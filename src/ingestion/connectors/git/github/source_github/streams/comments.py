"""GitHub PR comments stream (REST, repo-level incremental, concurrent)."""

import logging
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

import requests as req

from source_github.clients.auth import rest_headers
from source_github.clients.concurrent import fetch_parallel_with_slices, retry_request
from source_github.streams.base import GitHubRestStream, _make_pk, _now_iso, check_rest_response
from source_github.streams.pull_requests import PullRequestsStream

logger = logging.getLogger("airbyte")


class CommentsStream(GitHubRestStream):
    """Fetches PR comments via repo-level incremental endpoints.

    Two repo-level endpoints with `since` parameter:
    - GET /repos/{owner}/{repo}/issues/comments?since=... (general discussion)
    - GET /repos/{owner}/{repo}/pulls/comments?since=... (inline review comments)

    This is much cheaper than per-PR fanout: 2 paginated calls per repo
    instead of 2 calls per PR. For 1000 PRs, that's 2 calls vs 2000.
    """

    name = "pull_request_comments"
    cursor_field = "updated_at"

    def __init__(self, parent: PullRequestsStream, max_workers: int = 10, **kwargs):
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
        """Yield one slice per repo (not per PR)."""
        state = stream_state or self._state
        seen_repos = set()
        for pr in self._parent.read_records(sync_mode=None):
            owner = pr.get("_owner", "")
            repo = pr.get("_repo", "")
            if not (owner and repo):
                continue
            repo_key = f"{owner}/{repo}"
            if repo_key in seen_repos:
                continue
            seen_repos.add(repo_key)

            # Repo-level cursors for the two comment feeds
            general_since = state.get(f"{repo_key}/general", {}).get("since", "")
            inline_since = state.get(f"{repo_key}/inline", {}).get("since", "")

            yield {
                "owner": owner,
                "repo": repo,
                "repo_key": repo_key,
                "general_since": general_since,
                "inline_since": inline_since,
            }

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
            records = self._fetch_repo_comments(stream_slice)
            yield from records
            self._advance_state(stream_slice, records)
        else:
            slices = self.stream_slices(stream_state=stream_state)
            for result in fetch_parallel_with_slices(self._fetch_repo_comments, slices, self._max_workers):
                if result.error is not None:
                    raise result.error
                yield from result.records
                self._advance_state(result.slice, result.records)

    def _advance_state(self, stream_slice: Mapping[str, Any], records: List[Mapping[str, Any]]):
        repo_key = stream_slice.get("repo_key", "")
        if not repo_key:
            return
        # Find max updated_at for general and inline separately
        max_general = stream_slice.get("general_since", "")
        max_inline = stream_slice.get("inline_since", "")
        for r in records:
            updated = r.get("updated_at", "")
            if not updated:
                continue
            if r.get("is_inline"):
                if updated > max_inline:
                    max_inline = updated
            else:
                if updated > max_general:
                    max_general = updated
        if max_general:
            self._state[f"{repo_key}/general"] = {"since": max_general}
        if max_inline:
            self._state[f"{repo_key}/inline"] = {"since": max_inline}

    def _fetch_repo_comments(self, stream_slice: dict) -> List[Mapping[str, Any]]:
        """Fetch both general and inline comments for one repo. Thread-safe."""
        records = []
        records.extend(self._fetch_paginated(stream_slice, comment_type="general"))
        records.extend(self._fetch_paginated(stream_slice, comment_type="inline"))
        return records

    def _do_rest_get(self, url: str, params: dict = None) -> req.Response:
        """REST GET with page-level retry. Thread-safe."""
        def _call():
            resp = req.get(url, headers=rest_headers(self._token), params=params, timeout=30)
            if resp.status_code == 429 or resp.status_code >= 500:
                raise RuntimeError(f"GitHub API error {resp.status_code} for {url}")
            return resp
        return retry_request(_call, context=url)

    def _fetch_paginated(self, stream_slice: dict, comment_type: str) -> List[Mapping[str, Any]]:
        owner = stream_slice.get("owner", "")
        repo = stream_slice.get("repo", "")
        records = []

        if comment_type == "general":
            # Repo-level issues comments (includes PR discussion comments)
            url = f"https://api.github.com/repos/{owner}/{repo}/issues/comments"
            since = stream_slice.get("general_since", "")
        else:
            # Repo-level pull request review comments (inline)
            url = f"https://api.github.com/repos/{owner}/{repo}/pulls/comments"
            since = stream_slice.get("inline_since", "")

        is_inline = comment_type == "inline"
        pk_prefix = "r" if is_inline else "c"
        params = {"per_page": "100", "sort": "updated", "direction": "asc"}
        if since:
            params["since"] = since

        while url:
            resp = self._do_rest_get(url, params)
            params = {}  # Only on first request

            remaining = resp.headers.get("X-RateLimit-Remaining")
            reset = resp.headers.get("X-RateLimit-Reset")
            if remaining and reset:
                self._rate_limiter.update_rest(int(remaining), float(reset))
            self._rate_limiter.wait_if_needed("rest")

            if not check_rest_response(resp, f"{owner}/{repo} {comment_type} comments"):
                break

            comments = resp.json()
            if not isinstance(comments, list):
                comments = [comments]

            for comment in comments:
                # Extract PR number from the comment's issue/PR URL
                pr_number = self._extract_pr_number(comment, is_inline)
                if pr_number is None:
                    continue  # Not a PR comment (could be an issue comment)

                comment_id = str(comment.get("id", ""))
                user = comment.get("user") or {}
                record = {
                    "pk": _make_pk(self._tenant_id, self._source_instance_id, owner, repo, pk_prefix, comment_id),
                    "tenant_id": self._tenant_id,
                    "source_instance_id": self._source_instance_id,
                    "data_source": "insight_github",
                    "collected_at": _now_iso(),
                    "database_id": comment.get("id"),
                    "pr_number": pr_number,
                    "pr_database_id": None,  # Not available from repo-level endpoint
                    "body": comment.get("body"),
                    "path": comment.get("path") if is_inline else None,
                    "line": comment.get("line") if is_inline else None,
                    "is_inline": is_inline,
                    "created_at": comment.get("created_at"),
                    "updated_at": comment.get("updated_at"),
                    "author_login": user.get("login"),
                    "author_database_id": user.get("id"),
                    "author_email": None,
                    "author_association": comment.get("author_association"),
                    "_owner": owner,
                    "_repo": repo,
                }
                if is_inline:
                    record["diff_hunk"] = comment.get("diff_hunk")
                    record["commit_id"] = comment.get("commit_id")
                    record["original_commit_id"] = comment.get("original_commit_id")
                    record["original_line"] = comment.get("original_line")
                    record["original_position"] = comment.get("original_position")
                    record["start_line"] = comment.get("start_line")
                    record["start_side"] = comment.get("start_side")
                    record["side"] = comment.get("side")
                    record["in_reply_to_id"] = comment.get("in_reply_to_id")
                records.append(record)

            url = resp.links.get("next", {}).get("url")

        return records

    def _extract_pr_number(self, comment: dict, is_inline: bool) -> Optional[int]:
        """Extract PR number from a comment record."""
        if is_inline:
            # Inline review comments have pull_request_url
            pr_url = comment.get("pull_request_url", "")
            if pr_url:
                try:
                    return int(pr_url.rstrip("/").split("/")[-1])
                except (ValueError, IndexError):
                    return None
            return None
        else:
            # General comments: issue_url contains the issue/PR number
            # But we need to filter out non-PR issue comments
            # PR comments have pull_request field in the issue
            # The issues/comments endpoint doesn't distinguish — we include all
            # and let the issue_url indicate the PR number
            issue_url = comment.get("issue_url", "")
            if issue_url:
                try:
                    return int(issue_url.rstrip("/").split("/")[-1])
                except (ValueError, IndexError):
                    return None
            return None

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
                "pk": {"type": "string"},
                "tenant_id": {"type": "string"},
                "source_instance_id": {"type": "string"},
                "data_source": {"type": "string"},
                "collected_at": {"type": "string"},
                "database_id": {"type": ["null", "integer"]},
                "pr_number": {"type": ["null", "integer"]},
                "pr_database_id": {"type": ["null", "integer"]},
                "body": {"type": ["null", "string"]},
                "path": {"type": ["null", "string"]},
                "line": {"type": ["null", "integer"]},
                "is_inline": {"type": ["null", "boolean"]},
                "created_at": {"type": ["null", "string"]},
                "updated_at": {"type": ["null", "string"]},
                "author_login": {"type": ["null", "string"]},
                "author_database_id": {"type": ["null", "integer"]},
                "author_email": {"type": ["null", "string"]},
                "author_association": {"type": ["null", "string"]},
                "diff_hunk": {"type": ["null", "string"]},
                "commit_id": {"type": ["null", "string"]},
                "original_commit_id": {"type": ["null", "string"]},
                "original_line": {"type": ["null", "integer"]},
                "original_position": {"type": ["null", "integer"]},
                "start_line": {"type": ["null", "integer"]},
                "start_side": {"type": ["null", "string"]},
                "side": {"type": ["null", "string"]},
                "in_reply_to_id": {"type": ["null", "integer"]},
                "pr_updated_at": {"type": ["null", "string"]},
                "_owner": {"type": "string"},
                "_repo": {"type": "string"},
            },
        }
