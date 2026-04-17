# Market Simulator — Design & Implementation

This document describes the GBM (Geometric Brownian Motion) simulator used as the default market data source in FinAlly when no `MASSIVE_API_KEY` is set. It covers the financial mathematics, code structure, configuration, and extension points.

---

## Overview

The simulator produces realistic-looking stock price movements entirely in-process — no network calls, no API keys required. It is the default experience for students and developers running the project locally.

Design goals:
- **Realistic motion** — prices drift and oscillate plausibly, not randomly walking to zero
- **Correlated moves** — tech stocks move together; finance stocks move together; cross-sector moves are weaker
- **Occasional drama** — random shock events produce sudden 2–5% moves to keep the UI interesting
- **Zero external dependencies** — runs without an internet connection
- **Hot path is fast** — `step()` is called every 500 ms; it must complete in well under 1 ms for 10 tickers

---

## Financial Mathematics

### Geometric Brownian Motion (GBM)

GBM is the standard model for continuous-time stock price simulation, originally formulated by Fischer Black and Myron Scholes. The stochastic differential equation is:

```
dS = μ·S·dt + σ·S·dW
```

where:
- `S` = stock price
- `μ` = annualized drift (expected return)
- `σ` = annualized volatility
- `dW` = Wiener process increment ~ N(0, dt)

The discrete-time solution (used in the code) is:

```
S(t+dt) = S(t) · exp((μ - σ²/2)·dt + σ·√dt·Z)
```

where `Z ~ N(0,1)` is a standard normal draw.

The `(μ - σ²/2)` term is the **Itô correction** — it accounts for the asymmetry of the log-normal distribution so that the expected price after time T is `S₀·exp(μ·T)` rather than systematically drifting away from that.

### Time Step

The simulator runs at 500 ms intervals. Expressed as a fraction of a trading year:

```
TRADING_SECONDS_PER_YEAR = 252 trading days × 6.5 hours/day × 3600 s/hour
                         = 5,896,800 seconds

dt = 0.5 / 5,896,800 ≈ 8.48 × 10⁻⁸
```

This tiny `dt` produces sub-cent price moves per tick for typical volatilities. Over thousands of ticks, the moves accumulate into plausible intraday price action.

**Example:** AAPL at σ=22%  
Expected standard deviation per tick = σ · √dt · S ≈ 0.22 × √(8.48×10⁻⁸) × 190 ≈ **$0.012** per tick

### Correlated Moves via Cholesky Decomposition

Independent GBM draws would produce uncorrelated prices — every stock doing its own thing. Real markets exhibit sector correlation: when AAPL drops, GOOGL and MSFT tend to drop too.

To model this, the simulator draws a vector of **correlated** normal random variables using the Cholesky decomposition of a correlation matrix.

**Algorithm:**

1. Build an n×n correlation matrix `Σ` where `Σ[i,j] = ρ(ticker_i, ticker_j)`
2. Compute the Cholesky factor `L` such that `L·Lᵀ = Σ`  
3. Each step: draw `Z ~ N(0, I_n)` (independent), then compute `Z_corr = L·Z`
4. Use `Z_corr[i]` as the normal draw for ticker `i`

```python
z_independent = np.random.standard_normal(n)   # [Z₁, Z₂, ..., Zₙ]
z_correlated  = cholesky @ z_independent        # [Z̃₁, Z̃₂, ..., Z̃ₙ]
```

The resulting draws have the desired pairwise correlations. The Cholesky matrix is only rebuilt when tickers are added or removed (O(n²), negligible for n < 50).

### Correlation Structure

Pairwise correlations are assigned by sector group:

| Pair type                          | Correlation coefficient |
|------------------------------------|------------------------|
| Tech stocks (same group)           | 0.60                   |
| Finance stocks (same group)        | 0.50                   |
| TSLA with any ticker               | 0.30                   |
| Cross-sector (tech ↔ finance, etc.)| 0.30                   |
| Unknown ticker with anything       | 0.30                   |

Groups are defined in `seed_prices.py`:

```python
CORRELATION_GROUPS = {
    "tech":    {"AAPL", "GOOGL", "MSFT", "AMZN", "META", "NVDA", "NFLX"},
    "finance": {"JPM", "V"},
}
```

TSLA is listed in the tech group but always gets `ρ=0.30` (it does its own thing).

---

## Code Structure

### `GBMSimulator` — `simulator.py`

Owns the mathematical simulation. Pure Python + NumPy; no asyncio, no I/O.

```python
class GBMSimulator:
    TRADING_SECONDS_PER_YEAR = 252 * 6.5 * 3600   # 5,896,800
    DEFAULT_DT = 0.5 / TRADING_SECONDS_PER_YEAR    # ~8.48e-8

    def __init__(
        self,
        tickers: list[str],
        dt: float = DEFAULT_DT,
        event_probability: float = 0.001,
    ) -> None: ...
```

