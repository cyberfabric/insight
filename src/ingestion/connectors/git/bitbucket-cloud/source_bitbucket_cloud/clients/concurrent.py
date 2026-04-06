"""Concurrent execution utilities for Bitbucket Cloud API streams."""

import logging
import random
import time
from concurrent.futures import ThreadPoolExecutor, Future, FIRST_COMPLETED, wait
from dataclasses import dataclass
from typing import Any, Callable, Iterable, List, Mapping, Optional

logger = logging.getLogger("airbyte")

DEFAULT_WORKERS = 5
MAX_RETRIES = 3
RETRY_BASE_DELAY = 2.0


@dataclass
class SliceResult:
    """Result of fetching a single slice — carries the slice for state tracking."""
    slice: Mapping[str, Any]
    records: List[Mapping[str, Any]]
    error: Optional[Exception] = None


def fetch_parallel_with_slices(
    fn: Callable[[Mapping[str, Any]], List[Mapping[str, Any]]],
    slices: Iterable[Mapping[str, Any]],
    max_workers: int = DEFAULT_WORKERS,
) -> Iterable[SliceResult]:
    """Execute fn(slice) with bounded in-flight concurrency.

    Submits up to max_workers slices initially, then submits the next slice
    as each worker completes. Never holds the entire slice list in memory.
    Adapts concurrency down after repeated transient failures.
    """
    current_workers = max_workers
    consecutive_errors = 0
    slice_iter = iter(slices)

    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        # Seed initial batch
        in_flight: dict[Future, Mapping[str, Any]] = {}
        for _ in range(current_workers):
            s = next(slice_iter, None)
            if s is None:
                break
            in_flight[pool.submit(_with_retry, fn, s)] = s

        while in_flight:
            done, _ = wait(in_flight, return_when=FIRST_COMPLETED)
            for future in done:
                s = in_flight.pop(future)
                exc = future.exception()
                if exc is not None:
                    consecutive_errors += 1
                    logger.error(f"Slice failed after retries: {exc}")
                    if consecutive_errors >= 3 and current_workers > 2:
                        current_workers = max(2, current_workers // 2)
                        logger.warning(f"Reducing concurrency to {current_workers} after {consecutive_errors} errors")
                    yield SliceResult(slice=s, records=[], error=exc)
                else:
                    consecutive_errors = 0
                    yield SliceResult(slice=s, records=future.result())

                # Submit next slice only if below adaptive concurrency limit
                if len(in_flight) < current_workers:
                    next_s = next(slice_iter, None)
                    if next_s is not None:
                        in_flight[pool.submit(_with_retry, fn, next_s)] = next_s


def retry_request(fn: Callable[[], Any], context: str = "") -> Any:
    """Retry a single HTTP request with jittered backoff.

    Use this inside fetch loops for page-level retry.
    Raises on auth/permission/404 errors immediately.
    Rate-limit 403s (containing "rate limit") are retried.
    """
    last_exc = None
    for attempt in range(MAX_RETRIES):
        try:
            return fn()
        except Exception as e:
            last_exc = e
            error_str = str(e).lower()
            # Rate-limit 403s should be retried, not raised immediately
            if "rate limit" in error_str:
                pass  # fall through to retry
            elif "401" in error_str or "403" in error_str or "404" in error_str:
                raise
            jitter = random.uniform(0, 1)
            delay = RETRY_BASE_DELAY * (2 ** attempt) + jitter
            logger.warning(f"Page retry {attempt + 1}/{MAX_RETRIES} for {context}: {e}. Waiting {delay:.1f}s...")
            time.sleep(delay)
    raise last_exc


def _with_retry(
    fn: Callable[[Mapping[str, Any]], List[Mapping[str, Any]]],
    s: Mapping[str, Any],
) -> List[Mapping[str, Any]]:
    """Call fn(s) with retry on transient errors (slice-level)."""
    last_exc = None
    for attempt in range(MAX_RETRIES):
        try:
            return fn(s)
        except Exception as e:
            last_exc = e
            error_str = str(e).lower()
            # Rate-limit 403s should be retried, not raised immediately
            if "rate limit" in error_str:
                pass  # fall through to retry
            elif "401" in error_str or "403" in error_str:
                raise
            elif "404" in error_str:
                return []  # deleted/missing resources: skip, don't abort
            jitter = random.uniform(0, 1)
            delay = RETRY_BASE_DELAY * (2 ** attempt) + jitter
            logger.warning(f"Slice retry {attempt + 1}/{MAX_RETRIES}: {e}. Waiting {delay:.1f}s...")
            time.sleep(delay)
    raise last_exc
