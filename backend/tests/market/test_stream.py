"""Tests for SSE streaming endpoint."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.market.cache import PriceCache
from app.market.stream import _generate_events, create_stream_router


def _make_request(*, disconnected_after: int = 999) -> MagicMock:
    """Create a mock FastAPI Request.

    disconnected_after: number of calls to is_disconnected() before returning True.
    """
    request = MagicMock()
    request.client = MagicMock()
    request.client.host = "127.0.0.1"
    call_count = {"n": 0}

    async def is_disconnected():
        call_count["n"] += 1
        return call_count["n"] > disconnected_after

    request.is_disconnected = is_disconnected
    return request


class TestCreateStreamRouter:
    """Tests for create_stream_router factory."""

    def test_returns_api_router(self):
        """create_stream_router returns a FastAPI APIRouter."""
        from fastapi import APIRouter

        cache = PriceCache()
        router = create_stream_router(cache)
        assert isinstance(router, APIRouter)

    def test_router_has_prices_route(self):
        """Router exposes a /api/stream/prices GET route."""
        cache = PriceCache()
        router = create_stream_router(cache)
        paths = [r.path for r in router.routes]
        assert "/api/stream/prices" in paths

    def test_different_caches_produce_separate_routers(self):
        """Each call to create_stream_router produces a fresh independent router."""
        cache1, cache2 = PriceCache(), PriceCache()
        router1 = create_stream_router(cache1)
        router2 = create_stream_router(cache2)
        # Each call must return a distinct object (no shared module-level state)
        assert router1 is not router2
        # Each router must have exactly one route (no duplicate registrations)
        assert len(router1.routes) == 1
        assert len(router2.routes) == 1


@pytest.mark.asyncio
class TestGenerateEvents:
    """Tests for the _generate_events async generator."""

    async def _collect(self, cache: PriceCache, request, interval: float = 0.0, max_frames: int = 10) -> list[str]:
        """Collect up to max_frames yielded SSE frames."""
        frames = []
        async for frame in _generate_events(cache, request, interval=interval):
            frames.append(frame)
            if len(frames) >= max_frames:
                break
        return frames

    async def test_first_frame_is_retry_directive(self):
        """Generator must yield the retry directive before any data."""
        cache = PriceCache()
        request = _make_request(disconnected_after=0)  # Disconnect immediately after retry

        frames = await self._collect(cache, request, max_frames=2)

        assert frames[0] == "retry: 1000\n\n"

    async def test_stops_when_client_disconnects(self):
        """Generator stops cleanly when request.is_disconnected() returns True."""
        cache = PriceCache()
        cache.update("AAPL", 190.0)
        request = _make_request(disconnected_after=1)  # Disconnect after 1 check

        frames = await self._collect(cache, request, max_frames=20)

        # Should be short (retry + at most 1 data frame)
        assert len(frames) <= 3

    async def test_yields_data_when_cache_has_prices(self):
        """Generator yields a data frame containing current cache prices."""
        import json

        cache = PriceCache()
        cache.update("AAPL", 190.0)
        cache.update("GOOGL", 175.0)
        # Disconnect after 2 checks so we get at least one data frame
        request = _make_request(disconnected_after=2)

        frames = await self._collect(cache, request, max_frames=5)

        data_frames = [f for f in frames if f.startswith("data: ")]
        assert len(data_frames) >= 1

        payload = json.loads(data_frames[0][len("data: "):].strip())
        assert "AAPL" in payload
        assert "GOOGL" in payload
        assert payload["AAPL"]["price"] == 190.0

    async def test_data_frame_format(self):
        """Data frames use correct SSE format: 'data: <json>\\n\\n'."""
        cache = PriceCache()
        cache.update("AAPL", 190.0)
        request = _make_request(disconnected_after=2)

        frames = await self._collect(cache, request, max_frames=5)

        data_frames = [f for f in frames if f.startswith("data: ")]
        assert len(data_frames) >= 1
        assert data_frames[0].endswith("\n\n")

    async def test_skips_send_when_version_unchanged(self):
        """Generator skips yielding a data frame when cache version has not changed."""
        cache = PriceCache()
        cache.update("AAPL", 190.0)

        sent_versions = []
        original_generate = _generate_events

        request = _make_request(disconnected_after=3)
        frames = await self._collect(cache, request, max_frames=5)

        # After the first data frame, the version doesn't change again in this test,
        # so subsequent loop iterations should not produce additional data frames.
        data_frames = [f for f in frames if f.startswith("data: ")]
        # Should only have sent data once (version only incremented once)
        assert len(data_frames) == 1

    async def test_no_data_frame_when_cache_empty(self):
        """Generator does not yield data frames when the cache is empty."""
        cache = PriceCache()
        request = _make_request(disconnected_after=2)

        frames = await self._collect(cache, request, max_frames=5)

        data_frames = [f for f in frames if f.startswith("data: ")]
        assert len(data_frames) == 0

    async def test_data_frame_contains_all_cache_fields(self):
        """Each ticker entry in the data frame includes all PriceUpdate fields."""
        import json

        cache = PriceCache()
        cache.update("AAPL", 190.0)
        request = _make_request(disconnected_after=2)

        frames = await self._collect(cache, request, max_frames=5)
        data_frames = [f for f in frames if f.startswith("data: ")]
        assert data_frames

        entry = json.loads(data_frames[0][len("data: "):].strip())["AAPL"]
        for field in ("ticker", "price", "previous_price", "timestamp", "change", "change_percent", "direction"):
            assert field in entry, f"Missing field: {field}"

    async def test_handles_no_client_info(self):
        """Generator works when request.client is None (e.g. Unix socket)."""
        cache = PriceCache()
        cache.update("AAPL", 190.0)
        request = _make_request(disconnected_after=1)
        request.client = None  # No client info

        frames = await self._collect(cache, request, max_frames=3)
        assert frames[0] == "retry: 1000\n\n"

    async def test_multiple_tickers_all_included(self):
        """All tickers in cache appear in each data frame."""
        import json

        tickers = ["AAPL", "GOOGL", "MSFT", "TSLA"]
        cache = PriceCache()
        for t in tickers:
            cache.update(t, 100.0)

        request = _make_request(disconnected_after=2)
        frames = await self._collect(cache, request, max_frames=5)

        data_frames = [f for f in frames if f.startswith("data: ")]
        assert data_frames

        payload = json.loads(data_frames[0][len("data: "):].strip())
        assert set(payload.keys()) == set(tickers)

    async def test_new_version_triggers_new_data_frame(self):
        """A cache update after the first send triggers a second data frame."""
        import asyncio

        cache = PriceCache()
        cache.update("AAPL", 190.0)

        frames: list[str] = []
        update_scheduled = False

        request = MagicMock()
        request.client = None
        check_count = {"n": 0}

        async def is_disconnected():
            check_count["n"] += 1
            # Update cache on second check to trigger a new version
            if check_count["n"] == 2:
                cache.update("AAPL", 191.0)
            return check_count["n"] > 3

        request.is_disconnected = is_disconnected

        async for frame in _generate_events(cache, request, interval=0.0):
            frames.append(frame)
            if len(frames) >= 10:
                break

        data_frames = [f for f in frames if f.startswith("data: ")]
        # Should have received two data frames (first send + after price update)
        assert len(data_frames) >= 2
