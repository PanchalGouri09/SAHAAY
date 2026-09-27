"""
Central configuration for the SAHAAY AI & Smart Features service.
Keep tunable numbers here so the main backend team / evaluators can
see all the "business rules" in one place, and so you can tweak
weights without hunting through the code.
"""

import os

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------
# ML model file paths
# ---------------------------------------------------------------------
MODEL_DIR = os.path.join(BASE_DIR, "ml")
SURPLUS_MODEL_PATH = os.path.join(MODEL_DIR, "surplus_model.pkl")
ENCODER_PATH = os.path.join(MODEL_DIR, "encoders.pkl")

# ---------------------------------------------------------------------
# Sample dataset
# ---------------------------------------------------------------------
SAMPLE_DATA_PATH = os.path.join(BASE_DIR, "data", "sample_surplus_data.csv")

# ---------------------------------------------------------------------
# PDF acknowledgment output folder
# ---------------------------------------------------------------------
PDF_OUTPUT_DIR = os.path.join(BASE_DIR, "storage")

# ---------------------------------------------------------------------
# NGO Matching weights (must sum to 1.0)
# Tune these to change how much each factor influences the final score.
# ---------------------------------------------------------------------
MATCHING_WEIGHTS = {
    "distance": 0.30,
    "quantity_fit": 0.25,
    "dietary_compatibility": 0.20,
    "pickup_time_feasibility": 0.15,
    "restaurant_reliability": 0.10,
}

# Max distance (km) beyond which an NGO gets a distance score of 0
MAX_MATCHING_DISTANCE_KM = 15.0

# ---------------------------------------------------------------------
# GPS / Road-distance routing
# ---------------------------------------------------------------------
# If True, matching tries to use real road distance (via a routing API)
# instead of straight-line (haversine) distance. If the routing call
# fails (no internet, API down, timeout), it automatically falls back
# to haversine so the service never breaks because of a network issue.
USE_ROAD_DISTANCE = True

# Free, no-API-key-needed public OSRM demo server. Fine for a diploma
# project / development. For production, replace with your own hosted
# OSRM instance or a paid provider (e.g. Google Distance Matrix API)
# by editing get_road_distance_km() in app/core/matching.py.
OSRM_BASE_URL = "https://router.project-osrm.org"
ROAD_DISTANCE_TIMEOUT_SECONDS = 3

# ---------------------------------------------------------------------
# Auto-escalation
# ---------------------------------------------------------------------
# Minutes an NGO has to accept a donation before it is auto-escalated
# to the next-ranked NGO in the list.
ESCALATION_TIMEOUT_MINUTES = 15

# ---------------------------------------------------------------------
# Restaurant reliability scoring weights (out of 100)
# ---------------------------------------------------------------------
RELIABILITY_WEIGHTS = {
    "completion_rate": 40,   # successfully completed / total donations offered
    "avg_ngo_rating": 30,    # average rating given by NGOs, scaled 0-5 -> 0-30
    "cancellation_penalty": 20,  # inverse of cancellation rate
    "acceptance_rate": 10,   # accepted / offered
}

# ---------------------------------------------------------------------
# Food safety rules
# ---------------------------------------------------------------------
# Hours after preparation beyond which food is automatically rejected
SAFETY_HARD_REJECT_HOURS = {
    "cooked": 4,
    "dairy": 3,
    "bakery": 12,
    "packaged": 48,
    "raw": 2,
    "default": 4,
}

# Hours after preparation beyond which food needs manual review
# (between "safe" and "hard reject")
SAFETY_MANUAL_REVIEW_HOURS = {
    "cooked": 3,
    "dairy": 2,
    "bakery": 8,
    "packaged": 36,
    "raw": 1,
    "default": 3,
}
