-- Close the gap in the original RLS-hardening check: PostgreSQL's PUBLIC role
-- includes anon, and a policy may target PUBLIC or multiple roles rather than
-- anon alone. Remove only broad policies on the sensitive identity tables;
-- fail closed if any other broad anonymous policy needs explicit review.
do $migration$
declare
    policy_row record;
    offending text;
begin
    for policy_row in
        select schemaname, tablename, policyname
        from pg_policies
        where schemaname = 'public'
          and tablename = any (array['users', 'providers', 'ngos', 'volunteers'])
          and roles && array['anon', 'public']::name[]
          and (
              btrim(coalesce(qual, ''), ' ()') = 'true'
              or btrim(coalesce(with_check, ''), ' ()') = 'true'
          )
    loop
        execute format(
            'drop policy %I on %I.%I',
            policy_row.policyname,
            policy_row.schemaname,
            policy_row.tablename
        );
    end loop;

    select string_agg(
        format('%s.%s.%s', schemaname, tablename, policyname),
        ', '
    )
    into offending
    from pg_policies
    where schemaname = 'public'
      and roles && array['anon', 'public']::name[]
      and (
          btrim(coalesce(qual, ''), ' ()') = 'true'
          or btrim(coalesce(with_check, ''), ' ()') = 'true'
      );

    if offending is not null then
        raise exception
            'Broad anon/PUBLIC RLS policies require review before migration completion: %',
            offending;
    end if;
end;
$migration$;
