from datetime import UTC, date, datetime, timedelta

import httpx
import pytest

from app.schemas.ai import (
    DonationAcknowledgmentRequest,
    EscalationCheckRequest,
    MatchRequest,
    ReliabilityInput,
    SafetyCheckRequest,
    SurplusPredictionRequest,
)
from app.services.ai_client import (
    AIClient,
    AIServiceConfigurationError,
    AIServiceError,
    AIServiceHTTPError,
    AIServiceUnavailableError,
)


def make_client(handler: object) -> AIClient:
    return AIClient(base_url="http://ai.test", transport=httpx.MockTransport(handler))


def test_client_returns_typed_models() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/prediction/predict-surplus"
        return httpx.Response(
            200,
            json={
                "predicted_surplus_kg": 12.5,
                "preparation_recommendation": "Reduce prepared quantity",
                "recommended_prepare_kg": 40.0,
                "input_echo": {
                    "food_prepared_kg": 50.0,
                    "food_sold_kg": 38.0,
                    "food_category": "cooked",
                    "day_of_week": "Monday",
                    "date": "2026-08-28",
                },
                "model_version": "v1",
            },
        )

    client = make_client(handler)
    result = client.predict_surplus(
        SurplusPredictionRequest(
            food_prepared_kg=50.0,
            food_sold_kg=38.0,
            food_category="cooked",
            day_of_week="Monday",
            date=date(2026, 8, 28),
        )
    )
    assert result.predicted_surplus_kg == 12.5
    assert result.preparation_recommendation == "Reduce prepared quantity"
    assert result.recommended_prepare_kg == 40.0
    assert result.input_echo.food_category == "cooked"
    assert result.model_version == "v1"


def test_predict_surplus_posts_payload_json() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = request.read().decode()
        captured["content_type"] = request.headers.get("content-type")
        captured["url"] = str(request.url)
        return httpx.Response(
            200,
            json={
                "predicted_surplus_kg": 1.0,
                "preparation_recommendation": "ok",
                "recommended_prepare_kg": 2.0,
                "input_echo": {
                    "food_prepared_kg": 5.0,
                    "food_sold_kg": 4.0,
                    "food_category": "bakery",
                    "day_of_week": "Tuesday",
                    "date": "2026-08-28",
                },
            },
        )

    client = make_client(handler)
    client.predict_surplus(
        SurplusPredictionRequest(
            food_prepared_kg=5.0,
            food_sold_kg=4.0,
            food_category="bakery",
            day_of_week="Tuesday",
            date=date(2026, 8, 28),
        )
    )

    assert "http://ai.test/api/v1/prediction/predict-surplus" == captured["url"]
    assert captured["content_type"] == "application/json"
    assert '"food_category":"bakery"' in captured["body"].replace(" ", "")


def test_predict_surplus_short_circuits_http_errors() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, json={"detail": "model not found"})

    client = make_client(handler)
    with pytest.raises(AIServiceHTTPError) as exc_info:
        client.predict_surplus(
            SurplusPredictionRequest(
                food_prepared_kg=1.0,
                food_sold_kg=0.0,
                food_category="raw",
                day_of_week="Wednesday",
                date=date(2026, 8, 28),
            )
        )
    assert exc_info.value.status_code == 404
    assert "model not found" in str(exc_info.value)


def test_non_json_response_raises_controlled_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content="not-json")

    client = make_client(handler)
    with pytest.raises(AIServiceHTTPError):
        client.predict_surplus(
            SurplusPredictionRequest(
                food_prepared_kg=1.0,
                food_sold_kg=0.0,
                food_category="raw",
                day_of_week="Wednesday",
                date=date(2026, 8, 28),
            )
        )


def test_transport_failure_maps_to_unavailable() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    client = make_client(handler)
    with pytest.raises(AIServiceUnavailableError):
        client.predict_surplus(
            SurplusPredictionRequest(
                food_prepared_kg=1.0,
                food_sold_kg=0.0,
                food_category="raw",
                day_of_week="Wednesday",
                date=date(2026, 8, 28),
            )
        )


def test_timeout_maps_to_unavailable() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("read timeout")

    client = make_client(handler)
    with pytest.raises(AIServiceUnavailableError):
        client.verify_safety(
            SafetyCheckRequest(
                donation_id="DON1",
                food_category="cooked",
                prepared_at=datetime.now(UTC) - timedelta(hours=1),
                storage_condition="refrigerated",
            )
        )