**Internal state:**

| Attribute       | Type                        | Purpose |
|-----------------|-----------------------------|---------|
| `_dt`           | float                       | Time step (fraction of trading year) |
| `_event_prob`   | float                       | Probability of shock event per tick per ticker |
| `_tickers`      | list[str]                   | Ordered list of tracked tickers |
| `_prices`       | dict[str, float]            | Current price per ticker |
| `_params`       | dict[str, dict[str, float]] | Per-ticker `mu` and `sigma` |
| `_cholesky`     | np.ndarray or None          | Cholesky factor of correlation matrix |

**Public API:**

```python
sim.step() -> dict[str, float]
# Advances all prices by one dt. Returns {ticker: new_price}.
# Called every 500ms by SimulatorDataSource._run_loop().

sim.add_ticker(ticker: str) -> None
# Add a new ticker. Seeds from SEED_PRICES or random $50–$300.
# Rebuilds Cholesky matrix.

sim.remove_ticker(ticker: str) -> None
# Remove a ticker. Rebuilds Cholesky matrix.

sim.get_price(ticker: str) -> float | None
# Current price for a ticker.

sim.get_tickers() -> list[str]
# Current ticker list.
```

**`step()` hot path (called every 500 ms):**

```python
def step(self) -> dict[str, float]:
    n = len(self._tickers)
    z_independent = np.random.standard_normal(n)
    z_correlated  = self._cholesky @ z_independent  # None-safe (n≤1 skips)

    for i, ticker in enumerate(self._tickers):
        mu    = self._params[ticker]["mu"]
        sigma = self._params[ticker]["sigma"]

        drift     = (mu - 0.5 * sigma**2) * self._dt
        diffusion = sigma * math.sqrt(self._dt) * z_correlated[i]

        self._prices[ticker] *= math.exp(drift + diffusion)

        # Shock event
        if random.random() < self._event_prob:
            shock = random.uniform(0.02, 0.05) * random.choice([-1, 1])
            self._prices[ticker] *= (1 + shock)

        result[ticker] = round(self._prices[ticker], 2)

    return result
```

### `SimulatorDataSource` — `simulator.py`

Wraps `GBMSimulator` to implement the `MarketDataSource` interface. Handles the asyncio lifecycle.

```python
class SimulatorDataSource(MarketDataSource):

    def __init__(
        self,
        price_cache: PriceCache,
        update_interval: float = 0.5,     # seconds between steps
        event_probability: float = 0.001,
    ) -> None: ...
```

**`start(tickers)`:**
1. Creates `GBMSimulator(tickers=tickers, event_probability=...)`
2. Seeds the cache immediately — every ticker gets its initial price in the cache before the first tick so SSE clients see prices right away
3. Launches `asyncio.create_task(self._run_loop(), name="simulator-loop")`

**`_run_loop()` (background task):**
```python
async def _run_loop(self) -> None:
    while True:
        try:
            prices = self._sim.step()
            for ticker, price in prices.items():
                self._cache.update(ticker=ticker, price=price)
        except Exception:
            logger.exception("Simulator step failed")
        await asyncio.sleep(self._interval)
```

The `try/except` around `step()` means a single bad tick (e.g., NumPy numerical error on an extreme price) does not crash the loop.

**`add_ticker(ticker)`:**
1. Calls `self._sim.add_ticker(ticker)` (rebuilds correlation matrix)
2. Immediately seeds the cache with the new ticker's starting price so there is no gap between the ticker appearing in the watchlist and having a price

**`stop()`:**
```python
async def stop(self) -> None:
    if self._task and not self._task.done():
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass
```

---

## Configuration

### Per-Ticker Parameters — `seed_prices.py`

```python
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

TICKER_PARAMS: dict[str, dict[str, float]] = {
    "AAPL": {"sigma": 0.22, "mu": 0.05},
    "GOOGL": {"sigma": 0.25, "mu": 0.05},
    "MSFT": {"sigma": 0.20, "mu": 0.05},
    "AMZN": {"sigma": 0.28, "mu": 0.05},
    "TSLA": {"sigma": 0.50, "mu": 0.03},  # High vol, low drift
    "NVDA": {"sigma": 0.40, "mu": 0.08},  # High vol, strong drift
    "META": {"sigma": 0.30, "mu": 0.05},
    "JPM":  {"sigma": 0.18, "mu": 0.04},  # Low vol (bank)
    "V":    {"sigma": 0.17, "mu": 0.04},  # Low vol (payments)
    "NFLX": {"sigma": 0.35, "mu": 0.05},
}

DEFAULT_PARAMS = {"sigma": 0.25, "mu": 0.05}  # For dynamically added tickers
```

