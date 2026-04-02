"""Base stream classes for GitHub REST and GraphQL APIs."""

import logging
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping, MutableMapping, Optional

import requests
from airbyte_cdk.sources.streams.http import HttpStream

from source_github.clients.auth import graphql_headers, rest_headers
from source_github.clients.rate_limiter import RateLimiter

logger = logging.getLogger("airbyte")


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def check_rest_response(resp, context: str = ""):
    """Validate a REST response. Raises on unexpected errors, returns False for skip-worthy ones."""
    if resp.status_code in (404, 409):
        logger.warning(f"Skipping {context} ({resp.status_code})")
        return False
    if resp.status_code == 429 or resp.status_code >= 500:
        raise RuntimeError(f"GitHub API error {resp.status_code} for {context}")
    if resp.status_code in (401, 403):
        raise RuntimeError(f"GitHub auth error {resp.status_code} for {context}: {resp.text[:200]}")
    if resp.status_code >= 400:
        raise RuntimeError(f"GitHub API error {resp.status_code} for {context}: {resp.text[:200]}")
    return True


def _make_pk(tenant_id: str, source_instance_id: str, *parts: str) -> str:
    suffix = ":".join(parts)
    return f"urn:github:{tenant_id}:{source_instance_id}:{suffix}"


class GitHubRestStream(HttpStream, ABC):
    """Base for GitHub REST API v3 streams."""

    url_base = "https://api.github.com/"
    primary_key = "pk"

    def __init__(
        self,
        token: str,
        tenant_id: str,
        source_instance_id: str,
        rate_limiter: RateLimiter,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._token = token
        self._tenant_id = tenant_id
        self._source_instance_id = source_instance_id
        self._rate_limiter = rate_limiter

    def request_headers(self, **kwargs) -> Mapping[str, Any]:
        return rest_headers(self._token)

    def request_params(self, **kwargs) -> MutableMapping[str, Any]:
        return {"per_page": "100"}

    def next_page_token(self, response: requests.Response) -> Optional[Mapping[str, Any]]:
        links = response.links
        if "next" in links:
            return {"next_url": links["next"]["url"]}
        return None

    def path(self, *, next_page_token: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        if next_page_token and "next_url" in next_page_token:
            # Return full URL; HttpStream will use it directly
            return next_page_token["next_url"].replace(self.url_base, "")
        return self._path(**kwargs)

    @abstractmethod
    def _path(self, **kwargs) -> str:
        ...

    def should_retry(self, response: requests.Response) -> bool:
        if response.status_code in (401, 403, 404, 409):
            return False
        return response.status_code in (429, 500, 502, 503, 504)

    def backoff_time(self, response: requests.Response) -> Optional[float]:
        if response.status_code == 429:
            reset = response.headers.get("X-RateLimit-Reset")
            if reset:
                import time
                wait = float(reset) - time.time() + 1
                return max(wait, 1.0)
        return None

    def parse_response(self, response: requests.Response, **kwargs) -> Iterable[Mapping[str, Any]]:
        self._update_rate_limit(response)
        self._rate_limiter.wait_if_needed("rest")
        if response.status_code == 404:
            logger.warning(f"Resource not found (404): {response.url}")
            return
        if response.status_code == 409:
            # 409 Conflict: empty repository (no commits yet)
            logger.warning(f"Empty repository (409): {response.url}")
            return
        data = response.json()
        records = data if isinstance(data, list) else [data]
        for record in records:
            yield self._add_envelope(record)

    def _update_rate_limit(self, response: requests.Response):
        remaining = response.headers.get("X-RateLimit-Remaining")
        reset = response.headers.get("X-RateLimit-Reset")
        if remaining and reset:
            self._rate_limiter.update_rest(int(remaining), float(reset))

    def _add_envelope(self, record: dict, pk_parts: Optional[list] = None) -> dict:
        record["tenant_id"] = self._tenant_id
        record["source_instance_id"] = self._source_instance_id
        record["data_source"] = "insight_github"
        record["collected_at"] = _now_iso()
        if pk_parts:
            record["pk"] = _make_pk(self._tenant_id, self._source_instance_id, *pk_parts)
        return record


class GitHubGraphQLStream(HttpStream, ABC):
    """Base for GitHub GraphQL API v4 streams."""

    url_base = "https://api.github.com/"
    primary_key = "pk"
    http_method = "POST"

    def __init__(
        self,
        token: str,
        tenant_id: str,
        source_instance_id: str,
        rate_limiter: RateLimiter,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._token = token
        self._tenant_id = tenant_id
        self._source_instance_id = source_instance_id
        self._rate_limiter = rate_limiter

    def path(self, **kwargs) -> str:
        return "graphql"

    def request_headers(self, **kwargs) -> Mapping[str, Any]:
        return graphql_headers(self._token)

    @abstractmethod
    def _query(self) -> str:
        """Return the GraphQL query string."""
        ...

    @abstractmethod
    def _variables(
        self,
        stream_slice: Optional[Mapping[str, Any]] = None,
        next_page_token: Optional[Mapping[str, Any]] = None,
    ) -> dict:
        """Return GraphQL variables for the query."""
        ...

    @abstractmethod
    def _extract_nodes(self, data: dict) -> list:
        """Extract record nodes from the GraphQL response data."""
        ...

    @abstractmethod
    def _extract_page_info(self, data: dict) -> dict:
        """Extract pageInfo from the GraphQL response data."""
        ...

    def request_body_json(
        self,
        stream_slice: Optional[Mapping[str, Any]] = None,
        next_page_token: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Optional[Mapping[str, Any]]:
        return {
            "query": self._query(),
            "variables": self._variables(stream_slice, next_page_token),
        }

    def next_page_token(self, response: requests.Response) -> Optional[Mapping[str, Any]]:
        data = response.json().get("data", {})
        page_info = self._extract_page_info(data)
        if page_info.get("hasNextPage"):
            return {"after": page_info["endCursor"]}
        return None

    def should_retry(self, response: requests.Response) -> bool:
        if response.status_code in (401, 403):
            return False
        return response.status_code in (429, 500, 502, 503, 504)

    def parse_response(
        self,
        response: requests.Response,
        stream_slice: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Mapping[str, Any]]:
        body = response.json()
        self._update_graphql_rate_limit(body)
        self._rate_limiter.wait_if_needed("graphql")

        if "errors" in body:
            if "data" not in body or body.get("data") is None:
                raise RuntimeError(f"GraphQL query failed: {body['errors']}")
            logger.warning(f"GraphQL partial errors (continuing with data): {body['errors']}")

        data = body.get("data", {})
        nodes = self._extract_nodes(data)
        for node in nodes:
            yield self._add_envelope(node)

    def _update_graphql_rate_limit(self, body: dict):
        rate_limit = body.get("data", {}).get("rateLimit", {})
        remaining = rate_limit.get("remaining")
        reset_at = rate_limit.get("resetAt")
        if remaining is not None and reset_at:
            self._rate_limiter.update_graphql(remaining, reset_at)

    def _add_envelope(self, record: dict, pk_parts: Optional[list] = None) -> dict:
        record["tenant_id"] = self._tenant_id
        record["source_instance_id"] = self._source_instance_id
        record["data_source"] = "insight_github"
        record["collected_at"] = _now_iso()
        if pk_parts:
            record["pk"] = _make_pk(self._tenant_id, self._source_instance_id, *pk_parts)
        return record
