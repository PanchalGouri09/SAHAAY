-- SAHAAY — delivery coordinates and volunteer service area
--
-- Gives every delivery row a real (nullable) pickup and dropoff coordinate pair
-- so volunteer-facing maps and straight-line distances always come from the
-- delivery's own columns instead of being re-derived per client. Existing
-- donations and claims already carry the source coordinates, so backfill copies
-- them once; everything after that is written by the volunteer-transport layer
-- at publish/rebind time (app/services/volunteer_transport.py).
--
-- Design notes
--   * All four columns are NULLABLE. NULL = "no usable coordinate is known"
--     and is never coerced into a fake pin by the client.
--   * Every statement is idempotent so the migration can be re-run safely.
--   * No column is dropped, renamed or narrowed, and no existing row is
--     fabricated: backfill only copies coordinates that genuinely exist.
--   * No RLS policy is created, altered or dropped here. Writes still go
--     through the authenticated FastAPI backend (service role server-side).

-- ---------------------------------------------------------------------------
-- 1. Delivery pickup / dropoff coordinates
-- ---------------------------------------------------------------------------
alter table public.deliveries
    add column if not exists pickup_latitude double precision,
    add column if not exists pickup_longitude double precision,
    add column if not exists dropoff_latitude double precision,
    add column if not exists dropoff_longitude double precision;

comment on column public.deliveries.pickup_latitude is
    'Real pickup latitude copied from the source donation (or set by the volunteer-transport publisher). NULL = not known.';
comment on column public.deliveries.pickup_longitude is
    'Real pickup longitude copied from the source donation (or set by the volunteer-transport publisher). NULL = not known.';
comment on column public.deliveries.dropoff_latitude is
    'Real dropoff latitude copied from the claiming NGO (or set by the volunteer-transport rebind). NULL = not known.';
comment on column public.deliveries.dropoff_longitude is
    'Real dropoff longitude copied from the claiming NGO (or set by the volunteer-transport rebind). NULL = not known.';

-- Backfill (one-time, safe to re-run):
--   * pickup coords come from the donation the delivery was created for;
--   * dropoff coords come from the NGO behind the delivery's claim.
update public.deliveries d
set pickup_latitude  = don.latitude,
    pickup_longitude = don.longitude
from public.donations don
where d.donation_id = don.id
  and d.pickup_latitude is null
  and d.pickup_longitude is null
  and don.latitude is not null
  and don.longitude is not null;

update public.deliveries d
set dropoff_latitude  = n.latitude,
    dropoff_longitude = n.longitude
from public.claims c
join public.ngos n on n.id = c.ngo_id
where d.claim_id = c.id
  and d.dropoff_latitude is null
  and d.dropoff_longitude is null
  and n.latitude is not null
  and n.longitude is not null;

-- ---------------------------------------------------------------------------
-- 2. Volunteer service area
-- ---------------------------------------------------------------------------
-- City/area describe the locality a volunteer serves, and
-- preferred_distance_km caps how far they want to travel for a delivery.
-- NULL = not answered (no preference), never treated as 0.
alter table public.volunteers
    add column if not exists city text,
    add column if not exists area text,
    add column if not exists preferred_distance_km double precision;

comment on column public.volunteers.city is
    'City the volunteer serves. NULL = not answered.';
comment on column public.volunteers.area is
    'Locality/area the volunteer serves. NULL = not answered.';
comment on column public.volunteers.preferred_distance_km is
    'Maximum preferred straight-line delivery distance in km. NULL = no preference, never treated as 0.';