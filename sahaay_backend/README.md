# SAHAAY Backend

Secure FastAPI boundary between the Flutter client, Firebase Authentication, and Supabase application data.

## Architecture

```text
Flutter
  -> Firebase ID token
  -> FastAPI
  -> Firebase Admin SDK verifies the token
  -> Supabase PostgreSQL using the server-only service-role key
```

The backend never accepts `firebase_uid` as an identity claim from a request body. It derives the UID from the verified Firebase token and maps it to `users.firebase_uid`.

## Requirements

- Python 3.11+
- `uv` recommended

Python 3.14 may work, but Python 3.11-3.13 is the conservative production target for the current dependency set.

## Setup

```powershell
cd sahaay_backend
uv sync --extra test
Copy-Item .env.example .env
```

Fill `.env` with real server-only values:

```text
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-server-only-key
FIREBASE_PROJECT_ID=your-project-id
FIREBASE_CLIENT_EMAIL=firebase-adminsdk-...@your-project.iam.gserviceaccount.com
FIREBASE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
```

Never commit `.env`, Firebase private keys, or the Supabase service-role key.

## Run

```powershell
uv run fastapi dev app/main.py
```

API docs: <http://127.0.0.1:8000/docs>

## Tests

```powershell
uv run pytest
```

Tests do not require production credentials for health and authentication-boundary checks. Database-backed tests require dependency overrides or a dedicated test project and must not use production credentials.

## Endpoints

- `GET /health`
- `GET /api/v1/profile`
- `POST /api/v1/profile`
- `GET /api/v1/donations`
- `POST /api/v1/donations`
- `GET /api/v1/claims`
- `POST /api/v1/claims`
- `GET /api/v1/deliveries`
- `PATCH /api/v1/deliveries/{delivery_id}/status`
- `GET /api/v1/notifications`
- `PATCH /api/v1/notifications/{notification_id}/read`

All routes except `/health` require `Authorization: Bearer <Firebase ID token>`.

## Intentionally not implemented

- AI prediction and matching
- Food safety and reliability scoring
- PDF generation
- Storage uploads
- Google Maps
- Firebase account creation
- Supabase schema or RLS changes

Storage bucket configuration was not present in the Flutter repository, so no upload route or bucket name was invented.
