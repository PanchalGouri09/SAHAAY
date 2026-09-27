"""
Trains the food surplus prediction model.

Run this once (and again whenever you get more real data) to produce
surplus_model.pkl and encoders.pkl in the app/ml/ folder.

Usage (from the sahaay-ai-service/ folder):
    python -m app.ml.train_model
"""

import os
import sys

import joblib
import pandas as pd
from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_absolute_error
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import LabelEncoder

# allow running this file directly (python app/ml/train_model.py)
sys.path.append(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from app.config import SAMPLE_DATA_PATH, SURPLUS_MODEL_PATH, ENCODER_PATH  # noqa: E402


def build_features(df: pd.DataFrame, category_encoder: LabelEncoder, day_encoder: LabelEncoder, fit: bool):
    """
    Converts raw columns into numeric features the model can use.
    If fit=True, the encoders are fit on this data (training time).
    If fit=False, the encoders just transform (prediction time).
    """
    df = df.copy()
    df["date"] = pd.to_datetime(df["date"])
    df["day_of_month"] = df["date"].dt.day
    df["month"] = df["date"].dt.month

    if fit:
        df["food_category_enc"] = category_encoder.fit_transform(df["food_category"])
        df["day_of_week_enc"] = day_encoder.fit_transform(df["day_of_week"])
    else:
        df["food_category_enc"] = category_encoder.transform(df["food_category"])
        df["day_of_week_enc"] = day_encoder.transform(df["day_of_week"])

    df["sell_through_ratio"] = df["food_sold_kg"] / df["food_prepared_kg"]

    feature_cols = [
        "food_prepared_kg",
        "food_sold_kg",
        "sell_through_ratio",
        "food_category_enc",
        "day_of_week_enc",
        "day_of_month",
        "month",
    ]
    return df[feature_cols]


def train():
    print(f"Loading training data from: {SAMPLE_DATA_PATH}")
    df = pd.read_csv(SAMPLE_DATA_PATH)

    category_encoder = LabelEncoder()
    day_encoder = LabelEncoder()

    X = build_features(df, category_encoder, day_encoder, fit=True)
    y = df["surplus_kg"]

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42
    )

    model = RandomForestRegressor(
        n_estimators=200,
        max_depth=6,
        random_state=42,
    )
    model.fit(X_train, y_train)

    predictions = model.predict(X_test)
    mae = mean_absolute_error(y_test, predictions)
    print(f"Model trained. Test MAE: {mae:.2f} kg (lower is better)")

    os.makedirs(os.path.dirname(SURPLUS_MODEL_PATH), exist_ok=True)
    joblib.dump(model, SURPLUS_MODEL_PATH)
    joblib.dump(
        {"food_category": category_encoder, "day_of_week": day_encoder},
        ENCODER_PATH,
    )
    print(f"Saved model to: {SURPLUS_MODEL_PATH}")
    print(f"Saved encoders to: {ENCODER_PATH}")


if __name__ == "__main__":
    train()
