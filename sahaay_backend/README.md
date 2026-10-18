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

## Firebase phone verification

Phone verification is performed by Firebase Authentication on the signed-in
client and linked to that Firebase account; the app does not sign in as a
different user to verify a phone. FastAPI verifies Firebase ID tokens with
revocation checks and derives phone verification from the trusted token's
`phone_number` claim. It never trusts a client-supplied verification boolean or
phone number.

Before enabling the backend gate:

1. In Firebase Console, enable **Authentication → Sign-in method → Phone** for
   the Firebase project used by this app.
2. Register the app's Android signing SHA-1 and SHA-256 fingerprints. Include
   the debug keystore fingerprint for local debug builds and the release
   signing fingerprints for distributed builds; update and re-download the
   Firebase Android configuration if Firebase requires it.
3. Review Firebase Authentication's SMS region policy, per-project and
   per-number quotas, billing requirements, and abuse-protection settings.
   Use Firebase test phone numbers during automated testing; they do not prove
   live SMS delivery.
4. Set `FIREBASE_PHONE_AUTH_ENABLED=true` only in the intended development or
   deployment environment after the Firebase configuration is confirmed.
   This flag enables backend enforcement for protected actions and matching
   eligibility; it does not configure Firebase or send SMS by itself. Keep it
   unset/false until then. Restart the backend after changing it.

Do not enable the flag in production until the phone provider, app signing,
SMS policy/quotas, and deployment environment have been reviewed. Verify SMS
delivery on a real device before claiming that delivery works.

## Run

```powershell
uv run fastapi dev app/main.py
```

API docs: <http://127.0.0.1:8000/docs>

## Container deployment

Build from this directory and pass deployment secrets at runtime; the image
does not copy `.env` or credentials:

```powershell
docker build -t sahaay-backend .
docker run --rm -p 8000:8000 --env-file .env -e PORT=8000 sahaay-backend
```

The container binds to `0.0.0.0`, honors the platform-provided `PORT`, and
serves `GET /health`. It intentionally runs one Uvicorn worker because the
escalation and ranked-offer pollers run in-process. Keep one replica while
those pollers are enabled; do not scale the service horizontally until
scheduler leadership is provided separately. Set `AI_SERVICE_URL` to the
AI service's private/internal address in deployment. `CORS_ORIGINS` is only
needed for browser clients and should contain exact deployed web origins;
native Android/iOS clients do not use browser CORS.

Before release, verify all of the following in the intended deployment:

- Configure the Supabase URL and service-role key, Firebase project/service
  account credentials, and Firebase client configuration through the hosting
  platform's secret store.
- Confirm `AI_SERVICE_URL` reaches the private AI service and verify both
  `/health` endpoints.
- Set exact browser origins in `CORS_ORIGINS` if Flutter Web is deployed.
- Keep a single backend replica while either in-process scheduler is enabled.
- Review and apply ordered Supabase migrations through the approved database
  workflow; neither the container nor application startup runs migrations.
- Verify the live `user_device_tokens` unique index matches
  `sahaay_backend/supabase/migrations/20260925120000_create_user_device_tokens.sql`.
  The local migration history has a different token uniqueness definition from
  the fetched upstream revision; if the live migration history reflects the
  upstream definition, reconcile it with a reviewed forward-only migration
  before enabling token registration. Do not rerun or rewrite an applied
  migration.
- Use a separately managed production signing key for a distributable Android
  release; this repository's current Android release variant uses the debug
  signing configuration.

`sahaay_backend/supabase/migrations` is the complete local migration sequence.
`sahaay/supabase/migrations` contains only the two original schema snapshots
and is not the deployment migration directory.

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
- `POST /api/v1/notifications/device-token` (used by the Flutter app)
- `POST`, `GET /api/v1/device-tokens`
- `DELETE /api/v1/device-tokens/{token_id}`

All routes except `/health` require `Authorization: Bearer <Firebase ID token>`.

## Related services

AI prediction, matching, food safety verification, reliability scoring, and
acknowledgment PDFs are provided by the separate AI service and exposed through
the backend's authenticated routes. The backend calls that service at the
`AI_SERVICE_URL` configured in `.env` (default: `http://127.0.0.1:8001`).

## Ranked donation offers

After a donation is persisted, the backend uses its existing eligibility and AI
ranking flow to store eligible NGO candidates and issue one five-minute offer
at a time. The provider can read the saved ranking and current offer without
starting another match with `GET /api/v1/donations/{donation_id}/offers`;
the owning provider can check or advance a due offer with
`POST /api/v1/donations/{donation_id}/offers/escalation-check`. This action
uses the same database-clock, row-locking transition as the scheduler and
returns only the transition status, whether it changed, whether another offer
is active, exhaustion state, and the next deadline (when available); it never
accepts a client-supplied NGO or offer identifier. Before the five-minute
deadline the response is `not_due` and the offer remains pending.
NGOs can list their own offer history with
`GET /api/v1/donation-offers` and respond with
`POST /api/v1/donation-offers/{offer_id}/respond` (`accepted` or `declined`).
The existing `POST /api/v1/donations/{donation_id}/match` contract remains
available to callers that explicitly request a fresh ranking.

Apply `supabase/migrations/20261014010000_add_ranked_donation_offers.sql`
through the normal reviewed deployment process before enabling this feature.
The restart-safe deadline poller defaults on and can be controlled with
`DONATION_OFFER_SCHEDULER_ENABLED`; the backend does not apply migrations or
execute SQL at startup.

## Intentionally not implemented

- Storage uploads
- Google Maps
- Firebase account creation
- Supabase schema or RLS changes

Storage bucket configuration was not present in the Flutter repository, so no upload route or bucket name was invented.
