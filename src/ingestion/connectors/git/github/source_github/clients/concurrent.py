"""Concurrent execution utilities for GitHub API streams."""

import logging
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import Any, Callable, Iterable, List, Mapping, Optional, Tuple

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


def fetch_parallel(
    fn: Callable[[Mapping[str, Any]], List[Mapping[str, Any]]],
    slices: Iterable[Mapping[str, Any]],
    max_workers: int = DEFAULT_WORKERS,
) -> Iterable[Mapping[str, Any]]:
    """Execute fn(slice) in parallel across slices, yielding records.

    Retries failed slices up to MAX_RETRIES times with exponential backoff.
    Raises on persistent failure to avoid silent data loss.
    """
    for result in fetch_parallel_with_slices(fn, slices, max_workers):
        if result.error is not None:
            raise result.error
        yield from result.records


def fetch_parallel_with_slices(
    fn: Callable[[Mapping[str, Any]], List[Mapping[str, Any]]],
    slices: Iterable[Mapping[str, Any]],
    max_workers: int = DEFAULT_WORKERS,
) -> Iterable[SliceResult]:
    """Execute fn(slice) in parallel, yielding SliceResult with both records and slice.

    Callers can use the slice to update state only for successful slices.
    Failed slices (after retries) are yielded with error set and empty records.
    """
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {pool.submit(_with_retry, fn, s): s for s in slices}
        for future in as_completed(futures):
            s = futures[future]
            exc = future.exception()
            if exc is not None:
                logger.error(f"Failed after {MAX_RETRIES} retries for slice {s}: {exc}")
                yield SliceResult(slice=s, records=[], error=exc)
            else:
                yield SliceResult(slice=s, records=future.result())


def _with_retry(
    fn: Callable[[Mapping[str, Any]], List[Mapping[str, Any]]],
    s: Mapping[str, Any],
) -> List[Mapping[str, Any]]:
    """Call fn(s) with retry on transient errors."""
    last_exc = None
    for attempt in range(MAX_RETRIES):
        try:
            return fn(s)
        except Exception as e:
            last_exc = e
            error_str = str(e).lower()
            # Don't retry auth errors
            if "401" in error_str or "403" in error_str:
                raise
            delay = RETRY_BASE_DELAY * (2 ** attempt)
            logger.warning(
                f"Attempt {attempt + 1}/{MAX_RETRIES} failed for slice {s}: {e}. "
                f"Retrying in {delay:.0f}s..."
            )
            time.sleep(delay)
    raise last_exc