### Volatility Reference

σ values are **annualized**. Per 500 ms tick at a $100 price:

| σ    | Typical ticker      | ~Move per tick |
|------|---------------------|----------------|
| 0.17 | V (Visa)            | $0.006         |
| 0.22 | AAPL                | $0.008         |
| 0.30 | META                | $0.012         |
| 0.40 | NVDA                | $0.016         |
| 0.50 | TSLA                | $0.020         |

### Shock Events

The `event_probability=0.001` setting means each ticker has a **0.1% chance per tick** of a 2–5% random shock.

With 10 tickers at 2 ticks/second:
- Expected events per second = 10 × 2 × 0.001 = 0.02
- Expected inter-event gap ≈ **50 seconds**

This produces exciting but not overwhelming drama in the UI. Adjust `event_probability` when constructing `SimulatorDataSource` if needed.

---

## Initialization Flow

```
SimulatorDataSource.start(["AAPL", "GOOGL", ...])
        │
        ├── GBMSimulator.__init__(tickers)
        │     ├── for each ticker:
        │     │     _prices[ticker] = SEED_PRICES.get(ticker, random $50–$300)
        │     │     _params[ticker] = TICKER_PARAMS.get(ticker, DEFAULT_PARAMS)
        │     └── _rebuild_cholesky()
        │           ├── Build n×n correlation matrix using _pairwise_correlation()
        │           └── np.linalg.cholesky(corr) → _cholesky
        │
        ├── for each ticker:
        │     price_cache.update(ticker, sim.get_price(ticker))  ← seed immediately
        │
        └── asyncio.create_task(_run_loop())
              └── loop forever:
                    prices = sim.step()
                    for ticker, price in prices.items():
                        price_cache.update(ticker, price)
                    await asyncio.sleep(0.5)
```

---

## Adding a New Ticker at Runtime

```
watchlist API: POST /api/watchlist {"ticker": "PYPL"}
        │
        ├── SimulatorDataSource.add_ticker("PYPL")
        │     ├── GBMSimulator.add_ticker("PYPL")
        │     │     ├── _add_ticker_internal("PYPL")
        │     │     │     ├── _prices["PYPL"] = SEED_PRICES.get("PYPL", random)
        │     │     │     └── _params["PYPL"] = DEFAULT_PARAMS
        │     │     └── _rebuild_cholesky()  ← n+1 tickers now
        │     └── price_cache.update("PYPL", sim.get_price("PYPL"))  ← immediate seed
        │
        └── SSE stream on next tick includes PYPL
```

Cholesky rebuild is O(n²) but n < 50 in practice, taking < 0.1 ms.

---

## Visual Behaviour

What the simulator produces in the UI after 10 minutes at default settings:

- **Tech stocks** drift together — if AAPL is up 1%, MSFT and GOOGL are likely up 0.4–0.8%
- **TSLA** wanders independently — can be down 3% while tech is up
- **NVDA** has the most dramatic moves due to σ=40% and μ=8% drift (tends upward over time)
- **JPM and V** are the calmest tickers — small moves, low drama
- **Shock events** fire roughly once per minute per ticker, creating sudden spikes that flash green/red in the UI

---

## Extension Points

### Adding a new ticker with custom parameters

Add entries to `SEED_PRICES` and `TICKER_PARAMS` in `seed_prices.py`. The ticker will get the correct volatility when added to the watchlist.

### Changing the update frequency

Pass a different `update_interval` to `SimulatorDataSource`:

```python
# 250ms updates (more fluid UI)
SimulatorDataSource(price_cache=cache, update_interval=0.25)
```

Also update `dt` in `GBMSimulator` to match:

```python
GBMSimulator(tickers=..., dt=0.25 / TRADING_SECONDS_PER_YEAR)
```

### Sector correlation groups

Add entries to `CORRELATION_GROUPS` in `seed_prices.py`. The `_pairwise_correlation` static method uses set membership to assign coefficients. New tickers not in any group default to `CROSS_GROUP_CORR = 0.30`.

### Mean reversion

The standard GBM model has no mean reversion — prices can drift arbitrarily far from the seed. For a long-running demo (hours), this means TSLA might reach $0 or $10,000. To add mean reversion, replace the GBM drift with an Ornstein-Uhlenbeck term:

```python
# OU mean-reversion: pulls price back toward target_price
# kappa = reversion speed (0.01 = slow, 0.1 = fast)
drift = kappa * (math.log(target_price) - math.log(current_price)) * dt
```

This is not in the current implementation but is a straightforward extension.
