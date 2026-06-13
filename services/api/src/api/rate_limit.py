"""Simple in-memory rate limiting dependencies (adapted from Beacon)."""

import time
from collections import defaultdict
from typing import ClassVar
from uuid import UUID

from fastapi import Depends, HTTPException, status

from .dependencies import get_current_user


class RateLimiter:
    """Fixed-window in-memory rate limiter per user."""

    # Shared state across all instances to preserve memory limits
    _history: ClassVar[dict[str, list[float]]] = defaultdict(list)

    def __init__(self, max_requests: int, window_seconds: int) -> None:
        """Initialize the rate limiter.

        Args:
            max_requests: Maximum requests allowed in the window
            window_seconds: Time window in seconds
        """
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        # Namespace history by window and max_requests to avoid collisions
        self._namespace = f"{max_requests}_{window_seconds}"

    async def __call__(self, user_id: UUID = Depends(get_current_user)) -> UUID:
        """Execute the rate limit check.

        Returns the user_id if allowed; raises 429 if the limit is exceeded.
        """
        now = time.time()
        # Combine user with the route's namespace to isolate different limits
        key = f"{user_id}_{self._namespace}"

        # Clean old timestamps
        RateLimiter._history[key] = [
            t for t in RateLimiter._history[key] if now - t < self.window_seconds
        ]

        if len(RateLimiter._history[key]) >= self.max_requests:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Rate limit exceeded. Please try again later.",
            )

        RateLimiter._history[key].append(now)
        return user_id
