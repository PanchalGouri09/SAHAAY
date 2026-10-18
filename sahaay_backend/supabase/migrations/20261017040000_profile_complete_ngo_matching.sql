-- Matching readiness is determined only by the existing NGO profile fields.
-- Legacy legal/demo verification values remain untouched and are not read.
create or replace function public.ngo_profile_is_complete(p_ngo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
    select coalesce((
        select
            nullif(btrim(u.full_name), '') is not null
            and u.role = 'ngo'
            and u.email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
            and case
                when coalesce(u.phone, n.phone) is null then false
                else
                    case
                        when regexp_replace(coalesce(u.phone, n.phone), '[[:space:]().-]', '', 'g') like '+91%'
                            then substring(regexp_replace(coalesce(u.phone, n.phone), '[[:space:]().-]', '', 'g') from 4)
                        when regexp_replace(coalesce(u.phone, n.phone), '[[:space:]().-]', '', 'g') like '0091%'
                            then substring(regexp_replace(coalesce(u.phone, n.phone), '[[:space:]().-]', '', 'g') from 5)
                        when length(regexp_replace(coalesce(u.phone, n.phone), '[[:space:]().-]', '', 'g')) = 12
                             and regexp_replace(coalesce(u.phone, n.phone), '[[:space:]().-]', '', 'g') like '91%'
                            then substring(regexp_replace(coalesce(u.phone, n.phone), '[[:space:]().-]', '', 'g') from 3)
                        else regexp_replace(coalesce(u.phone, n.phone), '[[:space:]().-]', '', 'g')
                    end ~ '^[6-9][0-9]{9}$'
            end
            and nullif(btrim(n.organization_name), '') is not null
            and nullif(btrim(n.address), '') is not null
            and nullif(btrim(n.city), '') is not null
            and n.latitude between -90 and 90
            and n.longitude between -180 and 180
            and n.available_from ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
            and n.available_to ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
            and n.available_from <> n.available_to
            and n.max_capacity_kg > 0
            and n.max_capacity_kg not in ('Infinity'::double precision, '-Infinity'::double precision, 'NaN'::double precision)
            and coalesce(array_length(n.preferred_food_types, 1), 0) > 0
            and not exists (
                select 1 from unnest(n.preferred_food_types) f
                where nullif(btrim(f), '') is null
            )
            and coalesce(array_length(n.dietary_preferences, 1), 0) > 0
            and not exists (
                select 1 from unnest(n.dietary_preferences) d
                where nullif(btrim(d), '') is null
            )
        from public.ngos n
        join public.users u on u.id = n.user_id
        where n.id = p_ngo_id
    ), false);
$function$;

create or replace function public.ngo_ready_for_donation_matching(p_ngo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
    select public.ngo_profile_is_complete(p_ngo_id);
$function$;

revoke all on function public.ngo_profile_is_complete(uuid)
    from public, anon, authenticated;
revoke all on function public.ngo_ready_for_donation_matching(uuid)
    from public, anon, authenticated;
grant execute on function public.ngo_profile_is_complete(uuid)
    to service_role;
grant execute on function public.ngo_ready_for_donation_matching(uuid)
    to service_role;
