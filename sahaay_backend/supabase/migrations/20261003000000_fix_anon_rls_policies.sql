-- ============================================================================
-- Batch 2 security fix: remove broad ANONYMOUS row-level-security policies
-- ============================================================================
--
-- Problem (production-blocking):
--   20260912112505_remote_schema.sql created, on each of the four sensitive
--   identity tables, three `to anon` policies with `using (true)` /
--   `with check (true)`:
--       * Allow anonymous insert  {users,providers,ngos,volunteers}
--       * Allow anonymous select  {users,providers,ngos,volunteers}
--       * Allow anonymous update  {users,providers,ngos,volunteers}
--   With the Supabase anon key (which ships in the Flutter binary) anyone
--   could read every user's row, overwrite profiles, and insert/modify
--   provider/NGO/volunteer records — bypassing FastAPI entirely.
--
-- Intended architecture (unchanged by this migration):
--   Flutter --Firebase ID token--> FastAPI --service-role--> Supabase
--   Protected business data is read/written ONLY through FastAPI, which
--   resolves Firebase UID -> users.firebase_uid -> users.id -> role profile
--   and authorizes by role. The backend's service-role client is unaffected
--   here: service_role bypasses RLS and keeps its table grants.
--
-- What is deliberately KEPT (legitimate, scoped, read-only public access):
--   * donations:  "public_view_available_donations"
--       (select only, status = 'available' AND expiry_time > now())
--   * ngos:       "public_view_verified_ngos"      (select only, verified = true)
--   * providers:  "public_view_verified_providers" (select only, verified = true)
--   Flutter itself reads exclusively through the FastAPI backend today, but
--   these three policies are scoped, read-only and intentional, so removing
--   them is not required to close the vulnerability and they are preserved.
--
-- Nothing is dropped or altered at the TABLE level: no tables, rows, columns,
-- grants, indexes or triggers are touched. Only the 12 unsafe policies are
-- dropped (IF EXISTS so the migration is idempotent on environments where a
-- policy may already have been removed by hand).
-- ============================================================================

-- users: identity table (firebase_uid -> role). Never anonymous-readable.
drop policy if exists "Allow anonymous insert users" on public.users;
drop policy if exists "Allow anonymous select users" on public.users;
drop policy if exists "Allow anonymous update users" on public.users;

-- providers: business table behind the provider dashboards.
drop policy if exists "Allow anonymous insert providers" on public.providers;
drop policy if exists "Allow anonymous select providers" on public.providers;
drop policy if exists "Allow anonymous update providers" on public.providers;

-- ngos: business table behind NGO claims and matching.
drop policy if exists "Allow anonymous insert ngos" on public.ngos;
drop policy if exists "Allow anonymous select ngos" on public.ngos;
drop policy if exists "Allow anonymous update ngos" on public.ngos;

-- volunteers: identity + live location table.
drop policy if exists "Allow anonymous insert volunteers" on public.volunteers;
drop policy if exists "Allow anonymous select volunteers" on public.volunteers;
drop policy if exists "Allow anonymous update volunteers" on public.volunteers;

-- Verification (fails the migration loudly if any broad anon policy remains):
do $$
declare
    offending text;
begin
    select string_agg(format('%s.%s', schemaname, tablename), ', ')
      into offending
      from pg_policies
     where schemaname = 'public'
       and roles = array['anon']::name[]
       and (qual = 'true' or with_check = 'true');

    if offending is not null then
        raise exception
            'Unsafe broad anon RLS policy still present on: %', offending;
    end if;
end $$;
