# Massive API (formerly Polygon.io) — Reference

Massive (rebranded from Polygon.io on 2025-10-30) provides REST, WebSocket, and flat-file market data for US equities, options, forex, crypto, indices, and futures. The Python SDK is `massive` (a drop-in replacement for `polygon-api-client`). This document covers only what FinAlly uses: **realtime snapshots** and **end-of-day OHLC bars** for US stocks.

---

## Installation & Authentication

```bash
pip install massive          # new name
# or: pip install polygon-api-client   # legacy, same code
```

```python
from massive import RESTClient

# API key from env var (automatic) or explicit:
client = RESTClient(api_key="YOUR_MASSIVE_API_KEY")
# Reads MASSIVE_API_KEY env var if api_key is omitted
```

The client defaults to `api.massive.com` but also accepts `api.polygon.io` (both endpoints use the same API keys).

---

## Rate Limits by Plan

| Plan     | Requests / minute | Recommended poll interval |
|----------|-------------------|---------------------------|
| Free     | 5                 | 15 s                      |
| Starter  | 60                | 5 s                       |
| Developer| 120               | 2 s                       |
| Advanced | Unlimited         | 0.5–1 s                   |

Exceeding the limit returns HTTP 429. The client does **not** retry automatically — implement backoff in the polling loop.

---

## Endpoint 1 — Full Market Snapshot (Multi-Ticker)

The primary endpoint for FinAlly's `MassiveDataSource`. Returns the current minute bar, daily bar, last trade, and last quote for a batch of tickers in a single call.

```
GET /v2/snapshot/locale/us/markets/stocks/tickers
```

**Query parameters:**

| Parameter   | Type    | Required | Description |
|-------------|---------|----------|-------------|
| `tickers`   | string  | No       | Comma-separated ticker symbols, e.g. `AAPL,TSLA,MSFT`. Omit for all tickers. |
| `include_otc` | boolean | No    | Include OTC securities (default: false). |

**Python (official SDK):**

```python
from massive import RESTClient
from massive.rest.models import SnapshotMarketType

client = RESTClient(api_key="YOUR_KEY")

# Batch snapshot for specific tickers
snapshots = client.get_snapshot_all(
    market_type=SnapshotMarketType.STOCKS,
    tickers=["AAPL", "GOOGL", "MSFT", "TSLA"],
)

for snap in snapshots:
    print(snap.ticker)                          # "AAPL"
    print(snap.last_trade.price)                # 193.42 (float)
    print(snap.last_trade.timestamp)            # Unix ms, e.g. 1712345678123
    print(snap.todays_change)                   # +2.15 (absolute)
    print(snap.todays_change_perc)              # +1.12 (percent)
    print(snap.day.open)                        # Today's open
    print(snap.day.high)                        # Today's high
    print(snap.day.low)                         # Today's low
    print(snap.day.close)                       # Today's close (latest intraday)
    print(snap.day.volume)                      # Today's volume
    print(snap.prev_day.close)                  # Previous day close
    print(snap.min.close)                       # Most recent 1-min bar close
```

**Response structure (raw JSON excerpt):**

```json
{
  "status": "OK",
  "count": 2,
  "tickers": [
    {
      "ticker": "AAPL",
      "todaysChange": 2.15,
      "todaysChangePerc": 1.12,
      "updated": 1712345678123456789,
      "day": {
        "o": 191.50, "h": 194.10, "l": 190.80, "c": 193.42,
        "v": 52341234, "vw": 192.45
      },
      "min": {
        "o": 193.10, "h": 193.50, "l": 193.00, "c": 193.42,
        "v": 45200, "vw": 193.28, "t": 1712345660000
      },
      "prevDay": {
        "o": 189.20, "h": 191.80, "l": 188.50, "c": 191.27,
        "v": 61234567
      },
      "lastTrade": {
        "p": 193.42,
        "s": 100,
        "t": 1712345678123,
        "c": [14, 41],
        "x": 4
      },
      "lastQuote": {
        "P": 193.43, "S": 200,
        "p": 193.42, "s": 100,
        "t": 1712345678200
      }
    }
  ]
}
```

**Key field mappings (SDK attributes vs raw JSON):**

| SDK attribute              | JSON field              | Notes |
|----------------------------|-------------------------|-------|
| `snap.ticker`              | `ticker`                | Symbol string |
| `snap.last_trade.price`    | `lastTrade.p`           | Last trade price (float) |
| `snap.last_trade.timestamp`| `lastTrade.t`           | Unix milliseconds |
| `snap.last_trade.size`     | `lastTrade.s`           | Shares in last trade |
| `snap.day.open`            | `day.o`                 | Today's open |
| `snap.day.close`           | `day.c`                 | Latest intraday close |
| `snap.day.volume`          | `day.v`                 | Today's volume |
| `snap.prev_day.close`      | `prevDay.c`             | Previous close |
| `snap.todays_change`       | `todaysChange`          | Absolute change |
| `snap.todays_change_perc`  | `todaysChangePerc`      | Percentage change |
| `snap.updated`             | `updated`               | Nanosecond timestamp |

