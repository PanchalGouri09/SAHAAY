"""Normalization and format validation for Indian mobile contact numbers."""

import re

_ALLOWED_PHONE_INPUT = re.compile(r"^(?:\+|00)?[0-9\s().-]+$")
_INDIAN_MOBILE = re.compile(r"^[6-9][0-9]{9}$")


def normalize_indian_mobile_number(value: object) -> str | None:
    """Return a canonical 10-digit Indian mobile number, or None if invalid.

    Spaces, parentheses, periods and hyphens are accepted as formatting.
    `+91`, `0091`, and `91` international prefixes are accepted, but other
    letters, punctuation, lengths, and first digits are rejected.
    """
    if not isinstance(value, str):
        return None
    candidate = value.strip()
    if not candidate or not _ALLOWED_PHONE_INPUT.fullmatch(candidate):
        return None

    compact = re.sub(r"[\s().-]", "", candidate)
    if compact.startswith("+91"):
        compact = compact[3:]
    elif compact.startswith("0091"):
        compact = compact[4:]
    elif compact.startswith("91") and len(compact) == 12:
        compact = compact[2:]

    return compact if _INDIAN_MOBILE.fullmatch(compact) else None
