"""Shared rate limit tracker and request governor for GitHub APIs."""

import logging
import threading
import time
from dataclasses import dataclass

logger = logging.getLogger("airbyte")

# Minimum interval between requests per API type.
# REST: ~10 req/sec (safe for sustained use)
# GraphQL: ~5 req/sec (higher point cost per request)
MIN_REST_INTERVAL = 0.1  # 100ms
MIN_GRAPHQL_INTERVAL = 0.2  # 200ms

# Secondary rate limit cooldown: how long to pause after a 502/503
SECONDARY_LIMIT_COOLDOWN = 60.0  # seconds


@dataclass
class RateLimitBudget:
    remaining: int = 5000
    reset_at: float = 0.0  # Unix timestamp


class RateLimiter:
    """Global request governor for GitHub REST and GraphQL APIs.

    Three layers of protection:
    1. Request throttle: minimum interval between requests (per API type)
    2. Primary rate limit: proactive backoff when remaining budget drops below threshold
    3. Secondary rate limit: long cooldown after 502/503 responses
    """

    def __init__(self, threshold: int = 200):
        self.threshold = threshold
        self.rest = RateLimitBudget()
        self.graphql = RateLimitBudget()
        self._last_rest_time: float = 0.0
        self._last_graphql_time: float = 0.0
        self._lock = threading.Lock()
        self._secondary_cooldown_until: float = 0.0

    def update_rest(self, remaining: int, reset_at: float):
        with self._lock:
            self.rest.remaining = remaining
            self.rest.reset_at = reset_at

    def update_graphql(self, remaining: int, reset_at_iso: str):
        with self._lock:
            self.graphql.remaining = remaining
            try:
                from datetime import datetime, timezone
                dt = datetime.fromisoformat(reset_at_iso.replace("Z", "+00:00"))
                self.graphql.reset_at = dt.timestamp()
            except (ValueError, AttributeError):
                pass

    def throttle(self, api_type: str = "rest"):
        """Enforce minimum interval between requests. Thread-safe."""
        with self._lock:
            # Check secondary cooldown first
            now = time.monotonic()
            if self._secondary_cooldown_until > now:
                wait = self._secondary_cooldown_until - now
                logger.warning(f"Secondary rate limit cooldown: waiting {wait:.0f}s")
                time.sleep(wait)
                now = time.monotonic()

            # Per-API-type throttle
            if api_type == "graphql":
                elapsed = now - self._last_graphql_time
                if elapsed < MIN_GRAPHQL_INTERVAL:
                    time.sleep(MIN_GRAPHQL_INTERVAL - elapsed)
                self._last_graphql_time = time.monotonic()
            else:
                elapsed = now - self._last_rest_time
                if elapsed < MIN_REST_INTERVAL:
                    time.sleep(MIN_REST_INTERVAL - elapsed)
                self._last_rest_time = time.monotonic()

    def on_secondary_limit(self):
        """Called when a 502/503 response is received. Triggers cooldown."""
        with self._lock:
            self._secondary_cooldown_until = time.monotonic() + SECONDARY_LIMIT_COOLDOWN
            logger.warning(
                f"Secondary rate limit detected (502/503). "
                f"Cooling down for {SECONDARY_LIMIT_COOLDOWN:.0f}s."
            )

    def wait_if_needed(self, api_type: str = "rest"):
        """Check primary rate limit budget and sleep if near exhaustion."""
        self.throttle(api_type)
        with self._lock:
            budget = self.rest if api_type == "rest" else self.graphql
            remaining = budget.remaining
            reset_at = budget.reset_at
        if remaining < self.threshold and reset_at > time.time():
            wait_seconds = reset_at - time.time() + 1
            logger.warning(
                f"Rate limit low ({api_type}: {remaining} remaining). "
                f"Sleeping {wait_seconds:.0f}s until reset."
            )
            time.sleep(min(wait_seconds, 900))  # Cap at 15 min