> **Note:** `lastTrade` and `lastQuote` availability depends on your subscription plan. On the free tier these fields may be absent or delayed; use `snap.day.close` as a fallback.

---

## Endpoint 2 — Unified Snapshot (Multi-Asset)

A newer, more flexible endpoint that works across asset classes. Supports up to 250 tickers per request and exposes a richer `session` object with pre/post-market data. Suitable when you need to mix stocks, crypto, and forex in one call.

```
GET /v3/snapshot
```

**Key query parameters:**

| Parameter         | Type   | Description |
|-------------------|--------|-------------|
| `ticker.any_of`   | string | Up to 250 comma-separated symbols |
| `type`            | string | Filter by asset: `stocks`, `crypto`, `fx`, `options`, `indices` |
| `limit`           | int    | Default 10, max 250 |
| `sort`            | string | Field to sort by |
| `order`           | string | `asc` or `desc` |

**Python:**

```python
# Using raw params dict (unified endpoint)
import httpx

headers = {"Authorization": f"Bearer YOUR_KEY"}
params = {
    "ticker.any_of": "AAPL,GOOGL,MSFT",
    "type": "stocks",
    "limit": 250,
}
r = httpx.get("https://api.massive.com/v3/snapshot", headers=headers, params=params)
results = r.json()["results"]

for item in results:
    print(item["ticker"])
    print(item["last_trade"]["price"])         # float
    print(item["last_trade"]["sip_timestamp"]) # nanoseconds
    print(item["session"]["close"])            # intraday close
    print(item["session"]["change_percent"])   # % change from prev close
```

**Response result object fields:**

| Field                        | Type   | Description |
|------------------------------|--------|-------------|
| `ticker`                     | string | Symbol |
| `name`                       | string | Company name |
| `type`                       | string | Asset class (`stocks`) |
| `market_status`              | string | `open`, `closed`, `early_trading`, `late_trading` |
| `last_trade.price`           | float  | Last trade price |
| `last_trade.size`            | int    | Shares traded |
| `last_trade.sip_timestamp`   | int    | Nanosecond Unix timestamp |
| `last_trade.timeframe`       | string | `REAL-TIME` or `DELAYED` |
| `last_quote.bid`             | float  | Best bid |
| `last_quote.ask`             | float  | Best ask |
| `last_quote.midpoint`        | float  | Mid-price |
| `last_minute.open/high/low/close` | float | Most recent 1-min OHLC |
| `last_minute.volume`         | int    | Volume in last minute |
| `session.open`               | float  | Regular session open |
| `session.close`              | float  | Latest price (intraday close) |
| `session.change`             | float  | Absolute change from prev close |
| `session.change_percent`     | float  | Percentage change from prev close |
| `fmv`                        | float  | Fair Market Value (Business plan only) |

---

## Endpoint 3 — Daily Aggregate Bars (End of Day)

Returns OHLCV bars for a single ticker over a date range. Use this for historical charts and end-of-day prices.

```
GET /v2/aggs/ticker/{stocksTicker}/range/{multiplier}/{timespan}/{from}/{to}
```

**Parameters:**

| Parameter      | Type    | Required | Description |
|----------------|---------|----------|-------------|
| `stocksTicker` | string  | Yes      | Ticker symbol (e.g. `AAPL`) |
| `multiplier`   | integer | Yes      | Timespan multiplier (e.g. `1` for 1-day bars) |
| `timespan`     | string  | Yes      | `minute`, `hour`, `day`, `week`, `month`, `quarter`, `year` |
| `from`         | string  | Yes      | Start date `YYYY-MM-DD` or Unix ms |
| `to`           | string  | Yes      | End date `YYYY-MM-DD` or Unix ms |
| `adjusted`     | boolean | No       | Adjust for splits (default: true) |
| `sort`         | string  | No       | `asc` (oldest first) or `desc` |
| `limit`        | integer | No       | Max 50,000; default 5,000 |

**Python (end-of-day bars for one ticker):**

