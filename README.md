# FinAlly — AI Trading Workstation

A visually stunning AI-powered trading workstation that streams live market data, lets users trade a simulated portfolio, and integrates an LLM chat assistant that can analyze positions and execute trades via natural language.

Built entirely by coding agents as a capstone project for an agentic AI coding course.

## Features

- **Live price streaming** via SSE with green/red flash animations
- **Simulated portfolio** — $10k virtual cash, market orders, instant fills
- **Portfolio visualizations** — heatmap (treemap), P&L chart, positions table
- **AI chat assistant** — analyzes holdings, suggests and auto-executes trades
- **Watchlist management** — track tickers manually or via AI
- **Dark terminal aesthetic** — Bloomberg-inspired, data-dense layout

## Architecture

Single Docker container serving everything on port 8000:

- **Frontend**: Next.js (static export) with TypeScript and Tailwind CSS
- **Backend**: FastAPI (Python/uv) with SSE streaming
- **Database**: SQLite with lazy initialization and default seed data
- **AI**: LiteLLM → OpenRouter (Cerebras inference) with structured outputs
- **Market data**: Built-in GBM simulator (default) or Massive/Polygon.io API (optional)

## Quick Start

```bash
# 1. Copy and configure environment
cp .env.example .env
# Edit .env and add your OPENROUTER_API_KEY

# 2. Build and run
docker build -t finally .
docker run -v finally-data:/app/db -p 8000:8000 --env-file .env finally

# 3. Open http://localhost:8000
```

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `OPENROUTER_API_KEY` | Yes | OpenRouter API key for AI chat |
| `MASSIVE_API_KEY` | No | Polygon.io key for real market data; omit to use the built-in simulator |
| `LLM_MOCK` | No | Set `true` for deterministic mock responses (testing/CI) |

## Project Structure

```
finally/
├── frontend/        # Next.js static export (TypeScript + Tailwind)
├── backend/         # FastAPI uv project (Python)
│   ├── app/         # Routes, services, models
│   └── tests/       # Pytest unit tests
├── planning/        # Project documentation and agent contracts
├── test/            # Playwright E2E tests
├── db/              # SQLite volume mount (runtime, gitignored)
└── scripts/         # start_mac.sh / stop_mac.sh (and Windows equivalents)
```

## License

See [LICENSE](LICENSE).
