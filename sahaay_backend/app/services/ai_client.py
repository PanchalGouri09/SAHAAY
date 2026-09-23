"""
Server-to-server HTTP client for the SAHAAY AI & Smart Features service.

The main backend talks to the standalone AI microservice only through this
client. It contains no AI logic; it only marshals requests/responses and
converts transport or HTTP failures into controlled backend exceptions.

The AI service must remain a separate, stateless microservice.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Any

import httpx

from app.config import get_settings
from app.schemas.ai import (
    DonationAcknowledgmentRequest,
    DonationAcknowledgmentResponse,
    EscalationCheckRequest,
    EscalationCheckResponse,
    MatchRequest,
    MatchResponse,
    ReliabilityInput,
    ReliabilityResponse,
    SafetyCheckRequest,
    SafetyCheckResponse,
    SurplusPredictionRequest,
    SurplusPredictionResponse,
)


class AIServiceError(Exception):
    """Base class for controlled backend errors caused by the AI service."""

    def __init__(self, message: str, *, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


class AIServiceUnavailableError(AIServiceError):
    """The AI service could not be reached or did not respond in time."""

    def __init__(self) -> None:
        super().__init__("The AI service is currently unreachable. Please try again later.")


class AIServiceHTTPError(AIServiceError):
    """The AI service returned an unsuccessful HTTP response."""

    def __init__(self, message: str, *, status_code: int | None = None) -> None:
        super().__init__(message, status_code=status_code)


class AIServiceConfigurationError(AIServiceError):
    """AI_SERVICE_URL is not configured."""

    def __init__(self) -> None:
        super().__init__("AI_SERVICE_URL is not configured on this server.")


class AIClient:
    """Typed, server-to-server HTTP client for the SAHAAY AI service."""

    def __init__(
        self,
        base_url: str | None = None,
        timeout: float | None = None,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        settings = get_settings()
        base = (base_url or settings.ai_service_url).strip()
        if not base:
            raise AIServiceConfigurationError()
        self.base_url = base.rstrip("/")
        self._timeout = timeout or settings.ai_request_timeout_seconds
        self._client = httpx.Client(base_url=self.base_url, timeout=self._timeout, transport=transport)

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "AIClient":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # ------------------------------------------------------------------
    # Public typed methods
    # ------------------------------------------------------------------

    def predict_surplus(self, payload: SurplusPredictionRequest) -> SurplusPredictionResponse:
        data = self._post_json("/api/v1/prediction/predict-surplus", payload)
        return SurplusPredictionResponse.model_validate(data)

    def rank_ngos(self, payload: MatchRequest) -> MatchResponse:
        data = self._post_json("/api/v1/matching/rank-ngos", payload)
        return MatchResponse.model_validate(data)

    def check_escalation(self, payload: EscalationCheckRequest) -> EscalationCheckResponse:
        data = self._post_json("/api/v1/escalation/check", payload)
        return EscalationCheckResponse.model_validate(data)

    def calculate_reliability(self, payload: ReliabilityInput) -> ReliabilityResponse:
        data = self._post_json("/api/v1/reliability/calculate", payload)
        return ReliabilityResponse.model_validate(data)

    def verify_safety(self, payload: SafetyCheckRequest) -> SafetyCheckResponse:
        data = self._post_json("/api/v1/safety/verify", payload)
        return SafetyCheckResponse.model_validate(data)

    def generate_acknowledgment(
        self, payload: DonationAcknowledgmentRequest
    ) -> DonationAcknowledgmentResponse:
        data = self._post_json("/api/v1/donation/generate-acknowledgment", payload)
        return DonationAcknowledgmentResponse.model_validate(data)

    def download_acknowledgment(self, donation_id: str) -> bytes:
        path = f"/api/v1/donation/download/{donation_id}"
        try:
            response = self._client.get(path)
        except httpx.TimeoutException as exc:
            raise AIServiceUnavailableError() from exc
        except httpx.RequestError as exc:
            raise AIServiceUnavailableError() from exc
        self._raise_for_status(response)
        return response.content

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _post_json(self, path: str, payload: Any) -> dict[str, Any]:
        try:
            response = self._client.post(path, json=payload.model_dump(mode="json"))
        except httpx.TimeoutException as exc:
            raise AIServiceUnavailableError() from exc
        except httpx.RequestError as exc:
            raise AIServiceUnavailableError() from exc
        self._raise_for_status(response)
        try:
            return response.json()
        except ValueError as exc:
            raise AIServiceHTTPError(
                "The AI service returned an unparseable response.",
                status_code=response.status_code,
            ) from exc

    def _raise_for_status(self, response: httpx.Response) -> None:
        if 200 <= response.status_code < 300:
            return
        try:
            body = response.json()
        except ValueError:
            body = None
        detail = None
        if isinstance(body, dict):
            detail = body.get("detail") or body.get("message")
        message = f"AI service request failed with status {response.status_code}."
        if detail:
            message = f"AI service error ({response.status_code}): {detail}"
        raise AIServiceHTTPError(message, status_code=response.status_code)


@lru_cache
def get_ai_client() -> AIClient:
    """Cached shared AI client, configured from server settings."""
    return AIClient()