```python
from massive import RESTClient
from datetime import date, timedelta

client = RESTClient(api_key="YOUR_KEY")

# Last 30 days of daily bars
today = date.today()
thirty_days_ago = today - timedelta(days=30)

bars = []
for bar in client.list_aggs(
    ticker="AAPL",
    multiplier=1,
    timespan="day",
    from_=thirty_days_ago.isoformat(),
    to=today.isoformat(),
    adjusted=True,
    sort="asc",
    limit=50000,
):
    bars.append(bar)

for bar in bars:
    print(bar.timestamp)   # Unix ms (start of bar)
    print(bar.open)        # float
    print(bar.high)        # float
    print(bar.low)         # float
    print(bar.close)       # float
    print(bar.volume)      # int
    print(bar.vwap)        # float (volume-weighted avg price)
    print(bar.transactions)# int (number of trades)
```

**Response result object fields:**

| SDK attribute   | JSON field | Description |
|-----------------|------------|-------------|
| `bar.timestamp` | `t`        | Bar start, Unix milliseconds |
| `bar.open`      | `o`        | Open price |
| `bar.high`      | `h`        | High price |
| `bar.low`       | `l`        | Low price |
| `bar.close`     | `c`        | Close price |
| `bar.volume`    | `v`        | Share volume |
| `bar.vwap`      | `vw`       | Volume-weighted average price |
| `bar.transactions` | `n`    | Number of trades in bar |

**Fetch today's close for multiple tickers (loop):**

```python
tickers = ["AAPL", "GOOGL", "MSFT", "AMZN", "TSLA"]
today = date.today().isoformat()
eod_prices = {}

for ticker in tickers:
    bars = list(client.list_aggs(
        ticker=ticker,
        multiplier=1,
        timespan="day",
        from_=today,
        to=today,
        limit=1,
    ))
    if bars:
        eod_prices[ticker] = bars[-1].close

print(eod_prices)
# {'AAPL': 193.42, 'GOOGL': 174.85, ...}
```

> **Caveat:** This requires one API call per ticker. For many tickers, use `get_snapshot_all()` instead (one call for all tickers).

---

## Endpoint 4 — Grouped Daily (All Tickers, One Call)

Returns EOD OHLCV for every US stock in a single call — ideal for seeding prices at startup.

```
GET /v2/aggs/grouped/locale/us/market/stocks/{date}
```

**Python:**

```python
from massive import RESTClient

client = RESTClient(api_key="YOUR_KEY")

# Get all stocks' EOD data for a specific date
grouped = client.get_grouped_daily_aggs(
    date="2024-04-05",
    adjusted=True,
)

# grouped is a list of Agg objects, one per ticker
prices = {bar.ticker: bar.close for bar in grouped}
print(prices.get("AAPL"))  # 193.42
```

---

## Endpoint 5 — Last Trade (Single Ticker)

Lowest-latency way to get the most recent trade for one ticker. Useful for spot-checking a single price without a full snapshot.

```
GET /v2/last/trade/{stocksTicker}
```

**Python:**

```python
trade = client.get_last_trade(ticker="AAPL")
print(trade.price)       # trade.p — last trade price
print(trade.size)        # trade.s — shares
print(trade.timestamp)   # trade.t — nanosecond SIP timestamp
```

---

## Choosing the Right Endpoint

| Use case                              | Endpoint                                | Notes |
|---------------------------------------|-----------------------------------------|-------|
| Live prices for a watchlist (≤250)   | `GET /v2/snapshot/…/stocks/tickers`     | One call, best for polling |
| Cross-asset unified view              | `GET /v3/snapshot`                      | Richer session data |
| Historical daily OHLC for one ticker  | `GET /v2/aggs/ticker/…`                 | Paginated, per-ticker |
| All EOD prices for seeding            | `GET /v2/aggs/grouped/…`               | One call, all tickers |
| Real-time single-ticker spot check    | `GET /v2/last/trade/{ticker}`           | Fastest single read |

For FinAlly's polling architecture, **`get_snapshot_all()`** is the correct choice: one API call returns the latest trade price for all watched tickers simultaneously.

---

## Error Handling

```python
import httpx
from massive import RESTClient

client = RESTClient(api_key="YOUR_KEY")

try:
    snapshots = client.get_snapshot_all(
        market_type=SnapshotMarketType.STOCKS,
        tickers=["AAPL", "TSLA"],
    )
except httpx.HTTPStatusError as e:
    if e.response.status_code == 401:
        print("Invalid API key")
    elif e.response.status_code == 403:
        print("Endpoint not available on current plan")
    elif e.response.status_code == 429:
        print("Rate limit exceeded — back off and retry")
    else:
        raise
except httpx.RequestError as e:
    print(f"Network error: {e}")
```

Common status codes:

| Code | Meaning |
|------|---------|
| 200  | OK |
| 400  | Bad request (invalid ticker format, missing param) |
| 401  | Invalid or missing API key |
| 403  | Endpoint not included in your plan |
| 429  | Rate limit exceeded |
| 500  | Massive server error (retry with backoff) |
