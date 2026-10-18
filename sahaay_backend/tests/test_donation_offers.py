from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.routers import ai_features, donation_offers
from app.main import app
from app.routers import donations
from app.schemas.donation import DonationCreate
from app.services import donation_offers as offers


class _RpcCall:
    def __init__(self, response):
        self.response = response

    def execute(self):
        return SimpleNamespace(data=self.response)


class _Client:
    def __init__(self, response=None):
        self.response = response or {}
        self.rpc_calls = []

    def rpc(self, name, params):
        self.rpc_calls.append((name, params))
        return _RpcCall(self.response)


class _ReadQuery:
    def __init__(self, rows):
        self.rows = rows
        self.filters = []
        self.single = False
        self.selected_columns = None
        self.row_range = None

    def select(self, *args):
        self.selected_columns = args[0] if args else None
        return self

    def eq(self, key, value):
        self.filters.append(("eq", key, value))
        return self

    def or_(self, expression):
        self.filters.append(("or", expression))
        return self

    def gt(self, key, value):
        self.filters.append(("gt", key, value))
        return self

    def in_(self, key, values):
        self.filters.append(("in", key, list(values)))
        return self

    def order(self, *_args, **_kwargs):
        return self

    def range(self, start, end):
        self.row_range = (start, end)
        return self

    def limit(self, _count):
        return self

    def maybe_single(self):
        self.single = True
        return self

    def execute(self):
        rows = list(self.rows)
        for filter_item in self.filters:
            kind = filter_item[0]
            if kind == "or":
                alternatives = []
                for clause in filter_item[1].split(","):
                    field, operator, raw = clause.split(".", 2)
                    if operator == "eq":
                        expected = raw == "true" if raw in {"true", "false"} else raw
                        alternatives.append((field, expected))
                rows = [
                    row
                    for row in rows
                    if any(row.get(field) == expected for field, expected in alternatives)
                ]
                continue
            _, key, value = filter_item
            if kind == "eq":
                rows = [row for row in rows if row.get(key) == value]
            elif kind == "in":
                rows = [row for row in rows if row.get(key) in value]
            elif kind == "gt":
                rows = [row for row in rows if row.get(key) > value]
        if self.row_range is not None:
            start, end = self.row_range
            rows = rows[start : end + 1]
        return SimpleNamespace(data=(rows[0] if rows else None) if self.single else rows)


class _ReadClient:
    def __init__(self, tables):
        self.tables = tables
        self.reads = []
        self.queries = []

    def table(self, name):
        self.reads.append(name)
        query = _ReadQuery(self.tables.get(name, []))
        self.queries.append((name, query))
        return query


class _InsertQuery:
    def __init__(self, row):
        self.row = row

    def insert(self, values):
        self.row = {**values, "id": "created-donation"}
        return self

    def select(self):
        return self

    def execute(self):
        return SimpleNamespace(data=[self.row])


class _CreateClient:
    def __init__(self):
        self.donation = {}

    def table(self, name):
        assert name == "donations"
        return _InsertQuery(self.donation)


def _rank(ngo_id: str, rank: int, score: float) -> dict:
    return {
        "ngo_id": ngo_id,
        "ngo_name": f"NGO {ngo_id}",
        "rank": rank,
        "final_score": score,
        "distance_km": 2.5,
        "distance_source": "road",
        "distance_score": 90,
        "quantity_fit_score": 80,
        "dietary_compatibility_score": 100,
        "pickup_time_feasibility_score": 70,
        "restaurant_reliability_score": 60,
    }


def test_ranked_candidates_keep_match_order_and_real_scores():
    rows = offers._ranked_candidate_rows(
        [_rank("ngo-second", 2, 87.5), _rank("ngo-first", 1, 91.25), _rank("ngo-second", 2, 87.5)]
    )

    assert [row["ngo_id"] for row in rows] == ["ngo-second", "ngo-first"]
    assert [row["match_rank"] for row in rows] == [1, 2]
    assert [row["ai_rank"] for row in rows] == [2, 1]
    assert rows[0]["final_score"] == 87.5
    assert rows[0]["score_details"]["distance_km"] == 2.5
    assert rows[0]["score_details"]["distance_source"] == "road"


def test_persist_ranked_candidates_starts_one_offer_and_notifies_its_ngo(monkeypatch):
    offer = {
        "id": "offer-1",
        "donation_id": "donation-1",
        "ngo_id": "ngo-1",
        "candidate_rank": 1,
        "status": "pending",
        "offer_expires_at": "2026-10-14T00:05:00+00:00",
    }
    client = _Client({"status": "offered", "offer": offer})
    notified = []
    monkeypatch.setattr(offers, "_notify_offer", lambda *_a, **kw: notified.append(kw["offer"]))

    result = offers.persist_ranked_candidates(
        client,
        donation_id="donation-1",
        ranked_ngos=[_rank("ngo-1", 1, 95)],
    )

    assert result["status"] == "offered"
    assert len(client.rpc_calls) == 1
    name, params = client.rpc_calls[0]
    assert name == "start_donation_offer_sequence"
    assert params["p_donation_id"] == "donation-1"
    assert params["p_candidates"][0]["ngo_id"] == "ngo-1"
    assert params["p_candidates"][0]["final_score"] == 95
    assert notified == [offer]


def test_offer_notification_uses_server_resolved_ngo_and_donation(monkeypatch):
    client = _ReadClient(
        {"donations": [{"id": "donation-1", "food_name": "Cooked rice"}]}
    )
    recipients = []
    notifications = []
    monkeypatch.setattr(
        offers.notification_service,
        "user_id_for_ngo",
        lambda _client, ngo_id: recipients.append(ngo_id) or "ngo-user-1",
    )
    monkeypatch.setattr(
        offers.notification_service,
        "notify",
        lambda *args, **kwargs: notifications.append((args, kwargs)),
    )

    offers._notify_offer(
        client,
        offer={
            "id": "offer-1",
            "donation_id": "donation-1",
            "ngo_id": "ngo-1",
            "offer_expires_at": "2026-10-14T00:05:00+00:00",
        },
    )

    assert recipients == ["ngo-1"]
    args, kwargs = notifications[0]
    assert args[1] == "ngo-user-1"
    assert kwargs["related_donation_id"] == "donation-1"
    assert kwargs["notif_type"] == "donation_offer"
    assert kwargs["data"] == {"screen": "my_offers"}
    assert kwargs["title"] == "A food donation is available"
    assert "Cooked rice is available for pickup" in kwargs["message"]
    assert "offer-1" not in kwargs["message"]
    assert "2026-10-14" not in kwargs["message"]
    assert "before the offer expires" in kwargs["message"]


