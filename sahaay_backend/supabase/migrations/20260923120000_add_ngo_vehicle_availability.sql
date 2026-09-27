-- Add NGO vehicle availability, used as a soft preference during AI NGO matching.
-- Idempotent so it can be re-applied against any state of the schema.
--
-- Semantics are three-state, which is why the column is nullable:
--   true  -> the NGO has answered "yes, I have a vehicle for food pickup"
--   false -> the NGO has answered "no, I don't"
--   NULL  -> the NGO has NOT answered yet
--
-- NULL is deliberately distinct from false: a false value is an explicit,
-- authoritative "no vehicle" answer, while NULL means the question is still
-- open. Collapsing both into false would make an unanswered NGO look like a
-- confirmed no-vehicle NGO, so the two states are stored separately.
--
-- Backward compatible: existing NGO rows are left NULL (i.e. "not answered")
-- and remain fully matchable. No existing data is deleted or rewritten, and
-- this migration does not touch any existing RLS policy or constraint.

alter table public.ngos
    add column if not exists vehicle_available boolean;

comment on column public.ngos.vehicle_available is
    'Three-state NGO pickup vehicle availability: true = has a vehicle, '
    'false = explicitly no vehicle, NULL = not answered yet.';

-- Matching eligibility policy, documented in app/routers/ai_features.py:
--   * vehicle_available IS NULL  -> treated as UNKNOWN, not as "no vehicle".
--     An unanswered NGO is still a full matching candidate and is never
--     auto-rejected.
--   * vehicle_available = true   -> preferred tier (ranked first when any
--     candidate has a vehicle).
--   * vehicle_available = false  -> still matchable, but ranked after
--     vehicle-owning NGOs. Such an NGO may still collect food via volunteers
--     or third-party transport, so it is never hard-excluded.
--
-- No index is added here: matching reads the full verified NGO set, so an
-- index on a low-cardinality boolean would not help.
