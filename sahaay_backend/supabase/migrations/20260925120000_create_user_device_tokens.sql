-- SAHAAY — user device tokens for push notifications
--
-- Stores FCM/APNs device tokens per user for push notification delivery.
-- The foreign key uses users.id (backend-derived from Firebase token),
-- NOT client-provided Firebase UID.
--
-- Design notes:
--   * token is UNIQUE per user — a user cannot have duplicate tokens.
--   * platform records the OS platform (android, ios, web).
--   * created_at/updated_at for auditing.
--   * Row Level Security: token access is restricted to backend operations
--     using the service-role client. Firebase-authenticated clients do not
--     use Supabase auth.uid() and must not access this table directly.
--   * Tokens are removed on logout so users don't continue receiving
--     private notifications after signing out.

-- ---------------------------------------------------------------------------
-- 1. user_device_tokens table
-- ---------------------------------------------------------------------------
create table public.user_device_tokens (
  id uuid not null default gen_random_uuid() primary key,
  user_id uuid not null references public.users(id) on delete cascade,
  token text not null,
  platform text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint user_device_tokens_token_key unique (user_id, token)
);

comment on table public.user_device_tokens is
    'Stores FCM/APNs device tokens per user for push notification delivery.';

comment on column public.user_device_tokens.user_id is
    'Backend-derived user ID from Firebase auth token (users table primary key).';

comment on column public.user_device_tokens.token is
    'The FCM registration token or APNs device token.';

comment on column public.user_device_tokens.platform is
    'The platform: android, ios, or web.';

comment on column public.user_device_tokens.created_at is
    'When the token was first registered.';

comment on column public.user_device_tokens.updated_at is
    'When the token was last updated.';

-- ---------------------------------------------------------------------------
-- 2. Index for fast token lookup by user
-- ---------------------------------------------------------------------------
create index idx_user_device_tokens_user_id
  on public.user_device_tokens (user_id);

create index idx_user_device_tokens_token
  on public.user_device_tokens (token);

-- ---------------------------------------------------------------------------
-- 3. Row Level Security policies
-- ---------------------------------------------------------------------------
alter table public.user_device_tokens enable row level security;

-- No client-facing policies are created. Supabase service_role bypasses RLS
-- for the authenticated backend's server-side reads and writes.
