"""
Basic API tests for the SAHAAY AI service.

Run with (from the sahaay-ai-service/ folder):
    pytest -v

These tests check that each endpoint responds correctly with valid
input. They are intentionally simple so a diploma student can extend
them easily.
"""

from datetime import datetime, timedelta

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_check():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_predict_surplus():
    payload = {
        "food_prepared_kg": 50,
        "food_sold_kg": 38,
        "food_category": "cooked",
        "day_of_week": "Friday",
        "date": "2026-08-28",
    }
    response = client.post("/api/v1/prediction/predict-surplus", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert "predicted_surplus_kg" in data
    assert data["predicted_surplus_kg"] >= 0
    assert "preparation_recommendation" in data
    assert "recommended_prepare_kg" in data


def test_rank_ngos():
    payload = {
        "donation": {
            "donation_id": "DON001",
            "restaurant_id": "REST001",
            "restaurant_latitude": 18.5204,
            "restaurant_longitude": 73.8567,
            "quantity_kg": 10,
            "dietary_type": "veg",
            "pickup_time": "18:00",
            "restaurant_reliability_score": 85,
        },
        "candidate_ngos": [
            {
                "ngo_id": "NGO001",
                "name": "Helping Hands",
                "latitude": 18.5304,
                "longitude": 73.8467,
                "dietary_accepted": ["veg", "any"],
                "max_capacity_kg": 20,
                "min_capacity_kg": 2,
                "available_from": "16:00",
                "available_to": "21:00",
            },
            {
                "ngo_id": "NGO002",
                "name": "Food For All",
                "latitude": 18.6104,
                "longitude": 73.9067,
                "dietary_accepted": ["non_veg"],
                "max_capacity_kg": 15,
                "min_capacity_kg": 1,
                "available_from": "09:00",
                "available_to": "13:00",
            },
        ],
    }
    response = client.post("/api/v1/matching/rank-ngos", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert len(data["ranked_ngos"]) == 2
    # NGO001 should outrank NGO002 (closer, dietary match, time fits)
    assert data["ranked_ngos"][0]["ngo_id"] == "NGO001"
    assert data["ranked_ngos"][0]["rank"] == 1
    assert data["ranked_ngos"][0]["distance_source"] in ("road", "straight_line")


def test_escalation_keep_waiting():
    payload = {
        "donation_id": "DON001",
        "ranked_ngo_ids": ["NGO001", "NGO002", "NGO003"],
        "current_ngo_index": 0,
        "current_ngo_status": "pending",
        "offer_sent_at": datetime.utcnow().isoformat(),
    }
    response = client.post("/api/v1/escalation/check", json=payload)
    assert response.status_code == 200
    assert response.json()["action"] == "keep_waiting"


def test_escalation_timeout_escalates():
    old_time = (datetime.utcnow() - timedelta(minutes=30)).isoformat()
    payload = {
        "donation_id": "DON001",
        "ranked_ngo_ids": ["NGO001", "NGO002", "NGO003"],
        "current_ngo_index": 0,
        "current_ngo_status": "pending",
        "offer_sent_at": old_time,
        "timeout_minutes": 15,
    }
    response = client.post("/api/v1/escalation/check", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert data["action"] == "escalate"
    assert data["next_ngo_id"] == "NGO002"


def test_reliability_score():
    payload = {
        "restaurant_id": "REST001",
        "total_donations_offered": 20,
        "total_donations_completed": 18,
        "total_donations_accepted": 19,
        "total_cancellations": 1,
        "average_ngo_rating": 4.5,
    }
    response = client.post("/api/v1/reliability/calculate", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert 0 <= data["reliability_score"] <= 100
    assert data["grade"] in ["Excellent", "Good", "Average", "Below Average", "Poor"]


def test_food_safety_eligible():
    payload = {
        "donation_id": "DON001",
        "food_category": "bakery",
        "prepared_at": (datetime.utcnow() - timedelta(hours=2)).isoformat(),
        "storage_condition": "room_temperature",
        "donation_status": "pending",
    }
    response = client.post("/api/v1/safety/verify", json=payload)
    assert response.status_code == 200
    assert response.json()["verdict"] == "Eligible"


def test_food_safety_not_eligible():
    payload = {
        "donation_id": "DON002",
        "food_category": "dairy",
        "prepared_at": (datetime.utcnow() - timedelta(hours=10)).isoformat(),
        "storage_condition": "room_temperature",
        "donation_status": "pending",
    }
    response = client.post("/api/v1/safety/verify", json=payload)
    assert response.status_code == 200
    assert response.json()["verdict"] == "Not Eligible"


def test_generate_and_download_acknowledgment():
    payload = {
        "donation_id": "DON999",
        "restaurant_name": "Spice Garden",
        "ngo_name": "Helping Hands",
        "food_details": "Veg thali, rice, dal",
        "quantity_kg": 12,
        "donation_datetime": datetime.utcnow().isoformat(),
        "completion_status": "Completed",
    }
    response = client.post("/api/v1/donation/generate-acknowledgment", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert data["pdf_filename"] == "acknowledgment_DON999.pdf"

    download_response = client.get("/api/v1/donation/download/DON999")
    assert download_response.status_code == 200
    assert download_response.headers["content-type"] == "application/pdf"
