"""
SAHAAY – AI & Smart Features Service
Entry point for the FastAPI application.

Run with:
    uvicorn app.main:app --reload --port 8000

Interactive API docs will be available at:
    http://127.0.0.1:8000/docs
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.routers import (
    donation_router,
    escalation_router,
    matching_router,
    prediction_router,
    reliability_router,
    safety_router,
)

app = FastAPI(
    title="SAHAAY - AI & Smart Features Service",
    description=(
        "Standalone Python/FastAPI microservice providing AI and rule-based "
        "smart features for the SAHAAY Food Wastage Prediction and "
        "Redistribution Platform: surplus prediction, NGO matching, "
        "auto-escalation, restaurant reliability scoring, food safety "
        "verification, and PDF donation acknowledgments."
    ),
    version="1.0.0",
)

# Allow the Flutter app / main backend (running on a different host/port)
# to call this service directly during development.
# TODO: restrict allow_origins to the actual backend/app domains before production deployment.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(prediction_router.router)
app.include_router(matching_router.router)
app.include_router(escalation_router.router)
app.include_router(reliability_router.router)
app.include_router(safety_router.router)
app.include_router(donation_router.router)


@app.get("/", tags=["Health"])
def root():
    return {
        "service": "SAHAAY AI & Smart Features Service",
        "status": "running",
        "docs": "/docs",
    }


@app.get("/health", tags=["Health"])
def health_check():
    return {"status": "ok"}
