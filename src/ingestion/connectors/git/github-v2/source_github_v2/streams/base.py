"""Base stream classes for GitHub REST and GraphQL APIs (v2 connector).

Designed for ConcurrentSource compatibility:
- No shared mutable state between stream instances
- Proper stream_slices / next_page_token contracts
- Rate-limit back-off handled via CDK retry (no external RateLimiter)
"""

import logging
import time
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping, MutableMapping, Optional

import requests
from airbyte_cdk.sources.streams.http import HttpStream

from source_github_v2.auth import graphql_headers, rest_headers

logger = logging.getLogger("airbyte")


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class GitHubAuthError(RuntimeError):
    """Raised on 401/403 (non-rate-limit) to prevent silent swallowing by child streams."""
    pass


def _is_rate_limit_403(resp) -> bool:
    """Return True if a 403 response is due to rate limit exhaustion, not auth failure."""
    if resp.status_code != 403:
        return False
    if resp.headers.get("Retry-After"):
        return True
    if resp.headers.get("X-RateLimit-Remaining") == "0":
        return True
    try:
        body_text = resp.text.lower()
        if "secondary rate limit" in body_text or "rate limit" in body_text:
            return True
    except Exception:
        pass
    return False


def _make_unique_key(tenant_id: str, source_id: str, *natural_key_parts: str) -> str:
    return f"{tenant_id}:{source_id}:{':'.join(natural_key_parts)}"


