-- Serialize handover code issuance, attempts, and completion at the database
-- boundary. Both functions lock the donation before the claim, matching the
-- ranked-offer transition's lock order and keeping reassignment/cancellation
-- from racing a handover transition.

create or replace function public.issue_donation_handover_code(
    p_claim_id uuid,
    p_donation_id uuid,
    p_code_hash text,
    p_expires_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
    v_donation public.donations%rowtype;
    v_claim public.claims%rowtype;
    v_now timestamptz := clock_timestamp();
begin
    if p_code_hash is null or p_code_hash !~ '^[0-9a-f]{64}$'
       or p_expires_at is null
       or p_expires_at <= v_now
       or p_expires_at > v_now + interval '15 minutes' then
        return jsonb_build_object('status', 'invalid_request');
    end if;

    select * into v_donation
    from public.donations
    where id = p_donation_id
    for update;
    if not found then
        return jsonb_build_object('status', 'donation_not_found');
    end if;

    select * into v_claim
    from public.claims
    where id = p_claim_id
      and donation_id = p_donation_id
    for update;
    if not found then
        return jsonb_build_object('status', 'claim_not_found');
    end if;
    if v_claim.handover_verified_at is not null then
        return jsonb_build_object('status', 'already_verified');
    end if;
    if v_claim.status <> 'accepted'
       or v_donation.status in ('available', 'expired', 'cancelled') then
        return jsonb_build_object('status', 'claim_closed');
    end if;
    if v_claim.handover_code_hash is not null
       and v_claim.handover_code_expires_at > v_now then
        return jsonb_build_object('status', 'active_code');
    end if;

    update public.claims
    set handover_code_hash = p_code_hash,
        handover_code_expires_at = p_expires_at,
        handover_code_attempts = 0,
        updated_at = v_now
    where id = p_claim_id;

    return jsonb_build_object('status', 'issued');
end;
$function$;

create or replace function public.verify_donation_handover(
    p_claim_id uuid,
    p_donation_id uuid,
    p_candidate_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $function$
declare
    v_donation public.donations%rowtype;
    v_claim public.claims%rowtype;
    v_attempts integer;
    v_now timestamptz := clock_timestamp();
begin
    select * into v_donation
    from public.donations
    where id = p_donation_id
    for update;
    if not found then
        return jsonb_build_object('status', 'donation_not_found');
    end if;

    select * into v_claim
    from public.claims
    where id = p_claim_id
      and donation_id = p_donation_id
    for update;
    if not found then
        return jsonb_build_object('status', 'claim_not_found');
    end if;
    if v_claim.handover_verified_at is not null then
        return jsonb_build_object(
            'status', 'already_verified',
            'verified_at', v_claim.handover_verified_at
        );
    end if;
    if v_claim.status <> 'accepted'
       or v_donation.status in ('available', 'expired', 'cancelled') then
        return jsonb_build_object('status', 'claim_closed');
    end if;
    if v_claim.handover_code_hash is null
       or v_claim.handover_code_expires_at is null
       or v_claim.handover_code_expires_at <= v_now then
        return jsonb_build_object('status', 'expired');
    end if;

    v_attempts := coalesce(v_claim.handover_code_attempts, 0);
    if v_attempts >= 10 then
        return jsonb_build_object('status', 'locked');
    end if;
    if p_candidate_hash is null
       or p_candidate_hash !~ '^[0-9a-f]{64}$'
       or v_claim.handover_code_hash <> p_candidate_hash then
        v_attempts := v_attempts + 1;
        update public.claims
        set handover_code_attempts = v_attempts,
            updated_at = v_now
        where id = p_claim_id;
        return jsonb_build_object(
            'status', 'wrong_code',
            'remaining_attempts', greatest(10 - v_attempts, 0)
        );
    end if;

    update public.claims
    set status = 'completed',
        handover_verified_at = v_now,
        handover_code_hash = null,
        handover_code_expires_at = null,
        handover_code_attempts = 0,
        updated_at = v_now
    where id = p_claim_id;

    update public.donations
    set status = 'completed',
        updated_at = v_now
    where id = p_donation_id
      and status not in ('expired', 'cancelled');

    return jsonb_build_object(
        'status', 'verified',
        'verified_at', v_now
    );
end;
$function$;

revoke all on function public.issue_donation_handover_code(uuid, uuid, text, timestamptz)
    from public, anon, authenticated;
revoke all on function public.verify_donation_handover(uuid, uuid, text)
    from public, anon, authenticated;
grant execute on function public.issue_donation_handover_code(uuid, uuid, text, timestamptz)
    to service_role;
grant execute on function public.verify_donation_handover(uuid, uuid, text)
    to service_role;
