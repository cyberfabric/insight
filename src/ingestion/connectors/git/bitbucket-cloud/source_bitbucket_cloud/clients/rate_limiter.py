"""Shared rate limit tracker and request governor for Bitbucket Cloud API."""

import logging
import threading
import time
from dataclasses import dataclass

logger = logging.getLogger("airbyte")

# Bitbucket Cloud: ~1000 req/hr authenticated. Be conservative.
MIN_REST_INTERVAL = 0.15  # 150ms between requests

# Secondary rate limit cooldown: pause after 502/503
SECONDARY_LIMIT_COOLDOWN = 60.0  # seconds


@dataclass
class RateLimitBudget:
    remaining: int = 1000
    reset_at: float = 0.0  # Unix timestamp


class RateLimiter:
    """Global request governor for Bitbucket Cloud REST API.

    Three layers of protection:
    1. Request throttle: minimum interval between requests
    2. Primary rate limit: proactive backoff when remaining budget drops below threshold
    3. Secondary rate limit: long cooldown after 502/503 responses
    """

    def __init__(self, threshold: int = 100):
        self.threshold = threshold
        self.rest = RateLimitBudget()
        self._last_rest_time: float = 0.0
        self._lock = threading.Lock()
        self._secondary_cooldown_until: float = 0.0

    def update_rest(self, remaining: int, reset_at: float):
        with self._lock:
            self.rest.remaining = remaining
            self.rest.reset_at = reset_at

    def throttle(self, api_type: str = "rest"):
        """Enforce minimum interval between requests. Thread-safe."""
        # Phase 1: check secondary cooldown (sleep outside lock)
        with self._lock:
            now = time.monotonic()
            secondary_wait = max(0.0, self._secondary_cooldown_until - now)

        if secondary_wait > 0:
            logger.warning(f"Secondary rate limit cooldown: waiting {secondary_wait:.0f}s")
            time.sleep(secondary_wait)

        # Phase 2: per-request throttle (compute under lock, sleep outside)
        with self._lock:
            now = time.monotonic()
            elapsed = now - self._last_rest_time
            throttle_wait = max(0.0, MIN_REST_INTERVAL - elapsed)
            self._last_rest_time = now + throttle_wait

        if throttle_wait > 0:
            time.sleep(throttle_wait)

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
            remaining = self.rest.remaining
            reset_at = self.rest.reset_at
        if remaining < self.threshold and reset_at > time.time():
            wait_seconds = reset_at - time.time() + 1
            logger.warning(
                f"Rate limit low (rest: {remaining} remaining). "
                f"Sleeping {wait_seconds:.0f}s until reset."
            )
            time.sleep(min(wait_seconds, 900))  # Cap at 15 min
