# Market Data Interface — Design

This document describes the unified Python market data API used in FinAlly. All code lives in `backend/app/market/`. The design isolates downstream code from the data source — whether prices come from the Massive REST API or from the built-in GBM simulator, every other part of the system sees the same interface.

---

## Design Principles

1. **Single abstraction, two implementations.** `MarketDataSource` is an abstract base class. `MassiveDataSource` and `SimulatorDataSource` both implement it. Nothing outside `app/market/` calls either implementation directly.

2. **Producer/consumer decoupling via `PriceCache`.** Data sources write into a shared in-memory cache. The SSE endpoint, trade execution logic, and portfolio valuation all read from the cache. The data source and its consumers never communicate directly.

3. **Factory selects the implementation.** `create_market_data_source(cache)` reads `MASSIVE_API_KEY` from the environment and returns the correct implementation. Call sites need zero conditional logic.

4. **Async lifecycle, sync cache reads.** Data sources are started and stopped with `await`. Cache reads are synchronous (protected by a threading lock) because FastAPI request handlers and the SSE generator need them from any context.

---

## Module Map

```
backend/app/market/
├── __init__.py          # Public re-exports
├── models.py            # PriceUpdate dataclass
├── cache.py             # PriceCache (thread-safe store)
├── interface.py         # MarketDataSource ABC
├── simulator.py         # GBMSimulator + SimulatorDataSource
├── massive_client.py    # MassiveDataSource
├── factory.py           # create_market_data_source()
├── stream.py            # FastAPI SSE router
└── seed_prices.py       # Starting prices + GBM params
```

Public surface (what other modules import):

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

## Core Types

### `PriceUpdate` — `models.py`

An immutable snapshot of one ticker at one moment.

```python
@dataclass(frozen=True, slots=True)
class PriceUpdate:
    ticker: str
    price: float           # Current price, rounded to 2dp
    previous_price: float  # Price from the prior update
    timestamp: float       # Unix seconds

    # Computed properties (no storage)
    @property
    def change(self) -> float: ...          # price - previous_price
    @property
    def change_percent(self) -> float: ...  # % change, 4dp
    @property
    def direction(self) -> str: ...         # "up" | "down" | "flat"

    def to_dict(self) -> dict: ...          # JSON-safe dict for SSE
```

`to_dict()` output (the shape sent over SSE and returned by `/api/watchlist`):

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

### `PriceCache` — `cache.py`

Thread-safe in-memory store. One writer (the active data source), many readers (SSE, API handlers, trade logic).

```python
cache = PriceCache()

# Write (called by data source background task)
update: PriceUpdate = cache.update(ticker="AAPL", price=193.42)
# timestamp defaults to time.time() if not provided

# Read (called by API handlers, SSE generator)
update: PriceUpdate | None = cache.get("AAPL")
price: float | None        = cache.get_price("AAPL")
all_prices: dict[str, PriceUpdate] = cache.get_all()  # shallow copy

# Housekeeping
cache.remove("AAPL")       # Called when ticker removed from watchlist

# SSE change detection
version: int = cache.version  # Increments on every update()
```

The `version` counter lets the SSE generator skip a send cycle when no prices have changed, avoiding unnecessary network traffic.

### `MarketDataSource` — `interface.py`

Abstract base class. All implementations must honour this contract exactly.

```python
class MarketDataSource(ABC):

    @abstractmethod
    async def start(self, tickers: list[str]) -> None:
        """
        Begin producing price updates for the given tickers.
        Starts a background task that writes to the PriceCache.
        Call exactly once. Call order: start → [add/remove]* → stop.
        """

    @abstractmethod
    async def stop(self) -> None:
        """
        Cancel the background task and release resources.
        Safe to call multiple times. After stop(), no more writes to cache.
        """

    @abstractmethod
    async def add_ticker(self, ticker: str) -> None:
        """
        Add a ticker to the active set. No-op if already present.
        Takes effect on the next update cycle.
        """

    @abstractmethod
    async def remove_ticker(self, ticker: str) -> None:
        """
        Remove a ticker from the active set. No-op if absent.
        Also removes the ticker from the PriceCache immediately.
        """

    @abstractmethod
    def get_tickers(self) -> list[str]:
        """Return the current list of actively tracked tickers."""
```

---

## Implementations

### `SimulatorDataSource` — `simulator.py`

Wraps `GBMSimulator` in an asyncio background task. Updates every 500 ms.

```python
source = SimulatorDataSource(
    price_cache=cache,
    update_interval=0.5,      # seconds between steps
    event_probability=0.001,  # chance of shock event per tick
)
await source.start(["AAPL", "GOOGL", "MSFT", ...])
```

On `start()`:
- Creates a `GBMSimulator` with the initial ticker list
- Seeds the cache immediately so the SSE endpoint has data before the first tick
- Launches `asyncio.create_task(self._run_loop())`

On `add_ticker()`:
- Adds the ticker to the simulator (rebuilds correlation matrix)
- Seeds the cache immediately with the new ticker's starting price

On `stop()`:
- Cancels the background task with `task.cancel()`; awaits `CancelledError`

See `MARKET_SIMULATOR.md` for the GBM math and correlation approach.

### `MassiveDataSource` — `massive_client.py`

Polls `GET /v2/snapshot/locale/us/markets/stocks/tickers` on a configurable interval using the `massive` Python SDK.

```python
source = MassiveDataSource(
    api_key="sk-...",
    price_cache=cache,
    poll_interval=15.0,  # seconds; 15s fits free tier (5 req/min)
)
await source.start(["AAPL", "GOOGL", ...])
```

