alter table public.users
  add column if not exists leaderboard_public boolean not null default false;