def test_offer_notification_uses_human_fallback_when_food_name_is_missing(
    monkeypatch,
):
    notifications = []
    monkeypatch.setattr(
        offers,
        "_load_donation",
        lambda *_args: {"id": "donation-1", "food_name": None},
    )
    monkeypatch.setattr(
        offers.notification_service,
        "user_id_for_ngo",
        lambda *_args: "ngo-user",
    )
    monkeypatch.setattr(
        offers.notification_service,
        "notify",
        lambda *args, **kwargs: notifications.append((args, kwargs)),
    )

    offers._notify_offer(
        object(),
        offer={
            "id": "offer-1",
            "donation_id": "donation-1",
            "ngo_id": "ngo-1",
        },
    )

    args, kwargs = notifications[0]
    assert args[1] == "ngo-user"
    assert kwargs["title"] == "A food donation is available"
    assert kwargs["message"] == (
        "A food donation is available for pickup. Review the details and respond "
        "before the offer expires."
    )
    assert "offer-1" not in kwargs["title"]
    assert "offer-1" not in kwargs["message"]


def test_no_match_notifies_provider_with_clear_nontechnical_copy(monkeypatch):
    notifications = []
    monkeypatch.setattr(
        offers,
        "_load_donation",
        lambda *_args: {
            "id": "donation-7",
            "provider_id": "provider-1",
            "food_name": "Dal",
        },
    )
    monkeypatch.setattr(
        offers.notification_service,
        "user_id_for_provider",
        lambda _client, provider_id: (
            "provider-user" if provider_id == "provider-1" else None
        ),
    )
    monkeypatch.setattr(
        offers.notification_service,
        "notify",
        lambda *args, **kwargs: notifications.append((args, kwargs)),
    )

    offers._notify_provider_no_match(object(), "donation-7")

    args, kwargs = notifications[0]
    assert args[1] == "provider-user"
    assert kwargs["notif_type"] == "donation_no_match"
    assert kwargs["title"] == "No NGO match yet"
    assert kwargs["message"] == (
        "We couldn't find an eligible NGO for your Dal donation. Open SAHAAY to "
        "review your options."
    )
    assert kwargs["related_donation_id"] == "donation-7"


def test_persisted_no_candidate_result_triggers_provider_notice(monkeypatch):
    client = _Client({"status": "no_candidates"})
    notified = []
    monkeypatch.setattr(
        offers,
        "_notify_provider_no_match",
        lambda _client, donation_id: notified.append(donation_id),
    )

    result = offers.persist_ranked_candidates(
        client, donation_id="donation-7", ranked_ngos=[]
    )

    assert result["status"] == "no_candidates"
    assert notified == ["donation-7"]


@pytest.mark.parametrize(
    ("outcome", "expected_title", "copy"),
    [
        ("declined", "Finding your next NGO match", "An NGO declined the offer for Dal"),
        ("timed_out", "Finding your next NGO match", "The offer for Dal expired"),
    ],
)
def test_decline_and_timeout_notify_provider_with_readable_copy(
    monkeypatch, outcome, expected_title, copy
):
    notifications = []
    monkeypatch.setattr(
        offers,
        "_load_donation",
        lambda *_args: {
            "id": "donation-7",
            "provider_id": "provider-1",
            "food_name": "Dal",
        },
    )
    monkeypatch.setattr(
        offers.notification_service,
        "user_id_for_provider",
        lambda *_args: "provider-user",
    )
    monkeypatch.setattr(
        offers.notification_service,
        "notify",
        lambda *args, **kwargs: notifications.append((args, kwargs)),
    )

    offers._notify_provider_offer_advanced(
        object(), donation_id="donation-7", outcome=outcome
    )

    args, kwargs = notifications[0]
    assert args[1] == "provider-user"
    assert kwargs["title"] == expected_title
    assert copy in kwargs["message"]
    assert "donation-7" not in kwargs["message"]
    assert kwargs["dedupe"] is False
    assert kwargs["notif_type"] == "donation_offer"


@pytest.mark.parametrize(
    ("event", "expected_title", "expected_body"),
    [
        (
            "provider_exhausted",
            "No NGO match yet",
            "We couldn't find another eligible NGO for your Dal donation. Open "
            "SAHAAY to review your options.",
        ),
        (
            "provider_timed_out",
            "Finding your next NGO match",
            "The offer expired after no response. We're offering the donation to the next "
            "eligible NGO.",
        ),
        (
            "ngo_accepted",
            "Donation confirmed",
            "Your claim is confirmed. Open SAHAAY to view pickup and handover details.",
        ),
    ],
)
def test_donation_notification_copy_uses_clear_fallbacks(
    event, expected_title, expected_body
):
    from app.services.notification_service import donation_notification_copy

    title, body = donation_notification_copy(
        event, "Dal" if event == "provider_exhausted" else None
    )

    assert title == expected_title
    assert body == expected_body


def test_closed_offer_notification_explains_that_the_donation_is_unavailable(
    monkeypatch,
):
    notifications = []
    monkeypatch.setattr(
        offers,
        "_load_donation",
        lambda *_args: {"id": "donation-1", "provider_id": "provider-1", "food_name": "Dal"},
    )
    monkeypatch.setattr(
        offers.notification_service,
        "user_id_for_provider",
        lambda *_args: "provider-user",
    )
    monkeypatch.setattr(
        offers.notification_service,
        "notify",
        lambda *args, **kwargs: notifications.append((args, kwargs)),
    )

    offers._notify_provider_offer_closed(object(), "donation-1")

    _, kwargs = notifications[0]
    assert kwargs["title"] == "Offer closed"
    assert kwargs["message"] == (
        "The offer for Dal was closed because the donation is no longer available."
    )


def test_new_donation_matching_reuses_existing_provider_matching_path(monkeypatch):
    client = _Client({"status": "no_candidates"})
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda donation_id, profile, ai_client: {
            "status": "ok",
            "donation_id": donation_id,
            "ranked_ngos": [_rank("ngo-1", 1, 90)],
        },
    )

    result = offers.auto_start_offers_for_donation(
        client,
        donation={"id": "donation-7"},
        profile={"providers": [{"id": "provider-1"}]},
        ai_client=object(),
    )

    assert result["status"] == "no_candidates"
    assert client.rpc_calls[0][1]["p_donation_id"] == "donation-7"


