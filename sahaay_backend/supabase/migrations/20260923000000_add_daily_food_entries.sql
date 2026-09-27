-- =============================================================================
-- MANDATORY DAILY FOOD ENTRIES
-- -----------------------------------------------------------------------------
-- A daily food entry is NOT a donation. It records what a provider prepared
-- and sold on a given day so the EXISTING AI surplus-prediction service can be
-- called with a real daily observation. Creating an entry never creates a
-- donation, and this table holds no donation columns (no quantity/servings, no
-- pickup address, no expiry, no deadline, no status, no NGO/volunteer link).
--
-- ACCESS MODEL (matches the existing schema architecture):
--   * Row Level Security is ENABLED and NO policy is created for this table, so
--     the `anon` and `authenticated` Supabase roles have no direct access at
--     all. Only the FastAPI backend's service-role key can read or write it.
--     This is exactly how `public.food_predictions` is already protected in
--     20260912112505_remote_schema.sql, so this migration follows the existing
--     pattern and weakens nothing.
--   * `provider_id` is always written by the backend, resolved from the
--     Firebase bearer token. There is no policy that would let a client supply
--     it, and the Flutter app never talks to this table directly.
--   * RLS on every pre-existing table is left untouched.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.daily_food_entries (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider_id uuid NOT NULL REFERENCES public.providers(id) ON DELETE CASCADE,
    entry_date date NOT NULL,
    food_category text NOT NULL,
    food_prepared_kg numeric(12,3) NOT NULL,
    food_sold_kg numeric(12,3) NOT NULL,
    meal_type text NULL,
    prediction_id uuid NULL REFERENCES public.food_predictions(id) ON DELETE SET NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),

    CONSTRAINT daily_food_entries_prepared_kg_positive
        CHECK (food_prepared_kg > 0),
    CONSTRAINT daily_food_entries_sold_kg_non_negative
        CHECK (food_sold_kg >= 0),
    CONSTRAINT daily_food_entries_sold_not_above_prepared
        CHECK (food_sold_kg <= food_prepared_kg),
    CONSTRAINT daily_food_entries_meal_type_allowed
        CHECK (
            meal_type IS NULL
            OR meal_type IN ('breakfast', 'lunch', 'snacks', 'dinner', 'other')
        )
);

COMMENT ON TABLE public.daily_food_entries IS
    'Mandatory per-provider, per-day prepared/sold food log. Not a donation. '
    'Server-authoritative: provider_id is derived from the Firebase token and '
    'entry_date from the server clock.';
COMMENT ON COLUMN public.daily_food_entries.prediction_id IS
    'Row in the existing public.food_predictions table produced by the existing AI '
    'service. Nullable: an entry is still valid when the AI service is unreachable.';

-- One entry per provider per day. This is the database-level guarantee behind
-- the provider gate, so a double submit can never create two rows.
CREATE UNIQUE INDEX IF NOT EXISTS daily_food_entries_provider_date_key
    ON public.daily_food_entries (provider_id, entry_date);

-- Supports the provider-scoped history read (always filtered by provider_id).
CREATE INDEX IF NOT EXISTS daily_food_entries_provider_date_idx
    ON public.daily_food_entries (provider_id, entry_date DESC);

-- RLS on, zero policies: backend service-role only. Never granted to clients.
ALTER TABLE public.daily_food_entries ENABLE ROW LEVEL SECURITY;

-- Reuse the trigger function the base schema already installs for every other
-- timestamped table; defined in 20260912112505_remote_schema.sql.
DROP TRIGGER IF EXISTS update_daily_food_entries_updated_at
    ON public.daily_food_entries;
CREATE TRIGGER update_daily_food_entries_updated_at
    BEFORE UPDATE ON public.daily_food_entries
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
