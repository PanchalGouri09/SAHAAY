-- Matching eligibility is derived from saved NGO profile data. This does not
-- change ngos.verified or the separate legal-verification record.

create or replace function public.ngo_ready_for_donation_matching(p_ngo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
    select coalesce((
        select
            n.verified is true
            and nullif(btrim(n.organization_name), '') is not null
            and nullif(btrim(n.address), '') is not null
            and nullif(btrim(n.city), '') is not null
            and n.latitude between -90 and 90
            and n.longitude between -180 and 180
            and n.available_from ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
            and n.available_to ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
            and n.available_from <> n.available_to
            and n.max_capacity_kg > 0
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
        where n.id = p_ngo_id
    ), false);
$function$;

revoke all on function public.ngo_ready_for_donation_matching(uuid)
    from public, anon, authenticated;
grant execute on function public.ngo_ready_for_donation_matching(uuid)
    to service_role;

create or replace function public.start_donation_offer_sequence(
    p_donation_id uuid,
    p_candidates jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
    v_donation public.donations%rowtype;
    v_existing public.donation_offers%rowtype;
    v_candidate public.donation_match_candidates%rowtype;
    v_offer public.donation_offers%rowtype;
    v_max_rank integer;
begin
    if p_candidates is null or jsonb_typeof(p_candidates) <> 'array' then
        raise exception 'p_candidates must be a JSON array';
    end if;

    select * into v_donation
    from public.donations
    where id = p_donation_id
    for update;

    if not found then
        return jsonb_build_object('status', 'not_found');
    end if;
    if v_donation.status <> 'available'
       or v_donation.expiry_time <= clock_timestamp() then
        return jsonb_build_object('status', 'donation_closed');
    end if;

    select coalesce(max(match_rank), 0)
    into v_max_rank
    from public.donation_match_candidates
    where donation_id = p_donation_id;

    with eligible_candidates as (
        select c.*
        from jsonb_to_recordset(p_candidates) as c(
            ngo_id uuid,
            match_rank integer,
            ai_rank integer,
            final_score numeric,
            score_details jsonb
        )
        where public.ngo_ready_for_donation_matching(c.ngo_id)
          and not exists (
              select 1
              from public.donation_match_candidates prior
              where prior.donation_id = p_donation_id
                and prior.ngo_id = c.ngo_id
          )
    )
    insert into public.donation_match_candidates
        (donation_id, ngo_id, match_rank, ai_rank, final_score, score_details)
    select
        p_donation_id,
        c.ngo_id,
        v_max_rank + row_number() over (order by c.match_rank, c.ngo_id)::integer,
        c.ai_rank,
        c.final_score,
        coalesce(c.score_details, '{}'::jsonb)
    from eligible_candidates c
    order by c.match_rank, c.ngo_id
    on conflict (donation_id, ngo_id) do nothing;

    select * into v_existing
    from public.donation_offers
    where donation_id = p_donation_id and status = 'pending';
    if found then
        return jsonb_build_object('status', 'offered', 'offer', to_jsonb(v_existing));
    end if;

    select c.* into v_candidate
    from public.donation_match_candidates c
    where c.donation_id = p_donation_id
      and public.ngo_ready_for_donation_matching(c.ngo_id)
      and not exists (
          select 1
          from public.donation_offers o
          where o.donation_id = c.donation_id
            and o.ngo_id = c.ngo_id
      )
    order by c.match_rank
    limit 1;
    if not found then
        return jsonb_build_object(
            'status',
            case
                when exists (
                    select 1 from public.donation_match_candidates
                    where donation_id = p_donation_id
                ) then 'exhausted'
                else 'no_candidates'
            end
        );
    end if;

    insert into public.donation_offers
        (donation_id, ngo_id, candidate_rank, status, offer_expires_at)
    values (
        p_donation_id,
        v_candidate.ngo_id,
        v_candidate.match_rank,
        'pending',
        clock_timestamp() + interval '5 minutes'
    )
    returning * into v_offer;

    return jsonb_build_object('status', 'offered', 'offer', to_jsonb(v_offer));
end;
$function$;

create or replace function public.respond_to_donation_offer(
    p_offer_id uuid,
    p_ngo_id uuid,
    p_decision text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
    v_offer public.donation_offers%rowtype;
    v_donation public.donations%rowtype;
    v_next public.donation_match_candidates%rowtype;
    v_next_offer public.donation_offers%rowtype;
    v_claim public.claims%rowtype;
    v_other_ngo_ids uuid[];
    v_result_status text;
    v_updated_count integer;
begin
    if p_decision is null or p_decision not in ('accepted', 'declined', 'timeout') then
        return jsonb_build_object('status', 'invalid_decision');
    end if;

    select * into v_offer from public.donation_offers where id = p_offer_id;
    if not found then
        return jsonb_build_object('status', 'not_found');
    end if;

    select * into v_donation
    from public.donations
    where id = v_offer.donation_id
    for update;
    if not found then
        return jsonb_build_object('status', 'donation_closed', 'changed', false);
    end if;

    select * into v_offer
    from public.donation_offers
    where id = p_offer_id
    for update;
    if not found then
        return jsonb_build_object('status', 'not_found', 'changed', false);
    end if;
    if v_offer.status is distinct from 'pending' then
        return jsonb_build_object(
            'status', v_offer.status,
            'donation_id', v_offer.donation_id,
            'changed', false
        );
    end if;
    if p_decision <> 'timeout' and v_offer.ngo_id <> p_ngo_id then
        return jsonb_build_object('status', 'not_your_offer', 'changed', false);
    end if;

    if v_donation.status <> 'available'
       or v_donation.expiry_time <= clock_timestamp() then
        update public.donation_offers
        set status = 'timed_out', responded_at = clock_timestamp()
        where id = p_offer_id and status = 'pending';
        return jsonb_build_object(
            'status', 'expired',
            'donation_id', v_donation.id,
            'changed', true
        );
    end if;

    if p_decision = 'timeout' and v_offer.offer_expires_at > clock_timestamp() then
        return jsonb_build_object('status', 'not_due', 'changed', false);
    end if;

    if p_decision = 'timeout'
       or v_offer.offer_expires_at <= clock_timestamp() then
        v_result_status := 'timed_out';
    else
        v_result_status := p_decision;
    end if;

    if v_result_status = 'accepted'
       and not public.ngo_ready_for_donation_matching(v_offer.ngo_id) then
        return jsonb_build_object(
            'status', 'ngo_not_eligible',
            'donation_id', v_donation.id,
            'changed', false
        );
    end if;

    if v_result_status = 'accepted' then
        select coalesce(array_agg(ngo_id), '{}'::uuid[]) into v_other_ngo_ids
        from public.claims
        where donation_id = v_donation.id
          and status = 'pending'
          and ngo_id <> v_offer.ngo_id;

        update public.donations
        set status = 'claimed', updated_at = clock_timestamp()
        where id = v_donation.id
          and status = 'available'
          and expiry_time > clock_timestamp();
        get diagnostics v_updated_count = row_count;
        if v_updated_count = 0 then
            return jsonb_build_object('status', 'donation_closed', 'changed', false);
        end if;

        insert into public.claims
            (donation_id, ngo_id, requested_quantity, status, notes)
        values
            (v_donation.id, v_offer.ngo_id, v_donation.quantity, 'pending',
             'Created from a ranked donation offer.')
        returning * into v_claim;

        update public.claims
        set status = 'accepted', accepted_at = clock_timestamp()
        where id = v_claim.id
        returning * into v_claim;

        update public.donation_offers
        set status = 'accepted', responded_at = clock_timestamp()
        where id = p_offer_id and status = 'pending';

        return jsonb_build_object(
            'status', 'accepted',
            'donation_id', v_donation.id,
            'changed', true,
            'claim', to_jsonb(v_claim),
            'other_pending_ngo_ids', to_jsonb(v_other_ngo_ids)
        );
    end if;

    update public.donation_offers
    set status = v_result_status, responded_at = clock_timestamp()
    where id = p_offer_id and status = 'pending';

    select c.* into v_next
    from public.donation_match_candidates c
    where c.donation_id = v_donation.id
      and c.match_rank > v_offer.candidate_rank
      and public.ngo_ready_for_donation_matching(c.ngo_id)
      and not exists (
          select 1 from public.donation_offers prior
          where prior.donation_id = c.donation_id and prior.ngo_id = c.ngo_id
      )
    order by c.match_rank
    limit 1;

    if found then
        insert into public.donation_offers
            (donation_id, ngo_id, candidate_rank, status, offer_expires_at)
        values (
            v_donation.id,
            v_next.ngo_id,
            v_next.match_rank,
            'pending',
            clock_timestamp() + interval '5 minutes'
        )
        returning * into v_next_offer;
        return jsonb_build_object(
            'status', v_result_status,
            'donation_id', v_donation.id,
            'changed', true,
            'next_offer', to_jsonb(v_next_offer)
        );
    end if;

    return jsonb_build_object(
        'status', case when v_result_status = 'declined' then 'declined' else 'timed_out' end,
        'donation_id', v_donation.id,
        'changed', true,
        'exhausted', true
    );
end;
$function$;

revoke all on function public.start_donation_offer_sequence(uuid, jsonb)
    from public, anon, authenticated;
revoke all on function public.respond_to_donation_offer(uuid, uuid, text)
    from public, anon, authenticated;
grant execute on function public.start_donation_offer_sequence(uuid, jsonb)
    to service_role;
grant execute on function public.respond_to_donation_offer(uuid, uuid, text)
    to service_role;