class GitHubRestStream(HttpStream, ABC):
    """Base for GitHub REST API v3 streams.

    No external ``RateLimiter`` -- back-off is handled entirely through the
    CDK retry mechanism (``should_retry`` / ``backoff_time``).
    """

    url_base = "https://api.github.com/"
    primary_key = "unique_key"
    raise_on_http_errors = False  # We handle 404/409/401/403 in parse_response

    @property
    def request_timeout(self) -> Optional[int]:
        return 60

    def __init__(
        self,
        token: str,
        tenant_id: str,
        source_id: str,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._token = token
        self._tenant_id = tenant_id
        self._source_id = source_id

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
            return next_page_token["next_url"].replace(self.url_base, "")
        return self._path(**kwargs)

    @abstractmethod
    def _path(self, **kwargs) -> str:
        ...

    def should_retry(self, response: requests.Response) -> bool:
        if not isinstance(response, requests.Response):
            return True  # connection error — always retry
        if response.status_code == 403 and _is_rate_limit_403(response):
            return True
        if response.status_code in (401, 403, 404, 409):
            return False
        return response.status_code in (429, 500, 502, 503, 504)

    def backoff_time(self, response: requests.Response) -> Optional[float]:
        if not isinstance(response, requests.Response):
            return 60.0  # connection error — retry after 60s
        if response.status_code == 429 or (response.status_code == 403 and _is_rate_limit_403(response)):
            retry_after = response.headers.get("Retry-After")
            if retry_after:
                return max(float(retry_after), 1.0)
            reset = response.headers.get("X-RateLimit-Reset")
            if reset:
                wait = float(reset) - time.time() + 1
                return max(wait, 1.0)
        if response.status_code in (502, 503):
            return 60.0
        return None

    def _guard_response(self, response: requests.Response) -> bool:
        """Check auth errors and unexpected status codes.
        Returns True if safe to parse JSON. Raises on auth errors."""
        if response.status_code in (401, 403) and not _is_rate_limit_403(response):
            raise GitHubAuthError(
                f"GitHub auth error ({response.status_code}): {response.text[:200]}"
            )
        if response.status_code >= 400:
            logger.error(f"Unexpected HTTP {response.status_code}: {response.url} — {response.text[:200]}")
            return False
        return True

    def parse_response(self, response: requests.Response, **kwargs) -> Iterable[Mapping[str, Any]]:
        if not self._guard_response(response):
            return
        data = response.json()
        records = data if isinstance(data, list) else [data]
        for record in records:
            yield self._add_envelope(record)

    def _add_envelope(self, record: dict, pk_parts: Optional[list] = None) -> dict:
        record = dict(record)  # shallow copy — prevent mutating cached dicts
        record["tenant_id"] = self._tenant_id
        record["source_id"] = self._source_id
        record["data_source"] = "insight_github"
        record["collected_at"] = _now_iso()
        if pk_parts:
            record["unique_key"] = _make_unique_key(self._tenant_id, self._source_id, *pk_parts)
        return record


class GitHubGraphQLStream(HttpStream, ABC):
    """Base for GitHub GraphQL API v4 streams.

    Uses POST to ``/graphql``.  Back-off handled via CDK retry.
    """

    url_base = "https://api.github.com/"
    primary_key = "unique_key"
    http_method = "POST"

    @property
    def request_timeout(self) -> Optional[int]:
        return 120

    def __init__(
        self,
        token: str,
        tenant_id: str,
        source_id: str,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._token = token
        self._tenant_id = tenant_id
        self._source_id = source_id

    @staticmethod
    def _safe_get(data, *keys):
        """Navigate nested dicts safely, treating None as empty dict."""
        for key in keys:
            data = (data or {}).get(key)
        return data

    def path(self, **kwargs) -> str:
        return "graphql"

    def request_headers(self, **kwargs) -> Mapping[str, Any]:
        return graphql_headers(self._token)

    @abstractmethod
    def _query(self) -> str:
        ...

    @abstractmethod
    def _variables(
        self,
        stream_slice: Optional[Mapping[str, Any]] = None,
        next_page_token: Optional[Mapping[str, Any]] = None,
    ) -> dict:
        ...

    @abstractmethod
    def _extract_nodes(self, data: dict) -> list:
        ...

    @abstractmethod
    def _extract_page_info(self, data: dict) -> dict:
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

    def _is_graphql_rate_limited(self, response: requests.Response) -> bool:
        """Check if a 200 response contains a GraphQL rate-limit error in the body."""
        if response.status_code != 200:
            return False
        try:
            body = response.json()
            for error in body.get("errors", []):
                err_type = (error.get("type") or "").upper()
                err_msg = (error.get("message") or "").lower()
                if err_type == "RATE_LIMITED" or "rate limit" in err_msg:
                    return True
        except Exception:
            pass
        return False

    def should_retry(self, response: requests.Response) -> bool:
        if not isinstance(response, requests.Response):
            return True  # connection error — always retry
        if self._is_graphql_rate_limited(response):
            return True
        if response.status_code == 403 and _is_rate_limit_403(response):
            return True
        if response.status_code in (401, 403):
            return False
        return response.status_code in (429, 500, 502, 503, 504)

    def backoff_time(self, response: requests.Response) -> Optional[float]:
        if not isinstance(response, requests.Response):
            return 60.0  # connection error — retry after 60s
        if self._is_graphql_rate_limited(response):
            reset = response.headers.get("x-ratelimit-reset")
            if reset:
                wait = float(reset) - time.time() + 1
                return max(wait, 1.0)
            return 60.0
        if response.status_code == 429 or (response.status_code == 403 and _is_rate_limit_403(response)):
            retry_after = response.headers.get("Retry-After")
            if retry_after:
                return max(float(retry_after), 1.0)
            reset = response.headers.get("x-ratelimit-reset")
            if reset:
                wait = float(reset) - time.time() + 1
                return max(wait, 1.0)
            return 60.0
        if response.status_code in (502, 503):
            return 60.0
        return None

    def parse_response(
        self,
        response: requests.Response,
        stream_slice: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Mapping[str, Any]]:
        body = response.json()
        self._update_graphql_rate_limit(body, response)

        if "errors" in body:
            if "data" not in body or body.get("data") is None:
                raise RuntimeError(f"GraphQL query failed: {body['errors']}")
            logger.warning(f"GraphQL partial errors (continuing with data): {body['errors']}")

        data = body.get("data", {})
        nodes = self._extract_nodes(data)
        for node in nodes:
            yield self._add_envelope(node)

    def _update_graphql_rate_limit(self, body: dict, response: requests.Response = None):
        """Log GraphQL rate limit info from response body or headers."""
        rate_limit = body.get("data", {}).get("rateLimit", {})
        remaining = rate_limit.get("remaining")
        cost = rate_limit.get("cost")
        if cost is not None:
            logger.debug(f"GraphQL rate limit: cost={cost}, remaining={remaining}")
        if remaining is not None and remaining < 100:
            logger.warning(f"GraphQL rate limit low: {remaining} remaining")

    def _send_graphql(self, query: str, variables: dict, max_retries: int = 5) -> dict:
        """Execute a standalone GraphQL request with retry/backoff.

        Uses the same should_retry/backoff_time logic as CDK-managed requests.
        Returns the parsed JSON body on success.
        """
        headers = graphql_headers(self._token)
        payload = {"query": query, "variables": variables}

        for attempt in range(max_retries + 1):
            try:
                resp = requests.post(
                    "https://api.github.com/graphql",
                    json=payload,
                    headers=headers,
                    timeout=self.request_timeout,
                )
            except requests.RequestException as exc:
                if attempt >= max_retries:
                    raise
                logger.warning(f"GraphQL connection error (attempt {attempt + 1}), sleeping 60s: {exc}")
                time.sleep(60.0)
                continue

            if self.should_retry(resp):
                if attempt >= max_retries:
                    raise RuntimeError(
                        f"GraphQL request failed after {max_retries + 1} attempts "
                        f"({resp.status_code}): {resp.text[:200]}"
                    )
                wait = self.backoff_time(resp) or 60.0
                logger.warning(
                    f"GraphQL retryable error {resp.status_code} (attempt {attempt + 1}), "
                    f"retrying in {wait}s"
                )
                time.sleep(wait)
                continue

            if resp.status_code != 200:
                raise RuntimeError(f"GraphQL request failed ({resp.status_code}): {resp.text[:200]}")

            body = resp.json()
            self._update_graphql_rate_limit(body, resp)

            if "errors" in body and not body.get("data"):
                raise RuntimeError(f"GraphQL query failed: {body['errors']}")

            return body

        raise RuntimeError("GraphQL request failed: exhausted retries")

    def _add_envelope(self, record: dict, pk_parts: Optional[list] = None) -> dict:
        record = dict(record)  # shallow copy — prevent mutating cached dicts
        record["tenant_id"] = self._tenant_id
        record["source_id"] = self._source_id
        record["data_source"] = "insight_github"
        record["collected_at"] = _now_iso()
        if pk_parts:
            record["unique_key"] = _make_unique_key(self._tenant_id, self._source_id, *pk_parts)
        return record