def test_successful_donation_creation_starts_server_side_matching(monkeypatch):
    client = _CreateClient()
    started = []
    now = datetime.now(timezone.utc)
    payload = DonationCreate(
        food_name="Dal",
        food_category="cooked",
        veg_type="vegetarian",
        quantity=2,
        unit="kg",
        food_image_url="https://example.invalid/dal.jpg",
        prepared_at=now,
        expiry_time=now + timedelta(hours=3),
        pickup_deadline=now + timedelta(hours=2),
        pickup_address="1 Main Street",
        storage_condition="refrigerated",
    )
    monkeypatch.setattr(donations, "_provider_id_of", lambda _profile: "provider-1")
    monkeypatch.setattr(
        donations,
        "_verify_safety",
        lambda *_args: SimpleNamespace(verdict="Eligible", reasons=[]),
    )
    monkeypatch.setattr(donations, "map_food_category", lambda _category: "cooked")
    monkeypatch.setattr(donations, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        donations.notification_service,
        "donation_created",
        lambda *_args, **_kwargs: None,
    )
    ai_client = object()
    monkeypatch.setattr(
        donations,
        "auto_start_offers_for_donation",
        lambda *args, **kwargs: started.append(
            (
                kwargs["donation"]["id"],
                kwargs["profile"],
                kwargs["ai_client"] is ai_client,
            )
        ),
    )

    profile = {
        "role": "provider",
        "full_name": "Provider Contact",
        "email": "provider@example.org",
        "phone": "+91 9876543210",
        "providers": [
            {
                "id": "provider-1",
                "organization_name": "Kitchen",
                "address": "1 Main Street",
                "city": "Pune",
                "latitude": 18.52,
                "longitude": 73.85,
            }
        ],
    }
    result = donations.create_donation(
        payload,
        profile,
        ai_client,
    )

    assert result["id"] == "created-donation"
    assert started == [
        ("created-donation", profile, True)
    ]


def test_auto_matching_does_not_persist_an_ineligible_matching_result(monkeypatch):
    client = _Client()
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: {"status": "insufficient_data", "reason": "No usable location."},
    )

    result = offers.auto_start_offers_for_donation(
        client,
        donation={"id": "donation-8"},
        profile={"providers": [{"id": "provider-1"}]},
        ai_client=object(),
    )

    assert result == {"status": "insufficient_data", "reason": "No usable location."}
    assert client.rpc_calls == []


def test_concurrent_or_replayed_response_has_no_duplicate_notification(monkeypatch):
    client = _Client({"status": "accepted", "changed": False})
    notifications = []
    monkeypatch.setattr(
        offers.notification_service,
        "claim_status_changed",
        lambda *_args, **_kwargs: notifications.append("claim"),
    )
    monkeypatch.setattr(
        offers, "_notify_offer", lambda *_args, **_kwargs: notifications.append("offer")
    )

    result = offers.respond_to_offer(
        client, offer_id="offer-1", ngo_id="ngo-1", decision="accepted"
    )

    assert result["changed"] is False
    assert notifications == []
    assert client.rpc_calls[0][1]["p_ngo_id"] == "ngo-1"


def test_accepted_offer_notifies_via_existing_claim_event_service(monkeypatch):
    claim = {
        "id": "claim-1",
        "donation_id": "donation-1",
        "ngo_id": "ngo-1",
        "status": "accepted",
    }
    client = _Client(
        {
            "status": "accepted",
            "changed": True,
            "donation_id": "donation-1",
            "claim": claim,
            "other_pending_ngo_ids": ["ngo-2"],
        }
    )
    notifications = []
    monkeypatch.setattr(
        offers,
        "_load_donation",
        lambda *_args: {"id": "donation-1", "food_name": "Rice"},
    )
    monkeypatch.setattr(
        offers.notification_service,
        "claim_status_changed",
        lambda *args, **kwargs: notifications.append((args, kwargs)),
    )

    offers.respond_to_offer(
        client, offer_id="offer-1", ngo_id="ngo-1", decision="accepted"
    )

    args, kwargs = notifications[0]
    assert kwargs["claim"] == claim
    assert kwargs["new_status"] == "accepted"
    assert kwargs["other_pending_ngo_ids"] == ["ngo-2"]
    assert kwargs["donation"]["id"] == "donation-1"


def test_decline_notifies_only_the_next_active_offer(monkeypatch):
    next_offer = {
        "id": "offer-2",
        "donation_id": "donation-1",
        "ngo_id": "ngo-2",
    }
    client = _Client(
        {
            "status": "declined",
            "changed": True,
            "donation_id": "donation-1",
            "next_offer": next_offer,
        }
    )
    notified = []
    exhausted = []
    provider_updates = []
    monkeypatch.setattr(offers, "_notify_offer", lambda *_a, **kw: notified.append(kw["offer"]))
    monkeypatch.setattr(
        offers,
        "_notify_provider_offer_advanced",
        lambda _client, **kwargs: provider_updates.append(kwargs),
    )
    monkeypatch.setattr(
        offers,
        "_notify_provider_exhausted",
        lambda *_a: exhausted.append(True),
    )

    result = offers.respond_to_offer(
        client, offer_id="offer-1", ngo_id="ngo-1", decision="declined"
    )

    assert result["status"] == "declined"
    assert notified == [next_offer]
    assert exhausted == []
    assert provider_updates == [
        {"donation_id": "donation-1", "outcome": "declined"}
    ]


def test_timeout_notifies_provider_and_next_ngo(monkeypatch):
    next_offer = {"id": "offer-2", "donation_id": "donation-1", "ngo_id": "ngo-2"}
    provider_updates = []
    next_notifications = []
    monkeypatch.setattr(
        offers,
        "_notify_provider_offer_advanced",
        lambda _client, **kwargs: provider_updates.append(kwargs),
    )
    monkeypatch.setattr(
        offers,
        "_notify_offer",
        lambda _client, **kwargs: next_notifications.append(kwargs["offer"]),
    )

    offers._notify_response_result(
        object(),
        {
            "status": "timed_out",
            "changed": True,
            "donation_id": "donation-1",
            "next_offer": next_offer,
        },
    )

    assert provider_updates == [
        {"donation_id": "donation-1", "outcome": "timed_out"}
    ]
    assert next_notifications == [next_offer]


def test_final_timeout_notifies_provider_that_ranked_offers_are_exhausted(monkeypatch):
    exhausted = []
    monkeypatch.setattr(
        offers,
        "_notify_provider_exhausted",
        lambda _client, donation_id: exhausted.append(donation_id),
    )

    offers._notify_response_result(
        object(),
        {
            "status": "timed_out",
            "changed": True,
            "donation_id": "donation-1",
            "exhausted": True,
        },
    )

    assert exhausted == ["donation-1"]


def test_closed_donation_notifies_provider_that_offer_is_no_longer_available(
    monkeypatch,
):
    closed = []
    monkeypatch.setattr(
        offers,
        "_notify_provider_offer_closed",
        lambda _client, donation_id: closed.append(donation_id),
    )

    offers._notify_response_result(
        object(),
        {
            "status": "expired",
            "changed": True,
            "donation_id": "donation-1",
        },
    )

    assert closed == ["donation-1"]


