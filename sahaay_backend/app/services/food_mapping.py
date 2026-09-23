"""
Explicit mapping between SAHAAY donation vocabulary (Flutter/DB) and the
standalone AI service vocabulary.

The AI service only accepts a small controlled vocabulary:
  - FoodCategory: cooked | bakery | dairy | packaged | raw
  - DietaryType:  veg | non_veg | vegan | any

SAHAAY uses its own values (e.g. the Flutter category list: 'Cooked Meals',
'Rice', 'Bread', 'Fruits', 'Vegetables', 'Packaged Food', 'Bakery', 'Other'),
so incompatible enum strings are never passed straight to the AI service.

Mapping is explicit and keyword-based. Unmappable input returns None so
callers can raise a controlled error instead of guessing.
"""

from __future__ import annotations

VegetarianToAI = {
    "vegetarian": "veg",
    "non_vegetarian": "non_veg",
    "vegan": "vegan",
    "mixed": "any",
}

# Flutter/DB food category text -> AI FoodCategory
FoodCategoryAliases = {
    "cooked meals": "cooked",
    "cooked": "cooked",
    "rice": "cooked",
    "bread": "bakery",
    "bakery": "bakery",
    "fruits": "raw",
    "vegetables": "raw",
    "raw": "raw",
    "packaged food": "packaged",
    "packaged": "packaged",
    "dairy": "dairy",
}


def map_food_category(value: str | None) -> str | None:
    """Map a SAHAAY donation food_category to an AI FoodCategory, or None."""
    if not value:
        return None
    norm = value.strip().lower()
    return FoodCategoryAliases.get(norm, None)


def map_veg_type_to_ai(value: str | None) -> str | None:
    """Map a SAHAAY veg_type (db values) to an AI DietaryType, or None."""
    if not value:
        return None
    norm = value.strip().lower().replace(" ", "_").replace("-", "_")
    return VegetarianToAI.get(norm, None)