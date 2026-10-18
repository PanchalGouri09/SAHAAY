-- ============================================================================
-- Persist the donation-completion acknowledgment PDF reference.
-- ============================================================================
--
-- The completion pipeline (delivery -> delivered -> record_delivery_impact
-- trigger marks the donation 'completed') generates the acknowledgment PDF
-- through the AI service and stores the bytes in the existing Supabase
-- storage bucket (path: acknowledgments/acknowledgment_<donation_id>.pdf).
--
-- These two columns record THAT the PDF exists and WHERE it lives, so:
--   * Flutter can download it after an app restart,
--   * the main backend can serve the persisted copy without depending on the
--     AI service's own local disk surviving a restart,
--   * auto-generation is idempotent (it skips donations that already have a
--     persisted reference).
--
-- Both columns are nullable: NULL honestly means "no acknowledgment has been
-- generated for this donation" (e.g. donations whose quantity is recorded in
-- servings cannot honestly state a kg weight and are refused, not faked).
-- ============================================================================

alter table public.donations
    add column if not exists acknowledgment_pdf_url text;

alter table public.donations
    add column if not exists acknowledgment_generated_at timestamp with time zone;

comment on column public.donations.acknowledgment_pdf_url is
    'Public URL of the persisted completion acknowledgment PDF in storage. NULL = not generated.';
comment on column public.donations.acknowledgment_generated_at is
    'UTC timestamp when the acknowledgment PDF was generated and persisted.';
