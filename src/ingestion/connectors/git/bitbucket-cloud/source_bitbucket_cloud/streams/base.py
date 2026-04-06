"""Base stream class for Bitbucket Cloud REST API."""

import logging
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping, MutableMapping, Optional

import requests
from airbyte_cdk.sources.streams.http import HttpStream

from source_bitbucket_cloud.clients.auth import rest_headers
from source_bitbucket_cloud.clients.rate_limiter import RateLimiter

logger = logging.getLogger("airbyte")


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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
        if "rate limit" in body_text:
            return True
    except Exception:
        pass
    return False


def check_rest_response(resp, context: str = ""):
    """Validate a REST response. Raises on unexpected errors, returns False for skip-worthy ones."""
    if resp.status_code in (404, 409):
        logger.warning(f"Skipping {context} ({resp.status_code})")
        return False
    if resp.status_code == 429 or resp.status_code >= 500:
        raise RuntimeError(f"Bitbucket Cloud API error {resp.status_code} for {context}")
    if resp.status_code == 403 and _is_rate_limit_403(resp):
        raise RuntimeError(f"Bitbucket Cloud rate limit exhausted (403) for {context}")
    if resp.status_code in (401, 403):
        raise RuntimeError(f"Bitbucket Cloud auth error {resp.status_code} for {context}: {resp.text[:200]}")
    if resp.status_code >= 400:
        raise RuntimeError(f"Bitbucket Cloud API error {resp.status_code} for {context}: {resp.text[:200]}")
    return True


def _is_fatal(exc: Exception) -> bool:
    """Return True if the error should abort the stream (auth failures)."""
    error_str = str(exc).lower()
    if "rate limit" in error_str:
        return True
    if "401" in error_str:
        return True
    if "403" in error_str:
        return True
    return False


def _make_pk(tenant_id: str, source_instance_id: str, *parts: str) -> str:
    suffix = ":".join(parts)
    return f"urn:bitbucket_cloud:{tenant_id}:{source_instance_id}:{suffix}"


class BitbucketCloudRestStream(HttpStream, ABC):
    """Base for Bitbucket Cloud REST API v2.0 streams."""

    url_base = "https://api.bitbucket.org/2.0/"
    primary_key = "pk"

    def __init__(
        self,
        username: str | None,
        token: str,
        tenant_id: str,
        source_instance_id: str,
        rate_limiter: RateLimiter,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self._username = username
        self._token = token
        self._tenant_id = tenant_id
        self._source_instance_id = source_instance_id
        self._rate_limiter = rate_limiter

    def request_headers(self, **kwargs) -> Mapping[str, Any]:
        return rest_headers(self._username, self._token)

    def request_params(self, **kwargs) -> MutableMapping[str, Any]:
        return {"pagelen": "100"}

    def next_page_token(self, response: requests.Response) -> Optional[Mapping[str, Any]]:
        body = response.json()
        next_url = body.get("next")
        if next_url:
            return {"next_url": next_url}
        return None

    def path(self, *, next_page_token: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        if next_page_token and "next_url" in next_page_token:
            # Bitbucket returns a full URL; strip the base so HttpStream constructs it correctly
            full_url = next_page_token["next_url"]
            if full_url.startswith(self.url_base):
                return full_url[len(self.url_base):]
            # If the URL doesn't start with our base (shouldn't happen), return relative path
            return full_url
        return self._path(**kwargs)

    @abstractmethod
    def _path(self, **kwargs) -> str:
        ...

    def request_url(
        self,
        *,
        stream_state: Optional[Mapping[str, Any]] = None,
        stream_slice: Optional[Mapping[str, Any]] = None,
        next_page_token: Optional[Mapping[str, Any]] = None,
    ) -> str:
        """Override to use the full next URL directly when paginating."""
        if next_page_token and "next_url" in next_page_token:
            return next_page_token["next_url"]
        return super().request_url(
            stream_state=stream_state,
            stream_slice=stream_slice,
            next_page_token=next_page_token,
        )

    def should_retry(self, response: requests.Response) -> bool:
        if response.status_code == 403 and _is_rate_limit_403(response):
            return True
        if response.status_code in (401, 403, 404, 409):
            return False
        return response.status_code in (429, 500, 502, 503, 504)

    def backoff_time(self, response: requests.Response) -> Optional[float]:
        if response.status_code == 429 or (response.status_code == 403 and _is_rate_limit_403(response)):
            retry_after = response.headers.get("Retry-After")
            if retry_after:
                return max(float(retry_after), 1.0)
            reset = response.headers.get("X-RateLimit-Reset")
            if reset:
                import time
                wait = float(reset) - time.time() + 1
                return max(wait, 1.0)
            return 60.0
        if response.status_code in (502, 503):
            self._rate_limiter.on_secondary_limit()
            return 60.0
        return None

    def parse_response(self, response: requests.Response, **kwargs) -> Iterable[Mapping[str, Any]]:
        self._update_rate_limit(response)
        self._rate_limiter.wait_if_needed("rest")
        if response.status_code == 404:
            logger.warning(f"Resource not found (404): {response.url}")
            return
        if response.status_code == 409:
            logger.warning(f"Conflict (409): {response.url}")
            return
        data = response.json()
        records = data.get("values", [])
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
        record["data_source"] = "insight_bitbucket_cloud"
        record["collected_at"] = _now_iso()
        if pk_parts:
            record["pk"] = _make_pk(self._tenant_id, self._source_instance_id, *pk_parts)
        return record
