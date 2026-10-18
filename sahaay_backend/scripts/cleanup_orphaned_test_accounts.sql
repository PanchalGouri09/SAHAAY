-- ============================================================================
-- SAHAAY - orphaned test-account cleanup (REVIEWABLE, NOT AUTO-EXECUTED)
-- ----------------------------------------------------------------------------
-- WHAT THIS IS
--   The Firebase Authentication users used during testing were deleted, but
--   their SAHAAY rows in the Supabase `public.users` table (and the linked
--   role/donation/claim/delivery/impact/notification/feedback records) were
--   not. Those rows are "orphaned": `users.firebase_uid` no longer maps to a
--   live Firebase user. They are also why a fresh login with the same email
--   was rejected as "already associated with another SAHAAY account".
--
--   NOTE: the running app now repairs this WITHOUT deleting anything - on login
--   it matches the verified email and re-links (`POST /api/v1/profile/adopt`).
--   Run THIS script only if you additionally want to permanently purge the
--   leftover test data. It is safe to skip it entirely.
--
-- WHAT THIS SCRIPT DOES
--   Deletes only rows whose `users.id` you explicitly list below, together with
--   their dependent records, in foreign-key order. It NEVER touches rows that
--   are not in the target list, and it can only ever remove data you name.
--
-- WHAT IT DOES NOT DO
--   * It does not disable RLS, change policies, or touch auth/Firebase.
--   * It does not truncate or drop any table.
--   * It does not run automatically - you must execute it yourself.
--
-- REQUIRED BEFORE RUNNING
--   1. Run only against a NON-PRODUCTION / test Supabase project.
--   2. Take a manual backup / point-in-time snapshot first.
--   3. Fill in `_cleanup_targets` (STEP 2) with the exact `users.id` values
--      you want gone. Get them from the read-only report produced by
--      diagnose_accounts.py (they are the masked-id rows listed there).
--   4. Confirm every target row is an ORPHAN (no live Firebase user). This
--      script cannot check Firebase; verifying it is a manual precondition.
--
-- DEFAULT SAFETY: STEP 3 ends in ROLLBACK. Review the row counts it prints,
-- then replace ROLLBACK with COMMIT to actually apply the deletion.
-- ============================================================================


-- ============================================================================
-- STEP 1 - PREVIEW (READ ONLY). Inspect before deleting anything.
-- Shows every user with their role and how many dependent records each owns.
-- ============================================================================
select
    u.id                              as user_id,
    u.role,
    u.full_name,
    u.email,
    u.firebase_uid,
    (select count(*) from public.providers  p where p.user_id = u.id) as provider_rows,
    (select count(*) from public.ngos       n where n.user_id = u.id) as ngo_rows,
    (select count(*) from public.volunteers v where v.user_id = u.id) as volunteer_rows,
    (select count(*) from public.notifications no where no.user_id = u.id) as notifications,
    (select count(*) from public.feedback      f  where f.user_id = u.id) as feedback,
    (select count(*) from public.donations     d
        join public.providers p2 on p2.id = d.provider_id
        where p2.user_id = u.id)                                        as donations,
    (select count(*) from public.claims        c
        join public.ngos n2 on n2.id = c.ngo_id
        where n2.user_id = u.id)                                        as claims
from public.users u
order by u.role, u.created_at;


-- ============================================================================
-- STEP 2 - TARGETS (SESSION-LOCAL). List ONLY the `users.id` values to delete.
-- Replace the placeholder UUIDs with the real ids from STEP 1 / the report.
-- Leave this list empty to abort safely (STEP 3 refuses to run on 0 targets).
-- ============================================================================
create temp table _cleanup_targets (user_id uuid primary key) on commit drop;

insert into _cleanup_targets (user_id) values
    ('00000000-0000-0000-0000-000000000000')   -- <<< replace / add real ids
    -- ,('11111111-1111-1111-1111-111111111111')
    -- ,('22222222-2222-2222-2222-222222222222')
;

-- Convenience alternative: derive targets by exact email instead of uuid.
-- Only use this if you are certain each email is a test account.
-- insert into _cleanup_targets (user_id)
--   select id from public.users
--   where email in ('test1@example.com', 'test2@example.com');


-- ============================================================================
-- STEP 3 - DELETE (TRANSACTIONAL). Explicit FK-ordered deletes, then the rows.
-- Ends in ROLLBACK: review the printed confirmations, then change to COMMIT.
-- ============================================================================
begin;

-- Guard 0: refuse to run when no targets were supplied.
do $$
begin
    if (select count(*) from _cleanup_targets) = 0 then
        raise exception 'No cleanup targets supplied - aborting (nothing deleted).';
    end if;
end $$;

-- Guard 1: refuse if any target row is missing (typo'd uuid) so the counts
-- below are meaningful and no partial surprise deletion occurs.
do $$
begin
    if (select count(*) from _cleanup_targets t
        left join public.users u on u.id = t.user_id
        where u.id is null) > 0 then
        raise exception 'A target user_id does not exist in public.users - aborting.';
    end if;
end $$;

-- 1) Leaves/doc artifacts that reference the targets' donations.
delete from public.impact_records ir
using public.donations d
join public.providers p on p.id = d.provider_id
join _cleanup_targets t on t.user_id = p.user_id
where ir.donation_id = d.id;

delete from public.deliveries dl
using public.donations d
join public.providers p on p.id = d.provider_id
join _cleanup_targets t on t.user_id = p.user_id
where dl.donation_id = d.id;

-- 2) Claims (by the targets' NGO rows and by the targets' donations).
delete from public.claims c
using public.ngos n
join _cleanup_targets t on t.user_id = n.user_id
where c.ngo_id = n.id;

delete from public.claims c
using public.donations d
join public.providers p on p.id = d.provider_id
join _cleanup_targets t on t.user_id = p.user_id
where c.donation_id = d.id;

-- 3) Donations owned by the targets' provider rows.
delete from public.donations d
using public.providers p
join _cleanup_targets t on t.user_id = p.user_id
where d.provider_id = p.id;

-- 4) Direct children of the users (FK is ON DELETE CASCADE, made explicit
--    here so the operation and its row counts are fully reviewable).
delete from public.notifications no using _cleanup_targets t where no.user_id = t.user_id;
delete from public.feedback      f  using _cleanup_targets t where f.user_id  = t.user_id;

-- 5) Role rows.
delete from public.providers  p using _cleanup_targets t where p.user_id = t.user_id;
delete from public.ngos       n using _cleanup_targets t where n.user_id = t.user_id;
delete from public.volunteers v using _cleanup_targets t where v.user_id = t.user_id;

-- 6) Finally the users themselves.
delete from public.users u using _cleanup_targets t where u.id = t.user_id;

-- Post-conditions: these must all be 0 for the targeted ids.
select
    (select count(*) from public.users u join _cleanup_targets t on t.user_id = u.id)         as remaining_users,
    (select count(*) from public.providers p join _cleanup_targets t on t.user_id = p.user_id) as remaining_providers,
    (select count(*) from public.ngos n join _cleanup_targets t on t.user_id = n.user_id)      as remaining_ngos,
    (select count(*) from public.volunteers v join _cleanup_targets t on t.user_id = v.user_id) as remaining_volunteers;

rollback;   -- <-- change to `commit;` ONLY after the counts above look right.
