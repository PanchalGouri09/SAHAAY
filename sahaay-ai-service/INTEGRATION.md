# Integration Guide — For the Main Backend Team

This document explains how the main SAHAAY backend (Flutter app +
backend/database) should call the AI & Smart Features service.

## 1. Overview

This is a **separate, independently-deployable service**. It does not
own any persistent business data (no restaurants/NGOs/donations
tables) — it is stateless and purely computational. The main backend
remains the single source of truth for all data; it calls this
service's APIs with the relevant data and gets back predictions,
scores, or generated files.

**Base URL (development):** `http://<ai-service-host>:8000`
**All endpoints are prefixed with:** `/api/v1/...`
**Content type:** `application/json` for all requests except the PDF
download endpoint, which returns `application/pdf`.

Full field-level schema (including validation rules) is always
available live at `GET /docs` (Swagger UI) or `GET /openapi.json`
(raw OpenAPI spec) — recommend bookmarking this for whoever is coding
the HTTP client on the backend side.

---

## 2. When to call each endpoint

### a) Surplus Prediction — `POST /api/v1/prediction/predict-surplus`
Call this whenever the restaurant dashboard needs an estimated surplus
for planning (e.g. end-of-day, or when a restaurant logs prepared/sold
quantities). Response includes `predicted_surplus_kg`, plus
`recommended_prepare_kg` and a plain-English `preparation_recommendation`
string — display the latter directly to the restaurant (e.g. "Consider
preparing about 38 kg next time...").

### b) NGO Matching — `POST /api/v1/matching/rank-ngos`
Call this **as soon as a donation is created/confirmed** by a
restaurant. Pass the donation details plus the list of candidate NGOs
(the backend decides which NGOs are "candidates," e.g. all active NGOs
within some radius, or all NGOs in the city — this service just
scores and ranks whichever list you send). Store the returned
`ranked_ngos` order in your database against the donation.

Distance is calculated using real road distance via a routing API by
default, with an automatic fallback to straight-line distance if the
routing API is unreachable (no crash either way). Each NGO's
`distance_source` field tells you which method was actually used
("road" or "straight_line") — useful to display in an admin/debug view
but not required for normal app usage.

### c) Auto-Escalation — `POST /api/v1/escalation/check`
This service is **stateless** — it does not run background timers
itself. Your backend should:
1. When a donation offer is sent to the top-ranked NGO, record
   `offer_sent_at` (timestamp) and `current_ngo_index = 0` in your DB.
2. Run a scheduled job (cron / Celery beat / APScheduler / etc.) every
   1–5 minutes that calls this endpoint for every donation still
   `pending`.
3. Based on the `action` field in the response:
   - `"keep_waiting"` → do nothing yet.
   - `"escalate"` → update the donation's `current_ngo_index` to
     `next_ngo_index`, send a new offer to `next_ngo_id`, reset
     `offer_sent_at` to now.
   - `"accepted"` → proceed with pickup workflow.
   - `"no_ngos_left"` → flag the donation for manual admin review.

### d) Restaurant Reliability — `POST /api/v1/reliability/calculate`
Call this on a schedule (e.g. nightly batch job) or on-demand when
displaying a restaurant's profile. Feed it aggregate counts from your
database (offered/completed/accepted/cancelled donations, average NGO
rating). Store the returned `reliability_score` back on the
restaurant's profile — it is also the `restaurant_reliability_score`
input expected by the NGO Matching endpoint.

### e) Food Safety Verification — `POST /api/v1/safety/verify`
Call this **before** a donation is allowed to move to "confirmed"
status — e.g. right after the restaurant submits the donation form.
- `"Eligible"` → allow the donation to proceed automatically.
- `"Not Eligible"` → block the donation, show the `reasons` to the
  restaurant.
- `"Requires Manual Review"` → route to an admin queue; show
  `reasons` so the admin knows what to check.

### f) PDF Acknowledgment — `POST /api/v1/donation/generate-acknowledgment`
Call this **after** a donation's status is updated to "Completed" in
your database (i.e. pickup confirmed by both restaurant and NGO). The
response gives you `pdf_filename`; use
`GET /api/v1/donation/download/{donation_id}` to fetch the actual PDF
bytes (e.g. to store in your own file storage / email to the
restaurant / show a download link in the app).

---

## 3. Error handling contract

All endpoints return standard HTTP status codes:
- `200` — success
- `400` — invalid input (e.g. empty NGO list, index out of range) —
  response body has a `detail` field explaining what's wrong
- `404` — resource not found (only used by the PDF download endpoint)
- `422` — Pydantic validation error (wrong field type / missing
  required field) — response body lists exactly which field failed
- `500` — unexpected internal error — response body has a `detail`
  field with a short description; check server logs for the full
  traceback

Recommend the backend's HTTP client treats `4xx` as "fix the request"
and `5xx` as "retry later / alert," same as any REST API.

---

## 4. Authentication

This module does **not** implement authentication itself — it is
designed to sit behind the main backend (or an API gateway) and is
not meant to be exposed directly to the internet. If the deployment
environment requires it, add an API key check or JWT validation as
FastAPI middleware in `app/main.py`, or place this service behind the
same reverse proxy that authenticates the main backend.

---

## 5. Sample end-to-end flow

```
1. Restaurant logs food prepared/sold → backend optionally calls
   /predict-surplus for planning insight.

2. Restaurant creates a donation → backend calls /safety/verify.
   If "Eligible" or "Requires Manual Review" resolved by admin →
   proceed.

3. Backend calls /matching/rank-ngos with the donation + candidate
   NGO list → gets ranked list → sends offer to rank #1 NGO, saves
   offer_sent_at + current_ngo_index=0.

4. Scheduled job calls /escalation/check every few minutes until an
   NGO accepts or the list is exhausted.

5. Once NGO picks up and both sides confirm → backend marks donation
   "Completed" → calls /donation/generate-acknowledgment →
   downloads/stores the PDF.

6. Periodically (e.g. nightly), backend calls /reliability/calculate
   per restaurant and stores the updated score for use in future
   matching calls.
```

---

## 6. Deployment note

For local development, both the main backend and this AI service can
run on the same machine on different ports (e.g. backend on `:5000`,
this service on `:8000`). For production, this service can be
containerized (add a `Dockerfile` running
`uvicorn app.main:app --host 0.0.0.0 --port 8000`) and deployed
separately, with the main backend calling it over an internal network
URL or a public URL if hosted separately.
