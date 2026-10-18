-- SAHAAY — server-side handover verification columns on claims
--
-- The claimed-donation screen previously generated and "verified" a handover
-- code entirely inside the Flutter client, so any client could declare a
-- handover complete. These columns let the backend own the lifecycle:
--
--   * handover_code_hash       — SHA-256 of "<claim id>:<code>"; the plaintext
--                                code is never stored.
--   * handover_code_expires_at — 10-minute expiry for the live code.
--   * handover_code_attempts   — wrong-attempt counter (locked at 10).
--   * handover_verified_at     — set exactly once, only by a successful
--                                server-side verification.
--   * handover_photo_url       — persisted proof-of-handover photo URL so the
--                                image is re-displayed after an app restart.
--
-- Design notes:
--   * All columns are nullable: existing claims are unaffected and read as
--     "no code / not verified / no photo".
--   * No new tables and no changes to claim status values — the existing
--     claim lifecycle and its triggers are untouched.
--   * Row Level Security: no client-facing policies are added. The backend
--     writes these columns with the service-role client; Firebase-authenticated
--     clients never touch this table directly.

alter table public.claims
  add column if not exists handover_code_hash text,
  add column if not exists handover_code_expires_at timestamptz,
  add column if not exists handover_code_attempts integer not null default 0,
  add column if not exists handover_verified_at timestamptz,
  add column if not exists handover_photo_url text;

comment on column public.claims.handover_code_hash is
    'SHA-256 hash of the current handover code (plaintext is never stored).';
comment on column public.claims.handover_code_expires_at is
    'Expiry moment of the current handover code.';
comment on column public.claims.handover_code_attempts is
    'Number of wrong verification attempts for the current code.';
comment on column public.claims.handover_verified_at is
    'When the handover code was successfully verified server-side.';
comment on column public.claims.handover_photo_url is
    'Public URL of the persisted handover proof photo.';
