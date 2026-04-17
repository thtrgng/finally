# Market Data Backend — Implementation Design

This document is a complete implementation reference for the market data subsystem in `backend/app/market/`. It covers the unified interface, GBM simulator, Massive REST client, price cache, SSE streaming, and FastAPI wiring — with real code from the actual implementation.

---

## Architecture

```
MASSIVE_API_KEY env var
        │
        ▼
create_market_data_source(cache)
        │
        ├── set  → MassiveDataSource  ── polls Massive REST API every N sec
        │                                          │
        └── unset → SimulatorDataSource ───────────┤
                    GBM step every 500ms            │
                                                   ▼
                                            PriceCache.update()
                                            (thread-safe write)
                                                   │
                       ┌───────────────────────────┼─────────────────────┐
                       ▼                           ▼                     ▼
            GET /api/stream/prices        GET /api/portfolio    POST /api/portfolio/trade
            cache.get_all()               cache.get()           cache.get_price()
                       │
                       ▼
                Browser EventSource
```

### Module Map

```
backend/app/market/
├── __init__.py          # Public re-exports
├── models.py            # PriceUpdate — immutable frozen dataclass
├── cache.py             # PriceCache — thread-safe in-memory store
├── interface.py         # MarketDataSource — abstract base class
├── seed_prices.py       # Starting prices and GBM parameters
├── simulator.py         # GBMSimulator + SimulatorDataSource
├── massive_client.py    # MassiveDataSource
├── factory.py           # create_market_data_source()
└── stream.py            # FastAPI SSE router
```

Everything downstream imports from the public surface only:

```python
from app.market import (
    PriceCache,
    PriceUpdate,
    MarketDataSource,
    create_market_data_source,
    create_stream_router,
)
```

---

## 1. Data Model — `models.py`

`PriceUpdate` is the single data type that flows through the entire system: from data source → cache → SSE endpoint → browser.

```python
from __future__ import annotations

import time
from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class PriceUpdate:
    """Immutable snapshot of a single ticker's price at a point in time."""

    ticker: str
    price: float
    previous_price: float
    timestamp: float = field(default_factory=time.time)  # Unix seconds

    @property
    def change(self) -> float:
        """Absolute price change from previous update."""
        return round(self.price - self.previous_price, 4)

    @property
    def change_percent(self) -> float:
        """Percentage change from previous update."""
        if self.previous_price == 0:
            return 0.0
        return round((self.price - self.previous_price) / self.previous_price * 100, 4)

    @property
    def direction(self) -> str:
        """'up', 'down', or 'flat'."""
        if self.price > self.previous_price:
            return "up"
        elif self.price < self.previous_price:
            return "down"
        return "flat"

    def to_dict(self) -> dict:
        """Serialize for JSON / SSE transmission."""
        return {
            "ticker": self.ticker,
            "price": self.price,
            "previous_price": self.previous_price,
            "timestamp": self.timestamp,
            "change": self.change,
            "change_percent": self.change_percent,
            "direction": self.direction,
        }
```

**Wire format** — what `to_dict()` produces (sent over SSE and returned by `/api/watchlist`):

```json
{
  "ticker": "AAPL",
  "price": 193.42,
  "previous_price": 192.18,
  "timestamp": 1712345678.12,
  "change": 1.24,
  "change_percent": 0.6452,
  "direction": "up"
}
```

Key design choices:
- `frozen=True` — immutable after creation, safe to pass between threads without copying
- `slots=True` — lower memory overhead, faster attribute access
- `timestamp` defaults to `time.time()` at creation; Massive overrides this with the actual trade timestamp
- `change` and `change_percent` are computed properties, not stored — zero extra memory, always consistent

---

## 2. Price Cache — `cache.py`

The cache is the single point of truth for current prices. One writer (the active data source background task), many readers (SSE generator, API handlers, trade execution).