def test_scheduler_polls_persisted_deadlines_using_database_clock(monkeypatch):
    transition = {"status": "timed_out", "changed": True}
    client = _Client(
        {"checked": 1, "advanced": 1, "results": [transition]}
    )
    transitions = []
    monkeypatch.setattr(offers, "_notify_response_result", lambda _client, result: transitions.append(result))

    outcome = offers.expire_due_offers(client)

    assert outcome == {"checked": 1, "advanced": 1}
    name, params = client.rpc_calls[0]
    assert name == "expire_due_donation_offers"
    assert params == {"p_limit": 100}
    assert transitions == [transition]


def test_offer_endpoint_uses_authenticated_ngo_id(monkeypatch):
    calls = []
    monkeypatch.setattr(
        donation_offers,
        "get_supabase_client",
        lambda: object(),
    )
    monkeypatch.setattr(
        donation_offers,
        "respond_to_offer",
        lambda client, **kwargs: calls.append(kwargs)
        or {"status": "declined", "changed": True},
    )

    result = donation_offers.respond(
        "offer-9",
        donation_offers.OfferResponse(decision="declined"),
        {"ngos": [{"id": "authenticated-ngo"}]},
    )

    assert result["changed"] is True
    assert calls == [
        {
            "offer_id": "offer-9",
            "ngo_id": "authenticated-ngo",
            "decision": "declined",
        }
    ]


def test_accepting_offer_uses_server_profile_id_without_contact_gate(monkeypatch):
    calls = []
    profile = {
        "id": "user-row-id",
        "firebase_uid": "firebase-uid",
        "role": "ngo",
        "full_name": "NGO Contact",
        "email": "ngo@example.org",
        "phone": "+91 9876543210",
        "ngos": [
            {
                "id": "ngo-profile-id",
                "organization_name": "Community Pantry",
                "address": "2 Market Street",
                "city": "Pune",
                "latitude": 18.53,
                "longitude": 73.86,
                "available_from": "07:00",
                "available_to": "22:00",
                "max_capacity_kg": 25.0,
                "preferred_food_types": ["Cooked Meals"],
                "dietary_preferences": ["vegetarian"],
            }
        ],
    }
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: object())
    monkeypatch.setattr(
        donation_offers,
        "respond_to_offer",
        lambda _client, **kwargs: calls.append(kwargs)
        or {"status": "accepted", "changed": True},
    )

    result = donation_offers.respond(
        "offer-1",
        donation_offers.OfferResponse(decision="accepted"),
        profile,
    )

    assert result == {"status": "accepted", "changed": True}
    assert calls == [
        {
            "offer_id": "offer-1",
            "ngo_id": "ngo-profile-id",
            "decision": "accepted",
        }
    ]


@pytest.mark.parametrize("status", ["accepted", "declined"])
def test_replayed_offer_response_is_a_conflict(monkeypatch, status):
    monkeypatch.setattr(
        donation_offers, "require_complete_profile", lambda *_args, **_kwargs: None
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: object())
    monkeypatch.setattr(
        donation_offers,
        "respond_to_offer",
        lambda *_args, **_kwargs: {"status": status, "changed": False},
    )

    with pytest.raises(HTTPException) as error:
        donation_offers.respond(
            "offer-1",
            donation_offers.OfferResponse(decision="accepted"),
            {"ngos": [{"id": "ngo-1"}]},
        )

    assert error.value.status_code == 409
    assert "already been responded to" in error.value.detail


def test_timed_out_offer_cannot_be_accepted(monkeypatch):
    monkeypatch.setattr(
        donation_offers, "require_complete_profile", lambda *_args, **_kwargs: None
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: object())
    monkeypatch.setattr(
        donation_offers,
        "respond_to_offer",
        lambda *_args, **_kwargs: {"status": "timed_out", "changed": False},
    )

    with pytest.raises(HTTPException) as error:
        donation_offers.respond(
            "offer-1",
            donation_offers.OfferResponse(decision="accepted"),
            {"ngos": [{"id": "ngo-1"}]},
        )

    assert error.value.status_code == 409
    assert "deadline has passed" in error.value.detail


def test_offer_for_another_ngo_is_forbidden(monkeypatch):
    monkeypatch.setattr(
        donation_offers, "require_complete_profile", lambda *_args, **_kwargs: None
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: object())
    monkeypatch.setattr(
        donation_offers,
        "respond_to_offer",
        lambda *_args, **_kwargs: {
            "status": "not_your_offer",
            "changed": False,
        },
    )

    with pytest.raises(HTTPException) as error:
        donation_offers.respond(
            "offer-1",
            donation_offers.OfferResponse(decision="accepted"),
            {"ngos": [{"id": "different-ngo"}]},
        )

    assert error.value.status_code == 403


