-- Durable, sequential NGO offers based on the backend's existing match ranking.
-- This migration is forward-only and is intentionally not applied by the app.

create table if not exists public.donation_match_candidates (
    id uuid primary key default gen_random_uuid(),
    donation_id uuid not null references public.donations(id) on delete cascade,
    ngo_id uuid not null references public.ngos(id) on delete cascade,
    match_rank integer not null check (match_rank > 0),
    ai_rank integer not null check (ai_rank > 0),
    final_score numeric(5, 2) not null check (final_score >= 0 and final_score <= 100),
    score_details jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    constraint donation_match_candidates_donation_ngo_key unique (donation_id, ngo_id),
    constraint donation_match_candidates_donation_rank_key unique (donation_id, match_rank)
);

create table if not exists public.donation_offers (
    id uuid primary key default gen_random_uuid(),
    donation_id uuid not null references public.donations(id) on delete cascade,
    ngo_id uuid not null references public.ngos(id) on delete cascade,
    candidate_rank integer not null check (candidate_rank > 0),
    status text not null default 'pending'
        check (status = any (array['pending', 'accepted', 'declined', 'timed_out'])),
    offer_expires_at timestamptz not null,
    created_at timestamptz not null default now(),
    responded_at timestamptz,
    constraint donation_offers_donation_ngo_key unique (donation_id, ngo_id)
);

create unique index if not exists donation_offers_one_pending_per_donation
    on public.donation_offers (donation_id)
    where status = 'pending';
create index if not exists donation_offers_due_idx
    on public.donation_offers (offer_expires_at)
    where status = 'pending';
create index if not exists donation_match_candidates_rank_idx
    on public.donation_match_candidates (donation_id, match_rank);

alter table public.donation_match_candidates enable row level security;
alter table public.donation_offers enable row level security;

-- Extend (never replace existing meanings of) the currently deployed event
-- types with the two offer lifecycle events used by the backend.
alter table public.notifications
    drop constraint if exists notifications_type_check;
alter table public.notifications
    add constraint notifications_type_check check (
        type is null
        or type = any (array[
            'new_nearby_donation',
            'claim_submitted',
            'claim_accepted',
            'claim_rejected',
            'donation_claimed',
            'volunteer_assigned',
            'pickup_reminder',
            'delivery_completed',
            'delivery_failed',
            'donation_expiring_soon',
            'donation_cancelled',
            'claim_cancelled',
            'claim_completed',
            'handover_verified',
            'pickup_updated',
            'acknowledgment_ready',
            'donation_offer',
            'donation_offers_exhausted'
        ]::text[])
    );

revoke all on public.donation_match_candidates from public, anon, authenticated;
revoke all on public.donation_offers from public, anon, authenticated;
grant all on public.donation_match_candidates to service_role;
grant all on public.donation_offers to service_role;

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
    join public.ngos n on n.id = c.ngo_id and n.verified = true
    order by c.match_rank;

    select c.* into v_candidate
    from public.donation_match_candidates c
    join public.ngos n on n.id = c.ngo_id and n.verified = true
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

    -- Lock the donation first. Every offer for it serializes on this row.
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
    join public.ngos n on n.id = c.ngo_id and n.verified = true
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

create or replace function public.expire_due_donation_offers(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
    v_offer_id uuid;
    v_transition jsonb;
    v_results jsonb := '[]'::jsonb;
    v_checked integer := 0;
    v_advanced integer := 0;
    v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
    -- The database clock selects due work. Do not lock offers here: the response
    -- RPC locks donation then offer, and every competing path uses that order.
    for v_offer_id in
        select id
        from public.donation_offers
        where status = 'pending'
          and offer_expires_at <= clock_timestamp()
        order by offer_expires_at
        limit v_limit
    loop
        v_transition := public.respond_to_donation_offer(
            v_offer_id, null, 'timeout'
        );
        v_results := v_results || jsonb_build_array(v_transition);
        v_checked := v_checked + 1;
        if coalesce((v_transition->>'changed')::boolean, false) then
            v_advanced := v_advanced + 1;
        end if;
    end loop;

    return jsonb_build_object(
        'checked', v_checked,
        'advanced', v_advanced,
        'results', v_results
    );
end;
$function$;

revoke all on function public.start_donation_offer_sequence(uuid, jsonb)
    from public, anon, authenticated;
revoke all on function public.respond_to_donation_offer(uuid, uuid, text)
    from public, anon, authenticated;
revoke all on function public.expire_due_donation_offers(integer)
    from public, anon, authenticated;
grant execute on function public.start_donation_offer_sequence(uuid, jsonb)
    to service_role;
grant execute on function public.respond_to_donation_offer(uuid, uuid, text)
    to service_role;
grant execute on function public.expire_due_donation_offers(integer)
    to service_role;
