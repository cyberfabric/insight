"""GitHub PR reviews stream (REST, paginated per PR, concurrent, incremental)."""

import logging
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

import requests as req

from source_github.clients.auth import rest_headers
from source_github.clients.concurrent import fetch_parallel_with_slices, retry_request
from source_github.streams.base import GitHubRestStream, _is_fatal, _make_unique_key, _now_iso, check_rest_response, _is_rate_limit_403
from source_github.streams.pull_requests import PullRequestsStream

logger = logging.getLogger("airbyte")


class ReviewsStream(GitHubRestStream):
    """Fetches reviews for each PR via REST with proper pagination.

    Incremental: only fetches reviews for PRs whose updated_at is newer
    than the stored child cursor for that PR.
    """

    name = "pull_request_reviews"
    cursor_field = "pr_updated_at"

    def __init__(self, parent: PullRequestsStream, max_workers: int = 5, **kwargs):
        super().__init__(**kwargs)
        self._parent = parent
        self._max_workers = max_workers
        self._state: MutableMapping[str, Any] = {}

    def _path(self, **kwargs) -> str:
        return ""

    @property
    def state(self) -> MutableMapping[str, Any]:
        return self._state

    @state.setter
    def state(self, value: MutableMapping[str, Any]):
        self._state = value or {}

    def stream_slices(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        **kwargs,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or self._state
        total = 0
        skipped = 0
        skipped_no_reviews = 0
        for pr in self._parent.get_child_slices():
            owner = pr.get("repo_owner", "")
            repo = pr.get("repo_name", "")
            pr_number = pr.get("number")
            pr_database_id = pr.get("database_id")
            pr_updated_at = pr.get("updated_at", "")
            review_count = pr.get("review_count")
            if not (owner and repo and pr_number):
                continue
            total += 1
            # Skip PRs with zero reviews
            if review_count == 0:
                skipped_no_reviews += 1
                continue
            partition_key = f"{owner}/{repo}/{pr_number}"
            child_cursor = state.get(partition_key, {}).get("synced_at", "")
            if pr_updated_at and child_cursor and pr_updated_at <= child_cursor:
                skipped += 1
                continue
            yield {
                "owner": owner,
                "repo": repo,
                "pr_number": pr_number,
                "pr_database_id": pr_database_id,
                "pr_updated_at": pr_updated_at,
                "partition_key": partition_key,
            }
        fetched = total - skipped - skipped_no_reviews
        if skipped or skipped_no_reviews:
            logger.info(f"Reviews: {fetched}/{total} PRs need review sync ({skipped} unchanged, {skipped_no_reviews} zero reviews)")

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        return self._state

    def read_records(self, sync_mode=None, stream_slice=None, stream_state=None, **kwargs) -> Iterable[Mapping[str, Any]]:
        if stream_state:
            self._state = stream_state

        if stream_slice is not None:
            records = self._fetch_reviews(stream_slice)
            yield from records
            self._advance_state(stream_slice)
        else:
            # Feed slices as generator — chunked execution inside fetch_parallel_with_slices
            for result in fetch_parallel_with_slices(
                self._fetch_reviews, self.stream_slices(stream_state=stream_state), self._max_workers
            ):
                if result.error is not None:
                    if _is_fatal(result.error):
                        raise result.error
                    logger.warning(f"Skipping review slice {result.slice.get('partition_key', '?')}: {result.error}")
                    continue
                yield from result.records
                self._advance_state(result.slice)

    def _advance_state(self, stream_slice: Mapping[str, Any]):
        partition_key = stream_slice.get("partition_key", "")
        pr_updated_at = stream_slice.get("pr_updated_at", "")
        if partition_key and pr_updated_at:
            self._state[partition_key] = {"synced_at": pr_updated_at}

    def _fetch_reviews(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch all reviews for one PR with pagination. Thread-safe."""
        owner = stream_slice.get("owner", "")
        repo = stream_slice.get("repo", "")
        pr_number = stream_slice.get("pr_number")
        pr_database_id = stream_slice.get("pr_database_id")
        pr_id = str(pr_database_id) if pr_database_id is not None else ""
        records = []

        url = f"https://api.github.com/repos/{owner}/{repo}/pulls/{pr_number}/reviews"
        params = {"per_page": "100"}

        while url:
            _url, _params = url, params

            def _call(_url=_url, _params=_params):
                self._rate_limiter.wait_if_needed("rest")
                r = req.get(_url, headers=rest_headers(self._token), params=_params, timeout=30)
                # Always update limiter from headers before error handling
                remaining = r.headers.get("X-RateLimit-Remaining")
                reset = r.headers.get("X-RateLimit-Reset")
                if remaining and reset:
                    self._rate_limiter.update_rest(int(remaining), float(reset))
                if r.status_code in (502, 503):
                    self._rate_limiter.on_secondary_limit()
                    raise RuntimeError(f"GitHub secondary rate limit ({r.status_code})")
                if _is_rate_limit_403(r) or r.status_code == 429:
                    raise RuntimeError(f"rate limit exhausted ({r.status_code})")
                if r.status_code >= 500:
                    raise RuntimeError(f"GitHub API error {r.status_code}")
                return r

            resp = retry_request(_call, context=f"{owner}/{repo} PR#{pr_number} reviews")
            params = {}

            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            self._rate_limiter.wait_if_needed("rest")

            if not check_rest_response(resp, f"{owner}/{repo} PR#{pr_number} reviews"):
                break

            reviews = resp.json()
            if not isinstance(reviews, list):
                reviews = [reviews]

            for review in reviews:
                if review.get("state") == "PENDING":
                    continue
                review_id = str(review.get("id", ""))
                user = review.get("user") or {}
                records.append({
                    "unique_key": _make_unique_key(self._tenant_id, self._source_id, owner, repo, pr_id, review_id),
                    "tenant_id": self._tenant_id,
                    "source_id": self._source_id,
                    "data_source": "insight_github",
                    "collected_at": _now_iso(),
                    "database_id": review.get("id"),
                    "pr_number": pr_number,
                    "pr_database_id": pr_database_id,
                    "state": review.get("state"),
                    "body": review.get("body"),
                    "submitted_at": review.get("submitted_at"),
                    "author_login": user.get("login"),
                    "author_database_id": user.get("id"),
                    "author_email": None,
                    "author_association": review.get("author_association"),
                    "commit_id": review.get("commit_id"),
                    "pr_updated_at": stream_slice.get("pr_updated_at"),
                    "partition_key": stream_slice.get("partition_key"),
                    "repo_owner": owner,
                    "repo_name": repo,
                })

            url = resp.links.get("next", {}).get("url")

        return records

    def next_page_token(self, response, **kwargs):
        return None

    def parse_response(self, response, stream_slice=None, **kwargs):
        return []

    def get_json_schema(self) -> Mapping[str, Any]:
        return {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "additionalProperties": True,
            "properties": {
                "tenant_id": {"type": "string"},
                "source_id": {"type": "string"},
                "unique_key": {"type": "string"},
                "data_source": {"type": "string"},
                "collected_at": {"type": "string"},
                "database_id": {"type": ["null", "integer"]},
                "pr_number": {"type": ["null", "integer"]},
                "pr_database_id": {"type": ["null", "integer"]},
                "state": {"type": ["null", "string"]},
                "body": {"type": ["null", "string"]},
                "submitted_at": {"type": ["null", "string"]},
                "author_login": {"type": ["null", "string"]},
                "author_database_id": {"type": ["null", "integer"]},
                "author_email": {"type": ["null", "string"]},
                "author_association": {"type": ["null", "string"]},
                "commit_id": {"type": ["null", "string"]},
                "pr_updated_at": {"type": ["null", "string"]},
                "repo_owner": {"type": "string"},
                "repo_name": {"type": "string"},
            },
        }