```python
from __future__ import annotations

import time
from threading import Lock

from .models import PriceUpdate


class PriceCache:
    """Thread-safe in-memory cache of the latest price for each ticker."""

    def __init__(self) -> None:
        self._prices: dict[str, PriceUpdate] = {}
        self._lock = Lock()
        self._version: int = 0  # Increments on every update()

    def update(self, ticker: str, price: float, timestamp: float | None = None) -> PriceUpdate:
        """Record a new price. Returns the PriceUpdate written.

        previous_price is taken from the prior entry for this ticker, or
        set equal to price on first update (direction='flat').
        """
        with self._lock:
            ts = timestamp or time.time()
            prev = self._prices.get(ticker)
            previous_price = prev.price if prev else price

            update = PriceUpdate(
                ticker=ticker,
                price=round(price, 2),
                previous_price=round(previous_price, 2),
                timestamp=ts,
            )
            self._prices[ticker] = update
            self._version += 1
            return update

    def get(self, ticker: str) -> PriceUpdate | None:
        with self._lock:
            return self._prices.get(ticker)

    def get_all(self) -> dict[str, PriceUpdate]:
        """Snapshot of all current prices. Shallow copy — safe for the caller."""
        with self._lock:
            return dict(self._prices)

    def get_price(self, ticker: str) -> float | None:
        update = self.get(ticker)
        return update.price if update else None

    def remove(self, ticker: str) -> None:
        with self._lock:
            self._prices.pop(ticker, None)

    @property
    def version(self) -> int:
        """Monotonic counter; bumped on every update(). Used by SSE for change detection."""
        return self._version
```

**Usage from API handlers:**

```python
# In trade execution — need current price
price = cache.get_price("AAPL")          # float | None
if price is None:
    raise HTTPException(400, "No price available for AAPL")

# In portfolio valuation — need all positions valued
all_prices = cache.get_all()             # dict[str, PriceUpdate]
for ticker, position in positions.items():
    current_price = all_prices.get(ticker)
    if current_price:
        unrealized_pnl = (current_price.price - position.avg_cost) * position.quantity
```

**Why a threading lock instead of asyncio primitives?**  
The data source background task writes via `asyncio.to_thread` (Massive) or the asyncio event loop (simulator). FastAPI request handlers run in the same event loop but may also touch the cache from threadpool workers. A `threading.Lock` works correctly in both contexts; an `asyncio.Lock` would deadlock if called from a thread.

---

## 3. Abstract Interface — `interface.py`

All data sources implement this contract. Nothing outside `app/market/` references `SimulatorDataSource` or `MassiveDataSource` directly.

```python
from __future__ import annotations

from abc import ABC, abstractmethod


class MarketDataSource(ABC):
    """Contract for market data providers.

    Lifecycle:
        source = create_market_data_source(cache)
        await source.start(["AAPL", "GOOGL", ...])
        await source.add_ticker("TSLA")      # dynamic watchlist changes
        await source.remove_ticker("GOOGL")
        await source.stop()                  # on app shutdown
    """

    @abstractmethod
    async def start(self, tickers: list[str]) -> None:
        """Begin producing price updates for the given tickers.
        Starts a background task. Call exactly once."""

    @abstractmethod
    async def stop(self) -> None:
        """Cancel the background task. Safe to call multiple times."""

    @abstractmethod
    async def add_ticker(self, ticker: str) -> None:
        """Add a ticker to the active set. No-op if already present."""

    @abstractmethod
    async def remove_ticker(self, ticker: str) -> None:
        """Remove a ticker. Also removes it from the PriceCache."""

    @abstractmethod
    def get_tickers(self) -> list[str]:
        """Return the current list of actively tracked tickers."""
```

`add_ticker` and `remove_ticker` are `async` even though neither implementation currently needs to `await` inside them. This future-proofs the interface for an implementation that might need to open a WebSocket subscription or make an HTTP call to register a ticker.

---

## 4. Seed Prices — `seed_prices.py`

Starting prices and simulation parameters for the default watchlist. Kept in a dedicated module so both `GBMSimulator` and tests can import it without circular dependencies.

```python
# Realistic starting prices for the default watchlist
SEED_PRICES: dict[str, float] = {
    "AAPL": 190.00,
    "GOOGL": 175.00,
    "MSFT": 420.00,
    "AMZN": 185.00,
    "TSLA": 250.00,
    "NVDA": 800.00,
    "META": 500.00,
    "JPM":  195.00,
    "V":    280.00,
    "NFLX": 600.00,
}

# Per-ticker GBM parameters (annualized)
TICKER_PARAMS: dict[str, dict[str, float]] = {
    "AAPL": {"sigma": 0.22, "mu": 0.05},
    "GOOGL": {"sigma": 0.25, "mu": 0.05},
    "MSFT": {"sigma": 0.20, "mu": 0.05},
    "AMZN": {"sigma": 0.28, "mu": 0.05},
    "TSLA": {"sigma": 0.50, "mu": 0.03},  # High vol, low drift
    "NVDA": {"sigma": 0.40, "mu": 0.08},  # High vol, strong drift upward
    "META": {"sigma": 0.30, "mu": 0.05},
    "JPM":  {"sigma": 0.18, "mu": 0.04},  # Low vol (bank)
    "V":    {"sigma": 0.17, "mu": 0.04},  # Low vol (payments)
    "NFLX": {"sigma": 0.35, "mu": 0.05},
}

DEFAULT_PARAMS: dict[str, float] = {"sigma": 0.25, "mu": 0.05}

# Correlation groups for Cholesky decomposition
CORRELATION_GROUPS: dict[str, set[str]] = {
    "tech":    {"AAPL", "GOOGL", "MSFT", "AMZN", "META", "NVDA", "NFLX"},
    "finance": {"JPM", "V"},
}

INTRA_TECH_CORR    = 0.6   # Tech stocks move together
INTRA_FINANCE_CORR = 0.5   # Finance stocks move together
CROSS_GROUP_CORR   = 0.3   # Cross-sector / unknown
TSLA_CORR          = 0.3   # TSLA is in tech group but treated as independent
```

