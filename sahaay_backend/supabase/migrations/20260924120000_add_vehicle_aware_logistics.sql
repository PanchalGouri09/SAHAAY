-- SAHAAY — vehicle-aware logistics matching (provider side + volunteer hand-off)
--
-- Extends the existing ngos.vehicle_available (migration 20260923120000) with the
-- provider side of the same question, and adds the smallest amount of state
-- needed to make a "neither side can transport" donation discoverable by the
-- volunteer workflow.
--
-- Design notes
--   * vehicle_available is NULLABLE and NULL means "has not answered yet".
--     It is never used to mean false. All four explicit/none cases are
--     distinguishable in SQL.
--   * Every statement is idempotent so the migration can be re-run safely.
--   * No column is dropped, renamed or narrowed, and no existing row is
--     rewritten or deleted, so existing provider/donation data is preserved.
--   * No RLS policy is created, altered or dropped here. RLS stays exactly as
--     the remote schema defines it (enabled on providers/donations/deliveries),
--     and all writes still go through the authenticated FastAPI backend, which
--     uses the service role server-side.

-- ---------------------------------------------------------------------------
-- 1. Provider vehicle availability
-- ---------------------------------------------------------------------------
-- Mirrors public.ngos.vehicle_available exactly:
--   true  -> the provider has a vehicle available for transporting donated food
--   false -> the provider explicitly has no vehicle
--   null  -> the provider has not answered yet
--
-- Existing providers get NULL, i.e. "not answered yet", which the matching
-- layer reports as `unknown` rather than pretending it is a "no".
alter table public.providers
    add column if not exists vehicle_available boolean;

comment on column public.providers.vehicle_available is
    'Tri-state pickup-transport capability. true = has a vehicle, false = explicitly no vehicle, NULL = not answered yet. NULL is never treated as false.';

-- ---------------------------------------------------------------------------
-- 2. Donation-level volunteer transport flag
-- ---------------------------------------------------------------------------
-- Set when a claim is made by an NGO that has no vehicle while the providing
-- organisation also has no vehicle, i.e. the pairwise compatibility resolves to
-- 'volunteer_required'. NOT NULL with a false default so every existing donation
-- is immediately valid and reads as "no volunteer required" (the correct
-- default: nothing is known, so nothing is asserted).
alter table public.donations
    add column if not exists volunteer_transport_required boolean not null default false;

comment on column public.donations.volunteer_transport_required is
    'True when neither the provider nor the claiming NGO has transport, so a volunteer must bridge the pickup. Set by the backend at claim time; never set from client input.';

-- ---------------------------------------------------------------------------
-- 3. Allow a delivery to exist before a volunteer accepts it
-- ---------------------------------------------------------------------------
-- deliveries.volunteer_id is already nullable, which is what allows a genuine
-- "awaiting a volunteer" state. The problem is the status enum: the existing
-- deliveries_status_check does not contain a value that means "nobody has taken
-- this yet", and the column default is 'assigned' — which would have labelled an
-- unassigned row as if somebody were already on it.
--
-- 'unassigned' is ADDED to the allowed set. This is a widening of a status enum,
-- not a relaxation of any security control: no RLS policy, grant or role is
-- touched. 'unassigned' rows always carry volunteer_id IS NULL.
--
-- The constraint is dropped and recreated with drop if exists so this migration
-- stays re-runnable, and is restored immediately in the same transaction.
alter table public.deliveries
    drop constraint if exists deliveries_status_check;

alter table public.deliveries
    add constraint deliveries_status_check
    check (status = any (array['unassigned'::text,
                                'assigned'::text,
                                'accepted'::text,
                                'picked_up'::text,
                                'in_transit'::text,
                                'delivered'::text,
                                'failed'::text,
                                'cancelled'::text]));

comment on column public.deliveries.status is
    'unassigned = created for a volunteer_required donation and not yet accepted by any volunteer (volunteer_id IS NULL); assigned onward = a real volunteer has accepted it.';
