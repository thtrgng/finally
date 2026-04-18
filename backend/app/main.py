"""FinAlly FastAPI application entry point."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.market import PriceCache, create_market_data_source, create_stream_router

logger = logging.getLogger(__name__)

DEFAULT_TICKERS = ["AAPL", "GOOGL", "MSFT", "AMZN", "TSLA", "NVDA", "META", "JPM", "V", "NFLX"]


@asynccontextmanager
async def lifespan(app: FastAPI):
    cache: PriceCache = app.state.price_cache
    source = app.state.market_source
    await source.start(DEFAULT_TICKERS)
    logger.info("Market data source started")
    yield
    await source.stop()
    logger.info("Market data source stopped")


def create_app() -> FastAPI:
    cache = PriceCache()
    source = create_market_data_source(cache)

    app = FastAPI(
        title="FinAlly",
        description="AI Trading Workstation",
        version="0.1.0",
        lifespan=lifespan,
    )

    # CORS for Next.js dev server (localhost:3000)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["http://localhost:3000"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # Share singletons with all route handlers via app.state
    app.state.price_cache = cache
    app.state.market_source = source

    # Market data SSE endpoint
    app.include_router(create_stream_router(cache))

    # Health check
    @app.get("/api/health")
    async def health():
        return {"status": "ok", "tickers": source.get_tickers()}

    # Serve Next.js static export (production; directory may not exist in dev)
    try:
        app.mount("/", StaticFiles(directory="static", html=True), name="static")
    except RuntimeError:
        logger.info("No static/ directory found — frontend not mounted (dev mode)")

    return app


app = create_app()
