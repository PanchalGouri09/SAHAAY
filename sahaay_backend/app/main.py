import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app.routers import (
    admin,
    ai_features,
    claims,
    deliveries,
    daily_food,
    donations,
    donation_offers,
    device_tokens,
    handover,
    leaderboard,
    notifications,
    profile,
    transport_coordination,
)
from app.scheduler.escalation_scheduler import EscalationScheduler
from app.scheduler.donation_offer_scheduler import DonationOfferScheduler

settings = get_settings()
logger = logging.getLogger("sahaay.app")


@asynccontextmanager
async def lifespan(app: FastAPI):
    scheduler: EscalationScheduler | None = None
    offer_scheduler: DonationOfferScheduler | None = None
    if settings.escalation_scheduler_enabled:
        scheduler = EscalationScheduler(
            interval_seconds=settings.escalation_scheduler_interval_seconds
        )
        try:
            scheduler.start()
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "Escalation scheduler failed to start (error_type=%s)",
                type(exc).__name__,
            )
            scheduler = None
    if settings.donation_offer_scheduler_enabled:
        offer_scheduler = DonationOfferScheduler(
            interval_seconds=settings.escalation_scheduler_interval_seconds
        )
        try:
            offer_scheduler.start()
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "Donation-offer scheduler failed to start (error_type=%s)",
                type(exc).__name__,
            )
            offer_scheduler = None
    yield
    if scheduler is not None:
        await scheduler.stop()
    if offer_scheduler is not None:
        await offer_scheduler.stop()


app = FastAPI(
    title="SAHAAY Backend",
    version="0.1.0",
    description="Firebase-authenticated server boundary for SAHAAY application data.",
    lifespan=lifespan,
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

app.include_router(profile.router, prefix="/api/v1")
app.include_router(donations.router, prefix="/api/v1")
app.include_router(daily_food.router, prefix="/api/v1")
app.include_router(claims.router, prefix="/api/v1")
app.include_router(transport_coordination.router, prefix="/api/v1")
app.include_router(deliveries.router, prefix="/api/v1")
app.include_router(notifications.router, prefix="/api/v1")
app.include_router(device_tokens.router, prefix="/api/v1")
app.include_router(admin.router, prefix="/api/v1")
app.include_router(leaderboard.router, prefix="/api/v1")
app.include_router(handover.router, prefix="/api/v1")
app.include_router(donation_offers.router, prefix="/api/v1")
app.include_router(donation_offers.donation_router, prefix="/api/v1")
app.include_router(ai_features.router)


@app.get("/health", tags=["system"])
def health() -> dict[str, str]:
    return {"status": "ok"}
