-- Ranked offers must accept the same demo-verification eligibility as the
-- matching API. Demo verification remains distinct from legal verification:
-- this migration never changes ngos.verified.

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

    select * into v_existing
    from public.donation_offers
    where donation_id = p_donation_id and status = 'pending';
    if found then
        return jsonb_build_object('status', 'offered', 'offer', to_jsonb(v_existing));
    end if;
    if exists (
        select 1 from public.donation_match_candidates
        where donation_id = p_donation_id
    ) then
        return jsonb_build_object('status', 'already_started');
    end if;
    if jsonb_array_length(p_candidates) = 0 then
        return jsonb_build_object('status', 'no_candidates');
    end if;

    insert into public.donation_match_candidates
        (donation_id, ngo_id, match_rank, ai_rank, final_score, score_details)
    select p_donation_id, c.ngo_id, c.match_rank, c.ai_rank, c.final_score,
           coalesce(c.score_details, '{}'::jsonb)
    from jsonb_to_recordset(p_candidates) as c(
        ngo_id uuid,
        match_rank integer,
        ai_rank integer,
        final_score numeric,
        score_details jsonb
    )
    join public.ngos n
      on n.id = c.ngo_id
     and (n.verified is true or n.demo_verified is true)
    order by c.match_rank;

    select c.* into v_candidate
    from public.donation_match_candidates c
    join public.ngos n
      on n.id = c.ngo_id
     and (n.verified is true or n.demo_verified is true)
    where c.donation_id = p_donation_id
    order by c.match_rank
    limit 1;
    if not found then
        return jsonb_build_object('status', 'no_candidates');
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
       and not exists (
           select 1
           from public.ngos n
           where n.id = v_offer.ngo_id
             and (n.verified is true or n.demo_verified is true)
       ) then
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
    join public.ngos n
      on n.id = c.ngo_id
     and (n.verified is true or n.demo_verified is true)
    where c.donation_id = v_donation.id
      and c.match_rank > v_offer.candidate_rank
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
