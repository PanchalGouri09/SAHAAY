-- FCM device tokens, one row per device token.
--
-- RLS is enabled with no client policies. Only the FastAPI service role
-- manages these rows. User ids and push recipients are resolved server-side.

create table if not exists public.user_device_tokens (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.users (id) on delete cascade,
    token text not null unique,
    platform text not null default 'android',
    created_at timestamp with time zone not null default now(),
    updated_at timestamp with time zone not null default now()
);

comment on table public.user_device_tokens is
    'FCM/APNs tokens associated with backend-derived SAHAAY users.';

comment on column public.user_device_tokens.user_id is
    'Backend-derived users.id; never supplied as a token recipient by a client.';

create index if not exists user_device_tokens_user_id_idx
    on public.user_device_tokens (user_id);

alter table public.user_device_tokens enable row level security;
