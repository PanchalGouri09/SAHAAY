-- FCM device tokens, one row per (user, device).
--
-- Security posture: RLS is ENABLED with ZERO client policies. The anon and
-- authenticated Supabase keys therefore cannot read or write tokens at all;
-- only the FastAPI service role (which bypasses RLS) manages this table. Tokens
-- are never exposed to any client and never accepted from a request body as a
-- target recipient -- recipients are always resolved server-side from users.id.

create table if not exists public.user_device_tokens (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.users (id) on delete cascade,
    token text not null unique,
    platform text not null default 'android',
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now()
);

create index if not exists user_device_tokens_user_id_idx
    on public.user_device_tokens (user_id);

alter table "public"."user_device_tokens" enable row level security;