On `start()`:
- Creates a `RESTClient(api_key=...)` from the `massive` package
- Immediately executes one poll so the cache has data before the first interval
- Launches `asyncio.create_task(self._poll_loop())`

On `_poll_once()`:
- Calls `client.get_snapshot_all(market_type=STOCKS, tickers=self._tickers)` in a thread (`asyncio.to_thread`) because the Massive SDK is synchronous
- For each snapshot: extracts `snap.last_trade.price` and `snap.last_trade.timestamp / 1000.0`
- Writes to cache: `cache.update(ticker=snap.ticker, price=price, timestamp=ts)`
- Logs warnings for malformed snapshots; logs errors for full poll failures without re-raising (the loop retries on the next interval)

On `add_ticker()`:
- Appends to `self._tickers`; the change is picked up on the next poll

On `remove_ticker()`:
- Removes from `self._tickers` and calls `cache.remove(ticker)` immediately

---

## Factory — `factory.py`

```python
from app.market import create_market_data_source, PriceCache

cache = PriceCache()
source = create_market_data_source(cache)
# Returns MassiveDataSource if MASSIVE_API_KEY is set and non-empty,
# otherwise returns SimulatorDataSource.

await source.start(default_tickers)
# ... app runs ...
await source.stop()
```

Implementation:

```python
def create_market_data_source(price_cache: PriceCache) -> MarketDataSource:
    api_key = os.environ.get("MASSIVE_API_KEY", "").strip()
    if api_key:
        return MassiveDataSource(api_key=api_key, price_cache=price_cache)
    else:
        return SimulatorDataSource(price_cache=price_cache)
```

The factory is the only place in the codebase that knows both implementations exist.

---

## SSE Streaming — `stream.py`

`create_stream_router(cache)` returns a FastAPI `APIRouter` pre-bound to the given cache. Mount it on the FastAPI app at startup.

```python
from fastapi import FastAPI
from app.market import PriceCache, create_market_data_source, create_stream_router

app = FastAPI()
cache = PriceCache()
source = create_market_data_source(cache)

app.include_router(create_stream_router(cache))

@app.on_event("startup")
async def startup():
    await source.start(["AAPL", "GOOGL", "MSFT", ...])

@app.on_event("shutdown")
async def shutdown():
    await source.stop()
```

**Endpoint:** `GET /api/stream/prices`  
**Media type:** `text/event-stream`

The generator (`_generate_events`) runs a loop every 500 ms:
1. Checks if the client disconnected (`request.is_disconnected()`)
2. Compares `cache.version` to the last-sent version — skips the send if nothing changed
3. Serialises `cache.get_all()` to JSON and yields an SSE `data:` frame

SSE frame format:

```
retry: 1000

data: {"AAPL": {"ticker": "AAPL", "price": 193.42, "previous_price": 192.18, ...}, "GOOGL": {...}, ...}

data: {"AAPL": {"ticker": "AAPL", "price": 193.67, ...}, ...}
```

The `retry: 1000` directive tells the browser's `EventSource` to reconnect after 1 second if the connection drops. Reconnection is automatic and requires no client-side code.

---

## Data Flow

```
Environment variable MASSIVE_API_KEY
        │
        ▼
create_market_data_source(cache)
        │
        ├── set → MassiveDataSource  ──── polls Massive REST API every N sec
        │                                         │
        └── not set → SimulatorDataSource ────────┤
                      GBM step every 500ms        │
                                                  ▼
                                           PriceCache.update()
                                           (thread-safe write)
                                                  │
                          ┌───────────────────────┼─────────────────────┐
                          ▼                       ▼                     ▼
               SSE /api/stream/prices    /api/portfolio        /api/portfolio/trade
               (reads cache.get_all())  (reads cache.get())   (reads cache.get_price())
                          │
                          ▼
                   Browser EventSource
```

---

## Extending the Interface

To add a third data source (e.g., a WebSocket feed or a different vendor):

1. Create a new file, e.g. `backend/app/market/websocket_source.py`
2. Implement `MarketDataSource` — all five abstract methods
3. Write to `self._cache` the same way as the existing implementations
4. Update `factory.py` to instantiate the new source under whatever environment-variable condition makes sense
5. Add tests in `backend/tests/market/`

No changes needed to `PriceCache`, `stream.py`, or any API route.

---

## Seed Data — `seed_prices.py`

Starting prices and GBM parameters for the 10 default tickers:

| Ticker | Seed price | σ (volatility) | μ (drift) | Group   |
|--------|-----------|----------------|-----------|---------|
| AAPL   | $190.00   | 22%            | 5%        | tech    |
| GOOGL  | $175.00   | 25%            | 5%        | tech    |
| MSFT   | $420.00   | 20%            | 5%        | tech    |
| AMZN   | $185.00   | 28%            | 5%        | tech    |
| TSLA   | $250.00   | 50%            | 3%        | tech*   |
| NVDA   | $800.00   | 40%            | 8%        | tech    |
| META   | $500.00   | 30%            | 5%        | tech    |
| JPM    | $195.00   | 18%            | 4%        | finance |
| V      | $280.00   | 17%            | 4%        | finance |
| NFLX   | $600.00   | 35%            | 5%        | tech    |

\* TSLA is in the tech group but treated as an independent mover (correlation 0.3 with everything).

Tickers added dynamically (not in this table) get `σ=25%`, `μ=5%`, and a random seed price between $50–$300.