def test_provider_get_refreshes_candidates_and_returns_persisted_rank(monkeypatch):
    donation = {"id": "donation-1", "status": "available"}
    candidate = {"donation_id": "donation-1", "ngo_id": "ngo-1", "match_rank": 1}
    offer = {"id": "offer-1", "donation_id": "donation-1", "status": "pending"}
    client = _ReadClient(
        {
            "donation_match_candidates": [candidate],
            "ngos": [
                {
                    "id": "ngo-1",
                    "organization_name": "Community Kitchen",
                    "city": "Pune",
                    "address": "private address",
                    "phone": "private phone",
                    "user_id": "private user",
                }
            ],
            "donation_offers": [offer],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: donation,
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: {"status": "no_candidates"},
    )

    result = donation_offers.get_persisted_offers(
        "donation-1", {"providers": [{"id": "provider-1"}]}
    )

    assert result["matching_state"] == "active"
    assert result["ranked_candidates"] == [
        {
            **candidate,
            "ngo": {"organization_name": "Community Kitchen", "city": "Pune"},
        }
    ]
    assert result["current_offer"] == offer
    assert result["offers"] == [offer]
    assert client.reads == [
        "donation_match_candidates",
        "ngos",
        "donation_offers",
    ]
    ngo_query = next(query for table, query in client.queries if table == "ngos")
    assert ngo_query.selected_columns == (
        "id,organization_name,city,latitude,longitude"
    )
    assert set(result["ranked_candidates"][0]["ngo"]) == {
        "organization_name",
        "city",
    }
    assert result["refresh_warning"] is None


def test_provider_get_serves_saved_candidates_when_refresh_fails(monkeypatch):
    candidate = {"donation_id": "donation-1", "ngo_id": "ngo-1", "match_rank": 1}
    client = _ReadClient(
        {
            "donation_match_candidates": [candidate],
            "ngos": [
                {
                    "id": "ngo-1",
                    "organization_name": "Community Kitchen",
                    "city": "Pune",
                }
            ],
            "donation_offers": [],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: {"id": "donation-1", "status": "available"},
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: (_ for _ in ()).throw(
            HTTPException(status_code=502, detail="Matching service unavailable.")
        ),
    )

    result = donation_offers.get_persisted_offers(
        "donation-1", {"providers": [{"id": "provider-1"}]}
    )

    assert result["ranked_candidates"][0]["ngo_id"] == "ngo-1"
    assert result["refresh_warning"] == (
        "Matching refresh is unavailable; showing the last saved results."
    )


def test_provider_get_warns_when_saved_candidates_are_stale_after_incomplete_refresh(
    monkeypatch,
):
    candidate = {"donation_id": "donation-1", "ngo_id": "ngo-1", "match_rank": 1}
    client = _ReadClient(
        {
            "donation_match_candidates": [candidate],
            "ngos": [
                {
                    "id": "ngo-1",
                    "organization_name": "Community Kitchen",
                    "city": "Pune",
                }
            ],
            "donation_offers": [],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: {"id": "donation-1", "status": "available"},
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: {
            "status": "insufficient_data",
            "reason": "Donation dietary type is missing or unsupported.",
        },
    )

    result = donation_offers.get_persisted_offers(
        "donation-1", {"providers": [{"id": "provider-1"}]}
    )

    assert result["ranked_candidates"][0]["ngo_id"] == "ngo-1"
    assert "dietary type" in result["refresh_warning"]
    assert "Previously saved results are shown." in result["refresh_warning"]


def test_provider_get_returns_refresh_error_when_no_saved_candidates(monkeypatch):
    client = _ReadClient(
        {
            "donation_match_candidates": [],
            "ngos": [],
            "donation_offers": [],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: {"id": "donation-1", "status": "available"},
    )
    refresh_error = HTTPException(
        status_code=502, detail="Matching service unavailable."
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: (_ for _ in ()).throw(refresh_error),
    )

    with pytest.raises(HTTPException) as raised:
        donation_offers.get_persisted_offers(
            "donation-1", {"providers": [{"id": "provider-1"}]}
        )

    assert raised.value is refresh_error


def test_provider_and_ngo_reads_share_the_persisted_score_and_distance(monkeypatch):
    donation = {
        "id": "donation-1",
        "status": "available",
        "food_name": "Cooked rice",
        "provider_id": "provider-1",
        "quantity": 5,
        "unit": "kg",
        "pickup_address": "Main Road",
    }
    candidate = {
        "donation_id": "donation-1",
        "ngo_id": "ngo-1",
        "match_rank": 1,
        "ai_rank": 1,
        "final_score": 91.25,
        "score_details": {
            "distance_km": 2.4,
            "distance_source": "road",
            "distance_score": 95,
        },
    }
    offer = {
        "id": "offer-1",
        "donation_id": "donation-1",
        "ngo_id": "ngo-1",
        "candidate_rank": 1,
        "status": "pending",
        "offer_expires_at": "2026-10-16T01:05:00+00:00",
    }
    client = _ReadClient(
        {
            "donation_match_candidates": [candidate],
            "donation_offers": [offer],
            "donations": [donation],
            "ngos": [
                {
                    "id": "ngo-1",
                    "organization_name": "Community Kitchen",
                    "city": "Pune",
                }
            ],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: donation,
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: {"status": "no_candidates"},
    )

    provider_result = donation_offers.get_persisted_offers(
        "donation-1", {"providers": [{"id": "provider-1"}]}
    )
    ngo_result = donation_offers.list_ngo_offers({"ngos": [{"id": "ngo-1"}]})

    provider_candidate = provider_result["ranked_candidates"][0]
    ngo_candidate = ngo_result[0]["ranked_candidate"]
    assert provider_candidate["match_rank"] == ngo_result[0]["candidate_rank"] == 1
    assert provider_candidate["final_score"] == ngo_candidate["final_score"] == 91.25
    assert (
        provider_candidate["score_details"]["distance_km"]
        == ngo_candidate["score_details"]["distance_km"]
        == 2.4
    )
    assert provider_candidate["score_details"]["distance_source"] == "road"
    assert ngo_candidate["score_details"]["distance_source"] == "road"


def test_provider_persisted_read_explains_missing_complete_ngo_profiles(monkeypatch):
    client = _ReadClient(
        {
            "donation_match_candidates": [],
            "donation_offers": [],
            "ngos": [],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: {"id": "donation-1", "status": "available"},
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: {"status": "no_candidates"},
    )

    result = donation_offers.get_persisted_offers(
        "donation-1", {"providers": [{"id": "provider-1"}]}
    )

    assert result["matching_state"] == "no_matching_profiles"
    assert "completed NGO profiles" in result["matching_reason"]
    assert result["ranked_candidates"] == []


def test_provider_persisted_read_preserves_insufficient_donation_data(monkeypatch):
    client = _ReadClient(
        {
            "donation_match_candidates": [],
            "donation_offers": [],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: {"id": "donation-1", "status": "available"},
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: {
            "status": "insufficient_data",
            "reason": "Donation dietary type is missing or unsupported.",
        },
    )

    result = donation_offers.get_persisted_offers(
        "donation-1", {"providers": [{"id": "provider-1"}]}
    )

    assert result["matching_state"] == "insufficient_data"
    assert result["matching_reason"] == "Donation dietary type is missing or unsupported."
    assert result["ranked_candidates"] == []


def test_provider_persisted_read_preserves_real_no_candidate_reason(monkeypatch):
    client = _ReadClient(
        {
            "donation_match_candidates": [],
            "donation_offers": [],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: {"id": "donation-1", "status": "available"},
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: {
            "status": "no_candidates",
            "reason": "No NGO matches this donation's food and capacity requirements.",
        },
    )

    result = donation_offers.get_persisted_offers(
        "donation-1", {"providers": [{"id": "provider-1"}]}
    )

    assert result["matching_state"] == "no_candidates"
    assert result["matching_reason"] == (
        "No NGO matches this donation's food and capacity requirements."
    )


def test_ranked_matches_without_saved_rows_are_reported_as_persistence_failure(
    monkeypatch,
):
    client = _ReadClient(
        {
            "donation_match_candidates": [],
            "donation_offers": [],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: {"id": "donation-1", "status": "available"},
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: {"status": "ok", "ranked_ngos": [_rank("ngo-1", 1, 90)]},
    )
    monkeypatch.setattr(
        "app.services.donation_offers.persist_ranked_candidates",
        lambda *_args, **_kwargs: {"status": "no_candidates"},
    )

    with pytest.raises(HTTPException) as error:
        donation_offers.get_persisted_offers(
            "donation-1", {"providers": [{"id": "provider-1"}]}
        )

    assert error.value.status_code == 502
    assert "did not save" in error.value.detail


def test_provider_refresh_appends_a_newly_completed_ngo_without_reordering(
    monkeypatch,
):
    original = {
        "donation_id": "donation-1",
        "ngo_id": "ngo-old",
        "match_rank": 1,
        "ai_rank": 1,
        "final_score": 90.0,
        "score_details": {"distance_km": 2.0, "distance_source": "road"},
    }
    client = _ReadClient(
        {
            "donation_match_candidates": [original],
            "donation_offers": [],
            "ngos": [
                {"id": "ngo-old", "organization_name": "Old Pantry", "city": "Pune"},
                {"id": "ngo-new", "organization_name": "New Pantry", "city": "Pune"},
            ],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: {"id": "donation-1", "status": "available"},
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: {
            "status": "ok",
            "ranked_ngos": [
                {
                    "ngo_id": "ngo-new",
                    "rank": 1,
                    "final_score": 88.0,
                    "distance_km": 4.0,
                    "distance_source": "straight_line",
                }
            ],
        },
    )

    def persist(_client, *, donation_id, ranked_ngos):
        assert donation_id == "donation-1"
        assert [item["ngo_id"] for item in ranked_ngos] == ["ngo-new"]
        client.tables["donation_match_candidates"].append(
            {
                "donation_id": donation_id,
                "ngo_id": "ngo-new",
                "match_rank": 2,
                "ai_rank": 1,
                "final_score": 88.0,
                "score_details": {
                    "distance_km": 4.0,
                    "distance_source": "straight_line",
                },
            }
        )
        return {"status": "offered"}

    monkeypatch.setattr("app.services.donation_offers.persist_ranked_candidates", persist)
    result = donation_offers.get_persisted_offers(
        "donation-1", {"providers": [{"id": "provider-1"}]}
    )

    assert [row["ngo_id"] for row in result["ranked_candidates"]] == [
        "ngo-old",
        "ngo-new",
    ]
    assert [row["match_rank"] for row in result["ranked_candidates"]] == [1, 2]


def test_provider_match_route_returns_saved_ranking_without_recalculating(monkeypatch):
    donation = {"id": "donation-1", "provider_id": "provider-1", "status": "available"}
    candidate = {
        "donation_id": "donation-1",
        "ngo_id": "ngo-1",
        "match_rank": 1,
        "ai_rank": 2,
        "final_score": 87.5,
        "score_details": {"distance_km": 3.1, "distance_source": "road"},
    }
    client = _ReadClient(
        {
            "donation_match_candidates": [candidate],
            "ngos": [
                {
                    "id": "ngo-1",
                    "organization_name": "Community Kitchen",
                    "city": "Pune",
                }
            ],
        }
    )
    monkeypatch.setattr(ai_features, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: donation,
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: {"status": "no_candidates"},
    )
    monkeypatch.setattr(
        ai_features,
        "_calculate_ngos_match",
        lambda *_args: (_ for _ in ()).throw(
            AssertionError("persisted ranking must not be recalculated")
        ),
    )

    result = ai_features.match_ngos(
        "donation-1",
        {"providers": [{"id": "provider-1"}]},
        object(),
    )

    assert result["matching_state"] == "persisted"
    assert result["ranked_ngos"][0]["match_rank"] == 1
    assert result["ranked_ngos"][0]["rank"] == 2
    assert result["ranked_ngos"][0]["final_score"] == 87.5
    assert result["ranked_ngos"][0]["distance_km"] == 3.1
    assert result["ranked_ngos"][0]["distance_source"] == "road"


def test_ngo_offer_list_serializes_coordinate_distance_when_saved_score_is_missing(
    monkeypatch,
):
    donation = {
        "id": "donation-1",
        "provider_id": "provider-1",
        "latitude": 18.52,
        "longitude": 73.85,
    }
    client = _ReadClient(
        {
            "donation_offers": [
                {
                    "id": "offer-1",
                    "donation_id": "donation-1",
                    "ngo_id": "ngo-1",
                    "candidate_rank": 1,
                    "status": "pending",
                }
            ],
            "donations": [donation],
            "donation_match_candidates": [
                {
                    "donation_id": "donation-1",
                    "ngo_id": "ngo-1",
                    "score_details": {},
                }
            ],
            "providers": [],
            "ngos": [
                {
                    "id": "ngo-1",
                    "organization_name": "Community Kitchen",
                    "city": "Pune",
                    "latitude": 18.53,
                    "longitude": 73.86,
                }
            ],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)

    offers_for_ngo = donation_offers.list_ngo_offers(
        {
            "role": "ngo",
            "ngos": [
                {"id": "ngo-1", "latitude": 18.53, "longitude": 73.86}
            ],
        }
    )

    details = offers_for_ngo[0]["ranked_candidate"]["score_details"]
    assert details["distance_km"] > 0
    assert details["distance_source"] == "straight_line"


def test_saved_ranking_serializes_straight_line_distance_from_real_coordinates(
    monkeypatch,
):
    donation = {
        "id": "donation-1",
        "provider_id": "provider-1",
        "status": "available",
        "latitude": 18.52,
        "longitude": 73.85,
    }
    client = _ReadClient(
        {
            "donation_match_candidates": [
                {
                    "donation_id": "donation-1",
                    "ngo_id": "ngo-1",
                    "match_rank": 1,
                    "ai_rank": 1,
                    "final_score": 87.5,
                    "score_details": {},
                }
            ],
            "donations": [donation],
            "providers": [],
            "ngos": [
                {
                    "id": "ngo-1",
                    "organization_name": "Community Kitchen",
                    "city": "Pune",
                    "latitude": 18.53,
                    "longitude": 73.86,
                }
            ],
        }
    )
    monkeypatch.setattr(ai_features, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features, "_load_owned_donation", lambda *_args: donation
    )

    result = ai_features.match_ngos(
        "donation-1",
        {"providers": [{"id": "provider-1"}]},
        object(),
    )

    matched = result["ranked_ngos"][0]
    assert matched["distance_km"] > 0
    assert matched["distance_source"] == "straight_line"


def test_automatic_matching_sweep_retries_unranked_donations(monkeypatch):
    monkeypatch.setattr(offers, "_match_retry_after", {})
    monkeypatch.setattr(offers, "_match_scan_offset", 0)
    client = _ReadClient(
        {
            "donations": [
                {
                    "id": "donation-1",
                    "provider_id": "provider-1",
                    "status": "available",
                    "expiry_time": "9999-01-01T00:00:00+00:00",
                    "created_at": "2026-10-16T00:00:00+00:00",
                }
            ],
            "donation_match_candidates": [],
            "providers": [
                {"id": "provider-1", "user_id": "provider-user-1"}
            ],
        }
    )
    starts = []
    monkeypatch.setattr(
        offers,
        "auto_start_offers_for_donation",
        lambda _client, **kwargs: starts.append(kwargs)
        or {"status": "offered"},
    )

    first = offers.match_unranked_donations(client, object())
    second = offers.match_unranked_donations(client, object())

    assert first == {"scanned": 1, "attempted": 1, "offered": 1}
    assert second == {"scanned": 1, "attempted": 0, "offered": 0}
    assert starts[0]["donation"]["id"] == "donation-1"
    assert starts[0]["profile"]["role"] == "provider"
    assert starts[0]["profile"]["providers"][0]["id"] == "provider-1"


def test_automatic_matching_discovers_newly_eligible_ngo_after_retry_window(
    monkeypatch,
):
    monkeypatch.setattr(offers, "_match_retry_after", {})
    monkeypatch.setattr(offers, "_match_scan_offset", 0)
    client = _ReadClient(
        {
            "donations": [
                {
                    "id": "donation-1",
                    "provider_id": "provider-1",
                    "status": "available",
                    "expiry_time": "9999-01-01T00:00:00+00:00",
                    "created_at": "2026-10-16T00:00:00+00:00",
                }
            ],
            "donation_match_candidates": [],
            "providers": [
                {"id": "provider-1", "user_id": "provider-user-1"}
            ],
        }
    )
    eligible = [False]
    starts = []

    def start(_client, **kwargs):
        starts.append(kwargs)
        return {"status": "offered" if eligible[0] else "no_candidates"}

    monkeypatch.setattr(offers, "auto_start_offers_for_donation", start)

    assert offers.match_unranked_donations(client, object())["attempted"] == 1
    assert offers.match_unranked_donations(client, object())["attempted"] == 0
    eligible[0] = True
    result = offers.match_unranked_donations(
        client, object(), force_retry=True
    )

    assert result["attempted"] == 1
    assert result["offered"] == 1
    assert len(starts) == 2


def test_forced_refresh_reconsiders_donations_with_existing_ranked_candidates(
    monkeypatch,
):
    monkeypatch.setattr(offers, "_match_retry_after", {})
    monkeypatch.setattr(offers, "_match_scan_offset", 0)
    client = _ReadClient(
        {
            "donations": [
                {
                    "id": "donation-1",
                    "provider_id": "provider-1",
                    "status": "available",
                    "expiry_time": "9999-01-01T00:00:00+00:00",
                    "created_at": "2026-10-16T00:00:00+00:00",
                }
            ],
            "donation_match_candidates": [
                {"donation_id": "donation-1", "ngo_id": "ngo-previous"}
            ],
            "providers": [
                {"id": "provider-1", "user_id": "provider-user-1"}
            ],
        }
    )
    starts = []
    monkeypatch.setattr(
        offers,
        "auto_start_offers_for_donation",
        lambda _client, **kwargs: starts.append(kwargs)
        or {"status": "offered"},
    )

    result = offers.match_unranked_donations(client, object(), force_retry=True)

    assert result == {"scanned": 1, "attempted": 1, "offered": 1}
    assert starts[0]["donation"]["id"] == "donation-1"


def test_provider_expiry_check_uses_locked_timeout_transition(monkeypatch):
    pending_offer = {
        "id": "offer-private-id",
        "donation_id": "donation-1",
        "status": "pending",
        "offer_expires_at": "2026-10-14T00:05:00+00:00",
    }
    client = _ReadClient({"donation_offers": [pending_offer]})
    calls = []
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: {"id": "donation-1"},
    )
    monkeypatch.setattr(
        donation_offers,
        "respond_to_offer",
        lambda _client, **kwargs: calls.append(kwargs)
        or {
            "status": "timed_out",
            "changed": True,
            "next_offer": {
                "id": "another-private-id",
                "offer_expires_at": "2026-10-14T00:10:00+00:00",
            },
        },
    )

    result = donation_offers.check_provider_offer_escalation(
        "donation-1", {"providers": [{"id": "provider-1"}]}
    )

    assert calls == [
        {
            "offer_id": "offer-private-id",
            "ngo_id": None,
            "decision": "timeout",
        }
    ]
    assert result == {
        "status": "timed_out",
        "changed": True,
        "exhausted": False,
        "next_offer_active": True,
        "offer_expires_at": "2026-10-14T00:10:00+00:00",
    }
    assert "id" not in result


def test_timeout_rpc_sends_null_ngo_uuid_and_advances_once(monkeypatch):
    next_offer = {
        "id": "offer-next",
        "donation_id": "donation-1",
        "ngo_id": "ngo-2",
        "candidate_rank": 2,
        "status": "pending",
        "offer_expires_at": "2026-10-16T00:05:00+00:00",
    }
    client = _Client(
        {
            "status": "timed_out",
            "donation_id": "donation-1",
            "changed": True,
            "next_offer": next_offer,
        }
    )
    notifications = []
    monkeypatch.setattr(
        offers,
        "_notify_response_result",
        lambda _client, result: notifications.append(result)
        if result.get("changed")
        else None,
    )

    first = offers.respond_to_offer(
        client,
        offer_id="offer-current",
        ngo_id=None,
        decision="timeout",
    )
    client.response = {
        "status": "timed_out",
        "donation_id": "donation-1",
        "changed": False,
    }
    repeated = offers.respond_to_offer(
        client,
        offer_id="offer-current",
        ngo_id=None,
        decision="timeout",
    )

    assert client.rpc_calls == [
        (
            "respond_to_donation_offer",
            {
                "p_offer_id": "offer-current",
                "p_ngo_id": None,
                "p_decision": "timeout",
            },
        ),
        (
            "respond_to_donation_offer",
            {
                "p_offer_id": "offer-current",
                "p_ngo_id": None,
                "p_decision": "timeout",
            },
        ),
    ]
    assert first["next_offer"]["id"] == "offer-next"
    assert repeated["changed"] is False
    assert notifications == [first]


def test_duplicate_accept_replays_use_the_atomic_database_transition(monkeypatch):
    client = _Client(
        {
            "status": "accepted",
            "changed": True,
            "claim": {"id": "claim-1", "ngo_id": "ngo-1"},
        }
    )
    monkeypatch.setattr(offers, "_notify_response_result", lambda *_args: None)

    first = offers.respond_to_offer(
        client,
        offer_id="offer-1",
        ngo_id="ngo-1",
        decision="accepted",
    )
    client.response = {
        "status": "accepted",
        "changed": False,
        "claim": None,
    }
    repeated = offers.respond_to_offer(
        client,
        offer_id="offer-1",
        ngo_id="ngo-1",
        decision="accepted",
    )

    assert first["changed"] is True
    assert first["claim"]["id"] == "claim-1"
    assert repeated["changed"] is False
    assert [params for _, params in client.rpc_calls] == [
        {
            "p_offer_id": "offer-1",
            "p_ngo_id": "ngo-1",
            "p_decision": "accepted",
        },
        {
            "p_offer_id": "offer-1",
            "p_ngo_id": "ngo-1",
            "p_decision": "accepted",
        },
    ]


def test_provider_expiry_check_keeps_early_timeout_idempotent(monkeypatch):
    deadline = "2026-10-14T00:05:00+00:00"
    client = _ReadClient(
        {
            "donation_offers": [
                {
                    "id": "offer-1",
                    "donation_id": "donation-1",
                    "status": "pending",
                    "offer_expires_at": deadline,
                }
            ]
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    monkeypatch.setattr(
        ai_features,
        "_load_owned_donation",
        lambda *_args: {"id": "donation-1"},
    )
    monkeypatch.setattr(
        donation_offers,
        "respond_to_offer",
        lambda *_args, **_kwargs: {"status": "not_due", "changed": False},
    )

    result = donation_offers.check_provider_offer_escalation(
        "donation-1", {"providers": [{"id": "provider-1"}]}
    )

    assert result == {
        "status": "not_due",
        "changed": False,
        "exhausted": False,
        "next_offer_active": False,
        "offer_expires_at": deadline,
    }


def test_provider_donation_list_includes_linked_surplus_prediction(monkeypatch):
    prediction = {
        "id": "prediction-1",
        "predicted_surplus": 3.25,
        "planned_quantity": 6,
        "recommendation": "Prepare fewer portions",
        "prediction_date": "2026-10-14",
        "model_version": "surplus-v1",
        "confidence_score": None,
        "surplus_probability": None,
    }
    client = _ReadClient(
        {
            "donations": [
                {
                    "id": "donation-1",
                    "provider_id": "provider-1",
                    "prediction_id": "prediction-1",
                },
                {
                    "id": "donation-2",
                    "provider_id": "provider-1",
                    "prediction_id": None,
                },
            ],
            "food_predictions": [prediction],
            "providers": [{"id": "provider-1", "organization_name": "Kitchen"}],
        }
    )
    monkeypatch.setattr(donations, "get_supabase_client", lambda: client)

    result = donations.list_donations(
        {"role": "provider", "providers": [{"id": "provider-1"}]}
    )

    assert result[0]["surplus_prediction"] == prediction
    assert result[1]["surplus_prediction"] is None
    prediction_query = next(
        query for table, query in client.queries if table == "food_predictions"
    )
    assert prediction_query.selected_columns == (
        "id,predicted_surplus,planned_quantity,recommendation,"
        "prediction_date,model_version,confidence_score,surplus_probability"
    )


def test_ngo_list_is_scoped_to_authenticated_ngo_and_enriched(monkeypatch):
    offer = {
        "id": "offer-1",
        "donation_id": "donation-1",
        "ngo_id": "ngo-2",
        "status": "pending",
    }
    donation = {"id": "donation-1", "food_name": "Rice"}
    candidate = {"donation_id": "donation-1", "ngo_id": "ngo-2", "match_rank": 2}
    client = _ReadClient(
        {
            "donation_offers": [offer, {**offer, "id": "other-ngo", "ngo_id": "ngo-3"}],
            "donations": [donation],
            "donation_match_candidates": [candidate],
        }
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: client)
    result = donation_offers.list_ngo_offers({"ngos": [{"id": "ngo-2"}]})

    assert len(result) == 1
    assert result[0]["ngo_id"] == "ngo-2"
    assert result[0]["donation"] == donation
    assert result[0]["ranked_candidate"] == candidate
    assert client.reads == [
        "donation_offers",
        "donations",
        "donation_match_candidates",
    ]


def test_forward_migration_has_database_deadlines_locks_and_one_active_offer():
    migration = (
        Path(__file__).parents[1]
        / "supabase"
        / "migrations"
        / "20261014010000_add_ranked_donation_offers.sql"
    ).read_text(encoding="utf-8").lower()

    assert "where status = 'pending'" in migration
    assert "for update" in migration
    assert "clock_timestamp() + interval '5 minutes'" in migration
    assert "v_offer.offer_expires_at <= clock_timestamp()" in migration
    assert "offer_expires_at <= clock_timestamp()" in migration
    assert "'donation_offer'" in migration


def test_forward_migration_persists_demo_verified_ngo_candidates():
    migration = (
        Path(__file__).parents[1]
        / "supabase"
        / "migrations"
        / "20261017020000_demo_verified_ranked_offer_eligibility.sql"
    ).read_text(encoding="utf-8").lower()

    assert migration.count("n.demo_verified is true") == 4
    assert "ngo_not_eligible" in migration
    assert "set verified" not in migration


def test_forward_migration_appends_newly_ready_ngos_without_reordering():
    migration = (
        Path(__file__).parents[1]
        / "supabase"
        / "migrations"
        / "20261017030000_refresh_ranked_ngo_candidates.sql"
    ).read_text(encoding="utf-8").lower()

    assert "ngo_ready_for_donation_matching" in migration
    assert "v_max_rank + row_number()" in migration
    assert "public.donation_match_candidates prior" in migration
    assert "prior.ngo_id = c.ngo_id" in migration
    assert "on conflict (donation_id, ngo_id) do nothing" in migration
    assert "set verified" not in migration
    assert "n.demo_verified" not in migration


def test_forward_migration_uses_only_canonical_ngo_profile_completion():
    migration = (
        Path(__file__).parents[1]
        / "supabase"
        / "migrations"
        / "20261017040000_profile_complete_ngo_matching.sql"
    ).read_text(encoding="utf-8").lower()

    assert "ngo_profile_is_complete" in migration
    assert "ngo_ready_for_donation_matching" in migration
    assert "n.verified" not in migration
    assert "demo_verified" not in migration
    assert "from public.users u" not in migration
    assert "join public.users u on u.id = n.user_id" in migration
    assert "revoke all" in migration
    assert "to service_role" in migration


def test_routes_expose_persisted_provider_state_and_ngo_offer_actions():
    paths = app.openapi()["paths"]

    assert "get" in paths["/api/v1/donations/{donation_id}/offers"]
    assert "post" in paths[
        "/api/v1/donations/{donation_id}/offers/escalation-check"
    ]
    assert "get" in paths["/api/v1/donation-offers"]
    assert "post" in paths["/api/v1/donation-offers/{offer_id}/respond"]
    assert "post" in paths["/api/v1/donations/{donation_id}/match"]


def test_responding_ngo_that_lost_eligibility_gets_forbidden(monkeypatch):
    monkeypatch.setattr(
        donation_offers, "require_complete_profile", lambda *_args, **_kwargs: None
    )
    monkeypatch.setattr(donation_offers, "get_supabase_client", lambda: object())
    monkeypatch.setattr(
        donation_offers,
        "respond_to_offer",
        lambda *_args, **_kwargs: {"status": "ngo_not_eligible"},
    )

    with pytest.raises(HTTPException) as exc:
        donation_offers.respond(
            "offer-1",
            donation_offers.OfferResponse(decision="accepted"),
            profile={"ngos": {"id": "ngo-1"}},
        )

    assert exc.value.status_code == 403
    assert "Complete the NGO profile" in exc.value.detail
