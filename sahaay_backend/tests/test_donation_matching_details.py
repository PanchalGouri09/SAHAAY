from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.main import app
from app.routers import donations
from app.schemas.donation import DonationMatchingDetailsUpdate


class _Query:
    def __init__(self, row):
        self.row = row
        self.filters = {}
        self.values = None
        self.single = False

    def select(self, *_args):
        return self

    def update(self, values):
        self.values = values
        return self

    def eq(self, key, value):
        self.filters[key] = value
        return self

    def maybe_single(self):
        self.single = True
        return self

    def execute(self):
        if not self.row or any(
            self.row.get(key) != value for key, value in self.filters.items()
        ):
            return SimpleNamespace(data=None if self.single else [])
        if self.values is not None:
            self.row.update(self.values)
        return SimpleNamespace(data=self.row if self.single else [dict(self.row)])


class _Client:
    def __init__(self, row):
        self.row = row

    def table(self, name):
        assert name == "donations"
        return _Query(self.row)


def _profile(provider_id="provider-1"):
    return {"role": "provider", "providers": [{"id": provider_id}]}


def test_food_type_update_is_owner_scoped_and_retries_matching(monkeypatch):
    client = _Client(
        {
            "id": "donation-1",
            "provider_id": "provider-1",
            "status": "available",
            "veg_type": None,
        }
    )
    calls = []
    monkeypatch.setattr(donations, "get_supabase_client", lambda: client)
    monkeypatch.setattr(donations, "get_ai_client", lambda: object())
    monkeypatch.setattr(
        donations,
        "auto_start_offers_for_donation",
        lambda *args, **kwargs: calls.append((args, kwargs))
        or {"status": "offered"},
    )

    result = donations.update_donation_matching_details(
        "donation-1",
        DonationMatchingDetailsUpdate(veg_type="vegetarian"),
        _profile(),
    )

    assert client.row["veg_type"] == "vegetarian"
    assert result["matching"] == {"status": "offered"}
    assert len(calls) == 1


@pytest.mark.parametrize(
    ("row", "profile", "status_code"),
    [
        (
            {"id": "donation-1", "provider_id": "provider-other", "status": "available"},
            _profile(),
            403,
        ),
        (
            {"id": "donation-1", "provider_id": "provider-1", "status": "claimed"},
            _profile(),
            409,
        ),
        (None, _profile(), 404),
    ],
)
def test_food_type_update_rejects_non_owned_missing_or_closed_donation(
    monkeypatch, row, profile, status_code
):
    monkeypatch.setattr(donations, "get_supabase_client", lambda: _Client(row))

    with pytest.raises(HTTPException) as error:
        donations.update_donation_matching_details(
            "donation-1",
            DonationMatchingDetailsUpdate(veg_type="vegan"),
            profile,
        )

    assert error.value.status_code == status_code


def test_food_type_update_endpoint_still_requires_authentication():
    client = TestClient(app)

    response = client.patch(
        "/api/v1/donations/donation-1/matching-details",
        json={"veg_type": "vegetarian"},
    )

    assert response.status_code == 401