def test_rank_ngos_returns_match_response() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/matching/rank-ngos"
        return httpx.Response(
            200,
            json={
                "donation_id": "DON1",
                "ranked_ngos": [
                    {
                        "ngo_id": "NGO2",
                        "ngo_name": "Helping Hands",
                        "distance_km": 1.2,
                        "distance_source": "road",
                        "distance_score": 0.9,
                        "quantity_fit_score": 1.0,
                        "dietary_compatibility_score": 1.0,
                        "pickup_time_feasibility_score": 1.0,
                        "restaurant_reliability_score": 0.8,
                        "final_score": 0.94,
                        "rank": 1,
                    }
                ],
                "weights_used": {"distance": 0.30},
            },
        )

    client = make_client(handler)
    result = client.rank_ngos(
        MatchRequest(
            donation={
                "donation_id": "DON1",
                "restaurant_id": "REST1",
                "restaurant_latitude": 18.5,
                "restaurant_longitude": 73.8,
                "quantity_kg": 10.0,
                "dietary_type": "veg",
                "pickup_time": "18:00",
                "restaurant_reliability_score": 85.0,
            },
            candidate_ngos=[
                {
                    "ngo_id": "NGO2",
                    "name": "Helping Hands",
                    "latitude": 18.51,
                    "longitude": 73.81,
                    "dietary_accepted": ["veg", "any"],
                    "max_capacity_kg": 20.0,
                    "min_capacity_kg": 1.0,
                    "available_from": "16:00",
                    "available_to": "21:00",
                }
            ],
        )
    )
    assert result.donation_id == "DON1"
    assert result.ranked_ngos[0].ngo_id == "NGO2"
    assert result.ranked_ngos[0].rank == 1
    assert result.ranked_ngos[0].distance_source == "road"


def test_check_escalation_returns_action() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/escalation/check"
        return httpx.Response(
            200,
            json={
                "donation_id": "DON1",
                "action": "escalate",
                "next_ngo_id": "NGO2",
                "next_ngo_index": 1,
                "minutes_elapsed": 16.0,
                "message": "Offer timed out.",
            },
        )

    client = make_client(handler)
    result = client.check_escalation(
        EscalationCheckRequest(
            donation_id="DON1",
            ranked_ngo_ids=["NGO1", "NGO2"],
            current_ngo_index=0,
            current_ngo_status="pending",
            offer_sent_at=datetime.now(UTC) - timedelta(minutes=20),
            timeout_minutes=15,
        )
    )
    assert result.action == "escalate"
    assert result.next_ngo_id == "NGO2"
    assert result.minutes_elapsed == 16.0


def test_calculate_reliability_returns_score() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/reliability/calculate"
        return httpx.Response(
            200,
            json={
                "restaurant_id": "REST1",
                "reliability_score": 90.0,
                "grade": "Excellent",
                "breakdown": {"completion": 40.0},
            },
        )

    client = make_client(handler)
    result = client.calculate_reliability(
        ReliabilityInput(
            restaurant_id="REST1",
            total_donations_offered=10,
            total_donations_completed=9,
            total_donations_accepted=9,
            total_cancellations=1,
            average_ngo_rating=4.5,
        )
    )
    assert result.reliability_score == 90.0
    assert result.grade == "Excellent"


def test_verify_safety_returns_verdict() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/safety/verify"
        return httpx.Response(
            200,
            json={
                "donation_id": "DON1",
                "verdict": "Eligible",
                "hours_since_preparation": 2.0,
                "reasons": ["Fresh enough"],
            },
        )

    client = make_client(handler)
    result = client.verify_safety(
        SafetyCheckRequest(
            donation_id="DON1",
            food_category="cooked",
            prepared_at=datetime.now(UTC) - timedelta(hours=2),
            storage_condition="refrigerated",
        )
    )
    assert result.verdict == "Eligible"
    assert result.hours_since_preparation == 2.0


def test_generate_acknowledgment_returns_metadata() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/donation/generate-acknowledgment"
        return httpx.Response(
            200,
            json={
                "donation_id": "DON1",
                "pdf_filename": "acknowledgment_DON1.pdf",
                "file_path": "/tmp/acknowledgment_DON1.pdf",
                "message": "Acknowledgment PDF generated successfully.",
            },
        )

    client = make_client(handler)
    result = client.generate_acknowledgment(
        DonationAcknowledgmentRequest(
            donation_id="DON1",
            restaurant_name="Spice Garden",
            ngo_name="Helping Hands",
            food_details="Veg thali",
            quantity_kg=12.0,
            donation_datetime=datetime.now(UTC),
            completion_status="Completed",
        )
    )
    assert result.pdf_filename == "acknowledgment_DON1.pdf"
    assert result.file_path == "/tmp/acknowledgment_DON1.pdf"


def test_download_acknowledgment_returns_bytes() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/donation/download/DON1"
        return httpx.Response(200, content=b"%PDF-1.4 fake", headers={"content-type": "application/pdf"})

    client = make_client(handler)
    content = client.download_acknowledgment("DON1")
    assert content == b"%PDF-1.4 fake"


def test_download_missing_acknowledgment_maps_to_http_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, json={"detail": "No acknowledgment PDF found for donation_id 'X'."})

    client = make_client(handler)
    with pytest.raises(AIServiceHTTPError) as exc_info:
        client.download_acknowledgment("X")
    assert exc_info.value.status_code == 404
    assert "No acknowledgment PDF found" in str(exc_info.value)


def test_unconfigured_client_raises_configuration_error() -> None:
    with pytest.raises(AIServiceConfigurationError):
        AIClient(base_url="   ")


def test_http_error_is_aiservice_error() -> None:
    assert issubclass(AIServiceHTTPError, AIServiceError)
    assert issubclass(AIServiceUnavailableError, AIServiceError)