**Volatility reference — expected move per 500ms tick at $100:**

| Ticker | σ (annual) | ~Move per tick |
|--------|------------|---------------|
| V      | 17%        | $0.006        |
| AAPL   | 22%        | $0.008        |
| META   | 30%        | $0.012        |
| NVDA   | 40%        | $0.016        |
| TSLA   | 50%        | $0.020        |

Derived from: `σ · √dt · S` where `dt = 0.5 / 5_896_800 ≈ 8.48×10⁻⁸`.

---

## 5. GBM Simulator — `simulator.py`

### Financial Mathematics

The simulator uses **Geometric Brownian Motion (GBM)** — the standard continuous-time model for stock prices:

```
dS = μ·S·dt + σ·S·dW
```

The discrete-time solution (Itô's lemma applied):

```
S(t+dt) = S(t) · exp((μ - σ²/2)·dt + σ·√dt·Z)
```

The `(μ - σ²/2)` term is the **Itô correction** — without it, simulated prices would systematically drift above `S₀·exp(μ·T)` due to the asymmetry of the log-normal distribution.

**Time step** — 500ms expressed as a fraction of a trading year:

```
TRADING_SECONDS_PER_YEAR = 252 × 6.5 × 3600 = 5,896,800
dt = 0.5 / 5,896,800 ≈ 8.48×10⁻⁸
```

### Correlated Moves via Cholesky Decomposition

Independent GBM draws would give uncorrelated prices. Real markets have sector correlation — when AAPL drops, MSFT tends to drop too.

**Algorithm:**
1. Build n×n correlation matrix `Σ` from pairwise correlations
2. Compute Cholesky factor `L` such that `L·Lᵀ = Σ`
3. Each tick: draw `Z ~ N(0, Iₙ)`, compute `Z_corr = L·Z`
4. Use `Z_corr[i]` as the normal draw for ticker `i`

```python
z_independent = np.random.standard_normal(n)   # uncorrelated draws
z_correlated  = self._cholesky @ z_independent  # correlated draws
```

Cholesky is only rebuilt when tickers are added/removed — O(n²) but n < 50, takes < 0.1ms.

### `GBMSimulator` Class

```python
class GBMSimulator:
    TRADING_SECONDS_PER_YEAR = 252 * 6.5 * 3600  # 5,896,800
    DEFAULT_DT = 0.5 / TRADING_SECONDS_PER_YEAR   # ~8.48e-8

    def __init__(
        self,
        tickers: list[str],
        dt: float = DEFAULT_DT,
        event_probability: float = 0.001,
    ) -> None:
        self._dt = dt
        self._event_prob = event_probability
        self._tickers: list[str] = []
        self._prices: dict[str, float] = {}
        self._params: dict[str, dict[str, float]] = {}
        self._cholesky: np.ndarray | None = None

        for ticker in tickers:
            self._add_ticker_internal(ticker)
        self._rebuild_cholesky()
```

**`step()` — the hot path, called every 500ms:**

```python
def step(self) -> dict[str, float]:
    n = len(self._tickers)
    if n == 0:
        return {}

    z_independent = np.random.standard_normal(n)
    z_correlated = self._cholesky @ z_independent if self._cholesky is not None else z_independent

    result: dict[str, float] = {}
    for i, ticker in enumerate(self._tickers):
        mu    = self._params[ticker]["mu"]
        sigma = self._params[ticker]["sigma"]

        drift     = (mu - 0.5 * sigma**2) * self._dt
        diffusion = sigma * math.sqrt(self._dt) * z_correlated[i]
        self._prices[ticker] *= math.exp(drift + diffusion)

        # Shock event: ~0.1% chance per tick per ticker
        # With 10 tickers at 2 ticks/sec → ~1 event per 50 seconds
        if random.random() < self._event_prob:
            shock = random.uniform(0.02, 0.05) * random.choice([-1, 1])
            self._prices[ticker] *= (1 + shock)

        result[ticker] = round(self._prices[ticker], 2)

    return result
```

**`_rebuild_cholesky()` — called on add/remove:**

```python
def _rebuild_cholesky(self) -> None:
    n = len(self._tickers)
    if n <= 1:
        self._cholesky = None
        return

    corr = np.eye(n)
    for i in range(n):
        for j in range(i + 1, n):
            rho = self._pairwise_correlation(self._tickers[i], self._tickers[j])
            corr[i, j] = rho
            corr[j, i] = rho

    self._cholesky = np.linalg.cholesky(corr)

@staticmethod
def _pairwise_correlation(t1: str, t2: str) -> float:
    tech    = CORRELATION_GROUPS["tech"]
    finance = CORRELATION_GROUPS["finance"]

    if t1 == "TSLA" or t2 == "TSLA":
        return TSLA_CORR                      # 0.30 — independent mover
    if t1 in tech and t2 in tech:
        return INTRA_TECH_CORR                # 0.60
    if t1 in finance and t2 in finance:
        return INTRA_FINANCE_CORR             # 0.50
    return CROSS_GROUP_CORR                   # 0.30 — cross-sector or unknown
```

### `SimulatorDataSource` — Async Wrapper

```python
class SimulatorDataSource(MarketDataSource):

    def __init__(
        self,
        price_cache: PriceCache,
        update_interval: float = 0.5,
        event_probability: float = 0.001,
    ) -> None:
        self._cache = price_cache
        self._interval = update_interval
        self._event_prob = event_probability
        self._sim: GBMSimulator | None = None
        self._task: asyncio.Task | None = None

    async def start(self, tickers: list[str]) -> None:
        self._sim = GBMSimulator(tickers=tickers, event_probability=self._event_prob)
        # Seed cache immediately — SSE has prices before the first tick
        for ticker in tickers:
            price = self._sim.get_price(ticker)
            if price is not None:
                self._cache.update(ticker=ticker, price=price)
        self._task = asyncio.create_task(self._run_loop(), name="simulator-loop")

    async def stop(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._task = None

    async def add_ticker(self, ticker: str) -> None:
        if self._sim:
            self._sim.add_ticker(ticker)           # rebuilds Cholesky
            price = self._sim.get_price(ticker)
            if price is not None:
                self._cache.update(ticker=ticker, price=price)  # seed immediately

    async def remove_ticker(self, ticker: str) -> None:
        if self._sim:
            self._sim.remove_ticker(ticker)        # rebuilds Cholesky
        self._cache.remove(ticker)

    def get_tickers(self) -> list[str]:
        return self._sim.get_tickers() if self._sim else []

    async def _run_loop(self) -> None:
        while True:
            try:
                if self._sim:
                    prices = self._sim.step()
                    for ticker, price in prices.items():
                        self._cache.update(ticker=ticker, price=price)
            except Exception:
                logger.exception("Simulator step failed")  # loop survives bad ticks
            await asyncio.sleep(self._interval)
```

### Initialization Flow

```
SimulatorDataSource.start(["AAPL", "GOOGL", ...])
        │
        ├── GBMSimulator.__init__(tickers)
        │     ├── for each ticker:
        │     │     _prices[ticker] = SEED_PRICES.get(ticker, random $50–$300)
        │     │     _params[ticker] = TICKER_PARAMS.get(ticker, DEFAULT_PARAMS)
        │     └── _rebuild_cholesky()
        │           ├── build n×n correlation matrix
        │           └── np.linalg.cholesky(corr) → _cholesky
        │
        ├── for each ticker:
        │     cache.update(ticker, sim.get_price(ticker))   ← immediate seed
        │
        └── asyncio.create_task(_run_loop())
              └── loop:
                    prices = sim.step()
                    for ticker, price: cache.update(ticker, price)
                    await asyncio.sleep(0.5)
```

### Dynamic Ticker Addition

```
POST /api/watchlist {"ticker": "PYPL"}
        │
        ├── SimulatorDataSource.add_ticker("PYPL")
        │     ├── GBMSimulator.add_ticker("PYPL")
        │     │     ├── _prices["PYPL"] = SEED_PRICES.get("PYPL", random $50–$300)
        │     │     ├── _params["PYPL"] = DEFAULT_PARAMS
        │     │     └── _rebuild_cholesky()   ← now n+1 tickers
        │     └── cache.update("PYPL", sim.get_price("PYPL"))   ← immediate seed
        │
        └── SSE stream includes PYPL on next tick
```

---

## 6. Massive REST Client — `massive_client.py`

### API Overview

Massive (formerly Polygon.io, rebranded 2025-10-30) provides the real market data path. The Python package is `massive` (drop-in replacement for `polygon-api-client`).

```bash
pip install massive
```

**Rate limits by plan:**

| Plan      | Req / min | Recommended poll interval |
|-----------|-----------|--------------------------|
| Free      | 5         | 15 s (default)           |
| Starter   | 60        | 5 s                      |
| Developer | 120       | 2 s                      |
| Advanced  | Unlimited | 0.5–1 s                  |

The primary endpoint is `GET /v2/snapshot/locale/us/markets/stocks/tickers` — returns current price data for a batch of tickers in one call.

### `MassiveDataSource` Class

```python
from massive import RESTClient
from massive.rest.models import SnapshotMarketType


class MassiveDataSource(MarketDataSource):

    def __init__(
        self,
        api_key: str,
        price_cache: PriceCache,
        poll_interval: float = 15.0,  # 15s fits free tier (5 req/min)
    ) -> None:
        self._api_key = api_key
        self._cache = price_cache
        self._interval = poll_interval
        self._tickers: list[str] = []
        self._task: asyncio.Task | None = None
        self._client: RESTClient | None = None

    async def start(self, tickers: list[str]) -> None:
        self._client = RESTClient(api_key=self._api_key)
        self._tickers = list(tickers)
        await self._poll_once()   # Immediate first poll — cache has data right away
        self._task = asyncio.create_task(self._poll_loop(), name="massive-poller")

    async def stop(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._task = None
        self._client = None

    async def add_ticker(self, ticker: str) -> None:
        ticker = ticker.upper().strip()
        if ticker not in self._tickers:
            self._tickers.append(ticker)
            # Price appears on next poll — no immediate seed

    async def remove_ticker(self, ticker: str) -> None:
        ticker = ticker.upper().strip()
        self._tickers = [t for t in self._tickers if t != ticker]
        self._cache.remove(ticker)  # Remove from cache immediately

    def get_tickers(self) -> list[str]:
        return list(self._tickers)

    async def _poll_loop(self) -> None:
        while True:
            await asyncio.sleep(self._interval)
            await self._poll_once()

    async def _poll_once(self) -> None:
        if not self._tickers or not self._client:
            return
        try:
            # RESTClient is synchronous — run in thread to not block event loop
            snapshots = await asyncio.to_thread(self._fetch_snapshots)
            for snap in snapshots:
                try:
                    price     = snap.last_trade.price
                    timestamp = snap.last_trade.timestamp / 1000.0  # ms → seconds
                    self._cache.update(ticker=snap.ticker, price=price, timestamp=timestamp)
                except (AttributeError, TypeError) as e:
                    logger.warning("Skipping snapshot for %s: %s", getattr(snap, "ticker", "???"), e)
        except Exception as e:
            logger.error("Massive poll failed: %s", e)
            # Don't re-raise — loop retries on next interval

    def _fetch_snapshots(self) -> list:
        """Synchronous — called from asyncio.to_thread()."""
        return self._client.get_snapshot_all(
            market_type=SnapshotMarketType.STOCKS,
            tickers=self._tickers,
        )
```

### Snapshot Response Fields

The `get_snapshot_all()` call returns a list of snapshot objects. Key fields:

```python
for snap in snapshots:
    snap.ticker                    # "AAPL"
    snap.last_trade.price          # 193.42 — what we use
    snap.last_trade.timestamp      # Unix milliseconds — divide by 1000 for seconds
    snap.last_trade.size           # shares in last trade
    snap.day.open                  # today's open
    snap.day.close                 # latest intraday close (fallback if no last_trade)
    snap.day.volume                # today's volume
    snap.prev_day.close            # previous day's close
    snap.todays_change             # absolute change
    snap.todays_change_perc        # % change
```

**Free tier fallback:** On the free tier, `last_trade` may be absent or stale. Use `snap.day.close` as a fallback:

```python
try:
    price = snap.last_trade.price
    timestamp = snap.last_trade.timestamp / 1000.0
except (AttributeError, TypeError):
    # Fall back to day close — less real-time but always present
    price = snap.day.close
    timestamp = time.time()
```

### Error Handling

```python
import httpx

try:
    snapshots = client.get_snapshot_all(
        market_type=SnapshotMarketType.STOCKS,
        tickers=["AAPL", "TSLA"],
    )
except httpx.HTTPStatusError as e:
    if e.response.status_code == 401:
        logger.error("Invalid MASSIVE_API_KEY")
    elif e.response.status_code == 429:
        logger.warning("Rate limit exceeded — back off and retry")
    elif e.response.status_code == 403:
        logger.error("Endpoint not on current plan")
    else:
        raise
except httpx.RequestError as e:
    logger.error("Network error: %s", e)
```

The `_poll_once()` method catches all exceptions and logs them without re-raising. The poll loop will retry automatically at the next interval. This makes the system resilient to transient network failures, rate-limit spikes, and bad API keys — prices in the cache just stop updating until the error resolves.

### Why `asyncio.to_thread`?

The `massive.RESTClient` is a synchronous blocking client. Calling it directly in a coroutine would block the entire asyncio event loop for the duration of the HTTP request — freezing SSE streams and blocking all API handlers for ~100-500ms per poll.

`asyncio.to_thread(self._fetch_snapshots)` runs the synchronous call in a threadpool worker, freeing the event loop. This is the correct pattern for any sync I/O inside an async application.

---

## 7. Factory — `factory.py`

The factory is the only place in the codebase that knows both implementations exist. Everything else references `MarketDataSource`.

```python
import logging
import os

from .cache import PriceCache
from .interface import MarketDataSource
from .massive_client import MassiveDataSource
from .simulator import SimulatorDataSource

logger = logging.getLogger(__name__)


def create_market_data_source(price_cache: PriceCache) -> MarketDataSource:
    """Return the appropriate data source based on environment.

    - MASSIVE_API_KEY set and non-empty → MassiveDataSource (real data)
    - Otherwise → SimulatorDataSource (GBM simulation)
    """
    api_key = os.environ.get("MASSIVE_API_KEY", "").strip()

    if api_key:
        logger.info("Market data source: Massive API (real data)")
        return MassiveDataSource(api_key=api_key, price_cache=price_cache)
    else:
        logger.info("Market data source: GBM Simulator")
        return SimulatorDataSource(price_cache=price_cache)
```

Usage at app startup:

```python
from app.market import PriceCache, create_market_data_source

cache = PriceCache()
source = create_market_data_source(cache)   # reads MASSIVE_API_KEY
await source.start(default_tickers)
```

---

## 8. SSE Streaming — `stream.py`

### Endpoint Design

```
GET /api/stream/prices
Content-Type: text/event-stream

retry: 1000

data: {"AAPL": {"ticker": "AAPL", "price": 190.50, "previous_price": 190.42, ...}, "GOOGL": {...}, ...}

data: {"AAPL": {"ticker": "AAPL", "price": 190.53, ...}, ...}
```

- `retry: 1000` — browser reconnects automatically after 1 second if dropped
- All tickers sent in each event as one JSON object (not individual events per ticker)
- Version-based change detection skips sends when the cache hasn't changed (avoids unnecessary traffic)

### Implementation

```python
from collections.abc import AsyncGenerator

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse

from .cache import PriceCache


def create_stream_router(price_cache: PriceCache) -> APIRouter:
    """Factory: returns a FastAPI router pre-bound to the given cache."""

    router = APIRouter(prefix="/api/stream", tags=["streaming"])

    @router.get("/prices")
    async def stream_prices(request: Request) -> StreamingResponse:
        return StreamingResponse(
            _generate_events(price_cache, request),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",  # Disable nginx buffering
            },
        )

    return router


async def _generate_events(
    price_cache: PriceCache,
    request: Request,
    interval: float = 0.5,
) -> AsyncGenerator[str, None]:
    yield "retry: 1000\n\n"

    last_version = -1
    client_ip = request.client.host if request.client else "unknown"
    logger.info("SSE client connected: %s", client_ip)

    try:
        while True:
            if await request.is_disconnected():
                logger.info("SSE client disconnected: %s", client_ip)
                break

            current_version = price_cache.version
            if current_version != last_version:
                last_version = current_version
                prices = price_cache.get_all()
                if prices:
                    data = {ticker: update.to_dict() for ticker, update in prices.items()}
                    yield f"data: {json.dumps(data)}\n\n"

            await asyncio.sleep(interval)
    except asyncio.CancelledError:
        logger.info("SSE stream cancelled for: %s", client_ip)
```

### Factory Pattern Rationale

`create_stream_router(cache)` returns a router rather than using a global `cache` variable. This lets the app wire up the cache at startup and pass it explicitly, without the module-level import-time side effects that a global would require. It also makes the SSE endpoint trivially testable: pass a mock cache.

### Frontend Connection

```typescript
// Browser-side EventSource connection
const es = new EventSource("/api/stream/prices");

es.onmessage = (event) => {
  const prices: Record<string, PriceUpdate> = JSON.parse(event.data);
  // prices["AAPL"].price, prices["AAPL"].direction, etc.
  updateWatchlist(prices);
};

es.onerror = () => {
  // EventSource reconnects automatically after `retry: 1000` ms
  // No manual reconnection logic needed
};
```

The watchlist panel's price flash animation should trigger on receiving a new value that differs from the previous:

```typescript
es.onmessage = (event) => {
  const prices = JSON.parse(event.data);
  for (const [ticker, update] of Object.entries(prices)) {
    const prevPrice = lastKnownPrices[ticker]?.price;
    if (prevPrice !== undefined && prevPrice !== update.price) {
      flashPrice(ticker, update.direction); // "up" → green, "down" → red
    }
    lastKnownPrices[ticker] = update;
  }
};
```

---

## 9. FastAPI Wiring — `main.py`

How the market data subsystem plugs into the FastAPI application:

```python
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from app.market import PriceCache, create_market_data_source, create_stream_router

# Default watchlist — also in the database seed
DEFAULT_TICKERS = ["AAPL", "GOOGL", "MSFT", "AMZN", "TSLA", "NVDA", "META", "JPM", "V", "NFLX"]

# Module-level singletons — shared with all route handlers via app.state
price_cache = PriceCache()
market_source = create_market_data_source(price_cache)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: read watchlist from DB, start data source
    tickers = await load_watchlist_from_db()  # or DEFAULT_TICKERS on first run
    await market_source.start(tickers)
    yield
    # Shutdown: stop data source cleanly
    await market_source.stop()


app = FastAPI(lifespan=lifespan)

# Mount SSE router
app.include_router(create_stream_router(price_cache))

# Expose cache and source on app.state for use in API route handlers
app.state.price_cache = price_cache
app.state.market_source = market_source
```

**Accessing the cache from route handlers:**

```python
from fastapi import Request

@router.post("/api/watchlist")
async def add_to_watchlist(body: WatchlistAddRequest, request: Request):
    source: MarketDataSource = request.app.state.market_source
    await source.add_ticker(body.ticker)
    # ... save to DB ...

@router.delete("/api/watchlist/{ticker}")
async def remove_from_watchlist(ticker: str, request: Request):
    source: MarketDataSource = request.app.state.market_source
    await source.remove_ticker(ticker)  # also removes from cache
    # ... delete from DB ...

@router.post("/api/portfolio/trade")
async def execute_trade(body: TradeRequest, request: Request):
    cache: PriceCache = request.app.state.price_cache
    price = cache.get_price(body.ticker)
    if price is None:
        raise HTTPException(400, f"No price data for {body.ticker}")
    # ... execute trade at `price` ...
```

---

## 10. Testing

### Unit Test Structure

```
backend/tests/market/
├── test_models.py           # PriceUpdate: properties, to_dict(), immutability
├── test_cache.py            # PriceCache: thread safety, version counter, all operations
├── test_simulator.py        # GBMSimulator: step(), correlations, Cholesky, shock events
├── test_simulator_source.py # SimulatorDataSource: full lifecycle integration tests
├── test_factory.py          # create_market_data_source(): env var selection
└── test_massive.py          # MassiveDataSource: mocked REST client
```

**Testing the cache:**

```python
def test_version_increments_on_update():
    cache = PriceCache()
    v0 = cache.version
    cache.update("AAPL", 190.0)
    assert cache.version == v0 + 1

def test_first_update_direction_is_flat():
    cache = PriceCache()
    update = cache.update("AAPL", 190.0)
    assert update.direction == "flat"
    assert update.previous_price == update.price

def test_remove_clears_ticker():
    cache = PriceCache()
    cache.update("AAPL", 190.0)
    cache.remove("AAPL")
    assert cache.get("AAPL") is None
```

**Testing the simulator:**

```python
def test_step_returns_all_tickers():
    sim = GBMSimulator(tickers=["AAPL", "GOOGL"])
    prices = sim.step()
    assert set(prices.keys()) == {"AAPL", "GOOGL"}

def test_prices_stay_positive():
    sim = GBMSimulator(tickers=["AAPL"])
    for _ in range(1000):
        prices = sim.step()
        assert prices["AAPL"] > 0

def test_add_ticker_appears_in_next_step():
    sim = GBMSimulator(tickers=["AAPL"])
    sim.add_ticker("TSLA")
    prices = sim.step()
    assert "TSLA" in prices
```

**Testing the factory:**

```python
def test_factory_returns_simulator_without_key(monkeypatch):
    monkeypatch.delenv("MASSIVE_API_KEY", raising=False)
    cache = PriceCache()
    source = create_market_data_source(cache)
    assert isinstance(source, SimulatorDataSource)

def test_factory_returns_massive_with_key(monkeypatch):
    monkeypatch.setenv("MASSIVE_API_KEY", "test-key-123")
    cache = PriceCache()
    source = create_market_data_source(cache)
    assert isinstance(source, MassiveDataSource)
```

**Testing MassiveDataSource with mocks:**

```python
from unittest.mock import MagicMock, patch


def test_poll_once_updates_cache():
    cache = PriceCache()
    source = MassiveDataSource(api_key="test", price_cache=cache)

    # Build a fake snapshot
    snap = MagicMock()
    snap.ticker = "AAPL"
    snap.last_trade.price = 193.42
    snap.last_trade.timestamp = 1712345678000  # Unix ms

    source._client = MagicMock()
    source._tickers = ["AAPL"]

    with patch.object(source, "_fetch_snapshots", return_value=[snap]):
        asyncio.run(source._poll_once())

    update = cache.get("AAPL")
    assert update is not None
    assert update.price == 193.42
```

**Running tests:**

```bash
cd backend
uv run --extra dev pytest -v                    # all tests
uv run --extra dev pytest tests/market/ -v      # market subsystem only
uv run --extra dev pytest --cov=app --cov-report=term-missing
```

---

## 11. Adding a New Data Source

To add a third market data implementation (e.g., a WebSocket feed):

1. **Create** `backend/app/market/ws_source.py`
2. **Implement** all five abstract methods from `MarketDataSource`
3. **Write** to `self._cache` using `cache.update(ticker, price, timestamp)` — same as existing sources
4. **Update** `factory.py` to instantiate under the appropriate env var condition
5. **Add tests** in `backend/tests/market/test_ws_source.py`

No changes needed to `PriceCache`, `stream.py`, `models.py`, or any API route handler.

```python
class WebSocketSource(MarketDataSource):

    def __init__(self, api_key: str, price_cache: PriceCache) -> None:
        self._api_key = api_key
        self._cache = price_cache
        self._tickers: set[str] = set()
        self._task: asyncio.Task | None = None

    async def start(self, tickers: list[str]) -> None:
        self._tickers = set(tickers)
        self._task = asyncio.create_task(self._connect_and_stream())

    async def stop(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def add_ticker(self, ticker: str) -> None:
        self._tickers.add(ticker)
        # subscribe via WebSocket

    async def remove_ticker(self, ticker: str) -> None:
        self._tickers.discard(ticker)
        self._cache.remove(ticker)
        # unsubscribe via WebSocket

    def get_tickers(self) -> list[str]:
        return list(self._tickers)

    async def _connect_and_stream(self) -> None:
        async with websockets.connect("wss://...") as ws:
            async for message in ws:
                data = json.loads(message)
                self._cache.update(ticker=data["symbol"], price=data["price"])
```

---

## 12. Extension: Mean Reversion

Standard GBM has no floor — prices can drift to $0 or $10,000 over a long session (particularly TSLA at σ=50%). For demos running hours, add Ornstein-Uhlenbeck mean reversion:

```python
# Replace the drift term in GBMSimulator.step():

# Standard GBM drift:
# drift = (mu - 0.5 * sigma**2) * self._dt

# Ornstein-Uhlenbeck (log-price) drift:
kappa = 0.01  # reversion speed (0 = pure GBM, 0.1 = strong pull)
log_target = math.log(self._seed_prices[ticker])  # pull toward seed price
log_current = math.log(self._prices[ticker])
ou_drift = kappa * (log_target - log_current) * self._dt

drift = (mu - 0.5 * sigma**2) * self._dt + ou_drift
```

This is not in the current implementation but is a straightforward two-line change to `GBMSimulator.step()`.
