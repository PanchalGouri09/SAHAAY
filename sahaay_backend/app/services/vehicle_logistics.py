"""Vehicle-aware logistics compatibility for SAHAAY matching.

Why this is a separate deterministic layer
-------------------------------------------
The AI microservice ranks NGOs on the inputs its `NGOInput` contract actually
carries (distance, capacity, dietary, operating hours, reliability). It has **no
vehicle field**, so the AI has *not* learned vehicle behaviour and this module
never pretends otherwise. Vehicle information is applied as a transparent,
inspectable logistics layer in the main backend, on top of the AI ranking.

Why vehicle matters on BOTH sides
---------------------------------
A donation only reaches an NGO if somebody physically moves the food:

    provider has a vehicle -> the provider can bridge the gap to the NGO
    NGO has a vehicle      -> the NGO can collect from the provider
    neither has a vehicle  -> a volunteer must transport it

So compatibility is a function of the *pair* (provider, NGO), never of the NGO
alone. `provider_available=True` is not automatically "better" than
`provider_available=False`; what matters is whether *somebody* can move the food.

NULL handling (the important part)
----------------------------------
`vehicle_available` is tri-state and NULL means "this person has not answered
yet". NULL is NEVER silently coerced to False. If either side is unanswered the
result is `unknown`, because the system must not invent transport capability and
must not escalate a donation to "needs a volunteer" on the basis of missing data.
"""

from __future__ import annotations

from typing import Literal, Optional

VehicleCompatibility = Literal[
    "provider_transport",
    "ngo_transport",
    "both_transport",
    "volunteer_required",
    "unknown",
]


def vehicle_compatibility(
    provider_available: Optional[bool],
    ngo_available: Optional[bool],
) -> VehicleCompatibility:
    """Classify the pickup logistics of one (provider, NGO) pair.

    Args:
        provider_available: providers.vehicle_available, or None if unanswered.
        ngo_available: ngos.vehicle_available, or None if unanswered.

    Returns:
        both_transport     both sides have transport.
        provider_transport the provider can move the food to the NGO.
        ngo_transport      the NGO can collect the food itself.
        volunteer_required neither side can transport; a volunteer must bridge it.
        unknown            at least one side has not answered, so transport
                           capability cannot be determined.

    The three cases with both sides answered are total and mutually exclusive;
    any unanswered side yields `unknown`. `volunteer_required` is therefore only
    ever produced from two *explicit* `false` answers, never from missing data.
    """
    if provider_available is None or ngo_available is None:
        return "unknown"
    if provider_available and ngo_available:
        return "both_transport"
    if provider_available:
        return "provider_transport"
    if ngo_available:
        return "ngo_transport"
    return "volunteer_required"


def requires_volunteer_transport(provider_available: Optional[bool], ngo_available: Optional[bool]) -> bool:
    """True only when both sides explicitly reported no vehicle.

    Kept separate from a string comparison so callers cannot accidentally treat
    `unknown` as needing a volunteer.
    """
    return provider_available is False and ngo_available is False


# ---------------------------------------------------------------------------
# Ordering
# ---------------------------------------------------------------------------
# DOCUMENTED, DETERMINISTIC ORDERING RULE
#
# Vehicle compatibility MAY reorder the AI's ranking, and it does so by a single
# business rule:
#
#     A pickup is only possible if SOMEONE has transport. So candidates are
#     grouped by whether the pickup can be completed WITHOUT depending on a
#     third party, and the AI order is preserved inside each group.
#
# Tier 0  both_transport     - either side can support the logistics, so the
#                              pickup is viable with maximum flexibility.
# Tier 1  provider_transport - the provider can bridge the gap themselves.
# Tier 2  ngo_transport      - the NGO can collect the food themselves.
# Tier 3  unknown            - capability not yet known. Placed above
#                              volunteer_required on purpose: an unanswered
#                              question may still resolve into a working
#                              arrangement, whereas volunteer_required is a
#                              confirmed dependency on a third party.
# Tier 4  volunteer_required - confirmed to need a volunteer, which depends on a
#                              scarce resource actually accepting the task, so it
#                              is offered last. It is NEVER dropped: the NGO
#                              remains claimable.
#
# This is a viability grouping, not a "vehicle = higher score" fudge. No numeric
# score is added to `final_score`, the AI's own scores are never modified, and
# the ordering is applied with Python's stable `sorted`, so candidates sharing a
# tier keep the exact order the AI returned. If a deployment never uses the
# vehicle field, every candidate lands in `unknown` (tier 3), the sort is a
# no-op, and the untouched AI ranking is returned.
_LOGISTICS_TIERS: dict[str, int] = {
    "both_transport": 0,
    "provider_transport": 1,
    "ngo_transport": 2,
    "unknown": 3,
    "volunteer_required": 4,
}

#: True when at least one candidate can complete the pickup without a volunteer.
#: Used to decide whether the ordering changes anything at all.
_VIABLE_WITHOUT_VOLUNTEER = frozenset(
    {"both_transport", "provider_transport", "ngo_transport"}
)


def logistics_tier(compatibility: str) -> int:
    """Sort tier for a compatibility state. Unknown strings sort last-but-one."""
    return _LOGISTICS_TIERS.get(compatibility, _LOGISTICS_TIERS["unknown"])


def order_by_logistics(ranked: list[dict]) -> tuple[list[dict], bool]:
    """Order enriched candidates by logistics viability, AI order preserved within tier.

    `ranked` items must each carry a `vehicle_compatibility` key.

    Returns:
        (ordered_items, changed) where `changed` is True only if the compatibility
        information actually altered the AI's order.
    """
    if not any(
        item.get("vehicle_compatibility") in _VIABLE_WITHOUT_VOLUNTEER for item in ranked
    ):
        # Nothing can be transported without a volunteer. Reordering would be
        # pure noise, so the AI's ranking is returned untouched.
        return ranked, False
    return sorted(ranked, key=lambda item: logistics_tier(str(item.get("vehicle_compatibility")))), True


# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------
# Deliberately phrased as transport capability, never as a match-quality claim.
# "Best AI match" style wording would be misleading here: this says who can move
# the food, which is a logistics fact, not a statement about AI scoring.
COMPATIBILITY_LABELS: dict[str, str] = {
    "provider_transport": "Provider can transport",
    "ngo_transport": "NGO can transport",
    "both_transport": "Both have transport",
    "volunteer_required": "Volunteer transport required",
    "unknown": "Transport availability unknown",
}

COMPATIBILITY_DETAILS: dict[str, str] = {
    "provider_transport": "You have a vehicle, so you can deliver this food to the NGO.",
    "ngo_transport": "This NGO has a vehicle and can collect the food from you.",
    "both_transport": "You and this NGO both have transport, so pickup is flexible.",
    "volunteer_required": "Neither you nor this NGO has a vehicle. A volunteer is needed to transport this food.",
    "unknown": "Vehicle information is missing on one side, so transport cannot be confirmed yet.",
}


def compatibility_label(compatibility: str) -> str:
    return COMPATIBILITY_LABELS.get(compatibility, COMPATIBILITY_LABELS["unknown"])


def compatibility_detail(compatibility: str) -> str:
    return COMPATIBILITY_DETAILS.get(compatibility, COMPATIBILITY_DETAILS["unknown"])
