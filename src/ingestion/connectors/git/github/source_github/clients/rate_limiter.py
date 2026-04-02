"""Shared rate limit tracker for GitHub REST and GraphQL APIs."""

import logging
import time
from dataclasses import dataclass, field

logger = logging.getLogger("airbyte")


@dataclass
class RateLimitBudget:
    remaining: int = 5000
    reset_at: float = 0.0  # Unix timestamp


class RateLimiter:
    """Tracks REST and GraphQL rate limit budgets independently."""

    def __init__(self, threshold: int = 200):
        self.threshold = threshold
        self.rest = RateLimitBudget()
        self.graphql = RateLimitBudget()

    def update_rest(self, remaining: int, reset_at: float):
        self.rest.remaining = remaining
        self.rest.reset_at = reset_at

    def update_graphql(self, remaining: int, reset_at_iso: str):
        self.graphql.remaining = remaining
        try:
            from datetime import datetime, timezone
            dt = datetime.fromisoformat(reset_at_iso.replace("Z", "+00:00"))
            self.graphql.reset_at = dt.timestamp()
        except (ValueError, AttributeError):
            pass

    def wait_if_needed(self, api_type: str = "rest"):
        budget = self.rest if api_type == "rest" else self.graphql
        if budget.remaining < self.threshold and budget.reset_at > time.time():
            wait_seconds = budget.reset_at - time.time() + 1
            logger.warning(
                f"Rate limit low ({api_type}: {budget.remaining} remaining). "
                f"Sleeping {wait_seconds:.0f}s until reset."
            )
            time.sleep(min(wait_seconds, 900))  # Cap at 15 min
