"""Base stream class for Bitbucket Cloud REST API v2.0.

- Rate-limit back-off handled via CDK retry (no external RateLimiter)
- Proactive slowdown when Bitbucket signals X-RateLimit-NearLimit
"""

import logging
import time
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping, MutableMapping, Optional

import requests
from airbyte_cdk.sources.streams.http import HttpStream

from source_bitbucket_cloud.auth import auth_headers

logger = logging.getLogger("airbyte")


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class BitbucketAuthError(RuntimeError):
    """Raised on 401/403 to prevent silent swallowing by child streams."""
    pass


def _make_unique_key(tenant_id: str, source_id: str, *natural_key_parts: str) -> str:
    return f"{tenant_id}:{source_id}:{':'.join(natural_key_parts)}"


class BitbucketCloudRestStream(HttpStream, ABC):
    """Base for Bitbucket Cloud REST API v2.0 streams.

    Rate-limit strategy (zero config required):
    1. CDK retry on 429 with backoff (should_retry / backoff_time)
    2. Proactive slowdown when Bitbucket sends X-RateLimit-NearLimit: true
       (fires when <20% of hourly budget remains)
    """

    url_base = "https://api.bitbucket.org/2.0/"
    primary_key = "unique_key"
    raise_on_http_errors = False  # We handle 404/401/403 in parse_response

    @property
    def request_timeout(self) -> Optional[int]:
        return 60

    # Proactive slowdown state — shared across all stream instances via class var.
    # When Bitbucket sends X-RateLimit-NearLimit: true (<20% budget left),
    # we pause briefly to avoid hitting 429. Resets after sleeping.
    _near_limit_backoff: float = 10.0  # seconds to sleep per request when near limit
    _near_limit_active: bool = False

    def __init__(
        self,
        token: str,
        tenant_id: str,
        source_id: str,
        username: str = "",
        **kwargs,
    ):
        # Pop request_budget if passed (for backwards compat) but ignore it
        kwargs.pop("request_budget", None)
        super().__init__(**kwargs)
        self._token = token
        self._username = username
        self._tenant_id = tenant_id
        self._source_id = source_id

    def request_headers(self, **kwargs) -> Mapping[str, Any]:
        return auth_headers(self._token, self._username)

    def request_params(self, **kwargs) -> MutableMapping[str, Any]:
        return {"pagelen": "100"}

    def next_page_token(self, response: requests.Response) -> Optional[Mapping[str, Any]]:
        """Parse pagination from JSON response body (Bitbucket uses {"next": "full_url"})."""
        try:
            data = response.json()
        except ValueError:
            return None
        next_url = data.get("next")
        if next_url:
            return {"next_url": next_url}
        return None

    def path(self, *, next_page_token: Optional[Mapping[str, Any]] = None, **kwargs) -> str:
        if next_page_token and "next_url" in next_page_token:
            full_url = next_page_token["next_url"]
            if full_url.startswith(self.url_base):
                return full_url[len(self.url_base):]
            # Handle URLs with query params that might not exactly match url_base
            return full_url.replace("https://api.bitbucket.org/2.0/", "")
        return self._path(**kwargs)

    @abstractmethod
    def _path(self, **kwargs) -> str:
        ...

    def should_retry(self, response: requests.Response) -> bool:
        if not isinstance(response, requests.Response):
            return True  # connection error — always retry
        if response.status_code in (401, 403, 404):
            return False
        return response.status_code in (429, 500, 502, 503, 504)

    def backoff_time(self, response: requests.Response) -> Optional[float]:
        if not isinstance(response, requests.Response):
            return 60.0  # connection error — retry after 60s
        if response.status_code == 429:
            retry_after = response.headers.get("Retry-After")
            if retry_after:
                return max(float(retry_after), 1.0)
            # Bitbucket has no X-RateLimit-Reset, use longer default
            return 120.0
        if response.status_code in (502, 503):
            return 60.0
        return None

    def parse_response(
        self,
        response: requests.Response,
        stream_slice: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Mapping[str, Any]]:
        self._check_near_limit(response)

        if response.status_code in (401, 403):
            raise BitbucketAuthError(
                f"Bitbucket auth error ({response.status_code}): {response.text[:200]}"
            )

        if response.status_code == 404:
            logger.warning(f"Resource not found (404): {response.url}")
            return

        data = response.json()
        records = data.get("values", [])
        for record in records:
            yield self._add_envelope(record)

    def _check_near_limit(self, response: requests.Response) -> None:
        """Proactive slowdown when Bitbucket signals rate limit is near.

        X-RateLimit-NearLimit: true fires when <20% of hourly budget remains.
        We sleep briefly to spread remaining requests and avoid 429s.
        If we do hit 429, CDK retry handles it automatically.
        """
        near_limit = (
            response.headers.get("X-RateLimit-NearLimit", "").lower() == "true"
        )
        if near_limit and not BitbucketCloudRestStream._near_limit_active:
            BitbucketCloudRestStream._near_limit_active = True
            logger.warning(
                "Bitbucket X-RateLimit-NearLimit: true — slowing down requests "
                f"({self._near_limit_backoff}s delay per request)"
            )
        elif not near_limit and BitbucketCloudRestStream._near_limit_active:
            BitbucketCloudRestStream._near_limit_active = False
            logger.info("Bitbucket rate limit pressure relieved, resuming normal speed")

        if BitbucketCloudRestStream._near_limit_active:
            time.sleep(self._near_limit_backoff)

    def _add_envelope(self, record: dict, pk_parts: Optional[list] = None) -> dict:
        record = dict(record)  # shallow copy — prevent mutating cached dicts
        record["tenant_id"] = self._tenant_id
        record["source_id"] = self._source_id
        record["data_source"] = "insight_bitbucket_cloud"
        record["collected_at"] = _now_iso()
        if pk_parts:
            record["unique_key"] = _make_unique_key(self._tenant_id, self._source_id, *pk_parts)
        return record
