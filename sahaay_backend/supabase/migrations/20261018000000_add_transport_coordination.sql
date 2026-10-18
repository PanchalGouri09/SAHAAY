-- Persist the provider/NGO transport decision on each claim. This migration is
-- additive: existing claims are backfilled and existing delivery rows remain
-- untouched. The service-role-only RPC serializes decisions on the donation row.

create table if not exists public.claim_transport_coordination (
    id uuid primary key default gen_random_uuid(),
    claim_id uuid not null unique references public.claims(id) on delete restrict,
    donation_id uuid not null references public.donations(id) on delete restrict,
    provider_id uuid not null references public.providers(id) on delete restrict,
    ngo_id uuid not null references public.ngos(id) on delete restrict,
    provider_response text check (provider_response in ('yes', 'no')),
    provider_captain_name text,
    provider_captain_phone text,
    ngo_response text check (ngo_response in ('yes', 'no')),
    ngo_captain_name text,
    ngo_captain_phone text,
    responsible_role text check (responsible_role in ('provider', 'ngo', 'volunteer')),
    status text not null default 'awaiting_responses'
        check (status in (
            'awaiting_responses',
            'provider_transport',
            'ngo_transport',
            'searching_for_volunteers',
            'volunteer_assigned',
            'completed'
        )),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (
        (provider_response = 'yes'
            and nullif(btrim(provider_captain_name), '') is not null
            and provider_captain_phone is not null
            and provider_captain_phone ~ '^[6-9][0-9]{9}$')
        or provider_response is distinct from 'yes'
    ),
    check (
        (ngo_response = 'yes'
            and nullif(btrim(ngo_captain_name), '') is not null
            and ngo_captain_phone is not null
            and ngo_captain_phone ~ '^[6-9][0-9]{9}$')
        or ngo_response is distinct from 'yes'
    )
);

create index if not exists claim_transport_coordination_donation_idx
    on public.claim_transport_coordination (donation_id);

alter table public.claim_transport_coordination enable row level security;
revoke all on public.claim_transport_coordination from public, anon, authenticated;
grant all on public.claim_transport_coordination to service_role;

insert into public.claim_transport_coordination
    (claim_id, donation_id, provider_id, ngo_id)
select c.id, c.donation_id, d.provider_id, c.ngo_id
from public.claims c
join public.donations d on d.id = c.donation_id
on conflict (claim_id) do nothing;

update public.claim_transport_coordination c
set responsible_role = 'volunteer',
    status = 'volunteer_assigned',
    updated_at = now()
from public.deliveries d
where d.claim_id = c.claim_id
  and d.volunteer_id is not null
  and c.status = 'awaiting_responses';

update public.claim_transport_coordination c
set status = 'completed',
    updated_at = now()
from public.claims cl
where cl.id = c.claim_id
  and cl.status = 'completed'
  and c.status <> 'completed';

update public.donations d
set volunteer_transport_required = exists (
    select 1
    from public.claim_transport_coordination c
    join public.claims cl on cl.id = c.claim_id
    where c.donation_id = d.id
      and cl.status in ('pending', 'accepted', 'completed')
      and c.status in ('searching_for_volunteers', 'volunteer_assigned')
);

create or replace function public.initialize_claim_transport_coordination()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_provider_id uuid;
begin
    select d.provider_id into v_provider_id
    from public.donations d
    where d.id = new.donation_id;

    if v_provider_id is null then
        raise exception 'donation provider not found';
    end if;

    insert into public.claim_transport_coordination
        (claim_id, donation_id, provider_id, ngo_id)
    values
        (new.id, new.donation_id, v_provider_id, new.ngo_id)
    on conflict (claim_id) do nothing;
    return new;
end;
$$;

drop trigger if exists claims_initialize_transport_coordination on public.claims;
create trigger claims_initialize_transport_coordination
after insert on public.claims
for each row execute function public.initialize_claim_transport_coordination();

create or replace function public.respond_to_claim_transport(
    p_claim_id uuid,
    p_actor_role text,
    p_response text,
    p_captain_name text default null,
    p_captain_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_coord public.claim_transport_coordination%rowtype;
    v_claim public.claims%rowtype;
    v_prior_claim public.claims%rowtype;
    v_donation public.donations%rowtype;
    v_ngo public.ngos%rowtype;
    v_delivery public.deliveries%rowtype;
    v_existing_response text;
begin
    if p_actor_role not in ('provider', 'ngo')
       or p_response not in ('yes', 'no') then
        raise exception 'invalid transport response';
    end if;
    if p_response = 'yes' and (
        nullif(btrim(p_captain_name), '') is null
        or p_captain_phone is null
        or p_captain_phone !~ '^[6-9][0-9]{9}$'
    ) then
        raise exception 'valid captain name and Indian mobile number are required';
    end if;

    select * into v_claim from public.claims
    where id = p_claim_id;
    if not found or v_claim.status not in ('pending', 'accepted') then
        raise exception 'claim is not open for transport coordination';
    end if;

    -- All coordination and volunteer acceptance operations lock the donation
    -- first, making the winner decision and task transition serializable.
    select * into v_donation from public.donations
    where id = v_claim.donation_id
    for update;
    select * into v_claim from public.claims
    where id = p_claim_id
    for update;
    if not found or v_claim.status not in ('pending', 'accepted') then
        raise exception 'claim is not open for transport coordination';
    end if;
    select * into v_coord from public.claim_transport_coordination
    where claim_id = p_claim_id
    for update;
    if not found then
        raise exception 'transport coordination record is unavailable';
    end if;
    if (p_actor_role = 'provider' and v_coord.provider_id is null)
       or (p_actor_role = 'ngo' and v_coord.ngo_id is null) then
        raise exception 'transport participant not found';
    end if;

    if p_actor_role = 'provider' then
        v_existing_response := v_coord.provider_response;
    else
        v_existing_response := v_coord.ngo_response;
    end if;
    if v_existing_response is not null then
        if v_existing_response = p_response then
            return to_jsonb(v_coord);
        end if;
        raise exception 'transport response has already been submitted';
    end if;
    if v_coord.responsible_role is not null
       and v_coord.responsible_role <> p_actor_role then
        -- The losing party may still record a No, or acknowledge a Yes, but
        -- cannot change the already confirmed transport arrangement.
        if p_response = 'yes' then
            if p_actor_role = 'provider' then
                update public.claim_transport_coordination
                set provider_response = 'yes',
                    provider_captain_name = btrim(p_captain_name),
                    provider_captain_phone = p_captain_phone,
                    updated_at = now()
                where claim_id = p_claim_id returning * into v_coord;
            else
                update public.claim_transport_coordination
                set ngo_response = 'yes',
                    ngo_captain_name = btrim(p_captain_name),
                    ngo_captain_phone = p_captain_phone,
                    updated_at = now()
                where claim_id = p_claim_id returning * into v_coord;
            end if;
        else
            if p_actor_role = 'provider' then
                update public.claim_transport_coordination
                set provider_response = 'no', updated_at = now()
                where claim_id = p_claim_id returning * into v_coord;
            else
                update public.claim_transport_coordination
                set ngo_response = 'no', updated_at = now()
                where claim_id = p_claim_id returning * into v_coord;
            end if;
        end if;
        return to_jsonb(v_coord);
    end if;

    if p_actor_role = 'provider' then
        update public.claim_transport_coordination
        set provider_response = p_response,
            provider_captain_name = case when p_response = 'yes' then btrim(p_captain_name) else null end,
            provider_captain_phone = case when p_response = 'yes' then p_captain_phone else null end,
            responsible_role = case
                when p_response = 'yes' then 'provider'
                else responsible_role
            end,
            status = case
                when p_response = 'yes' then 'provider_transport'
                else status
            end,
            updated_at = now()
        where claim_id = p_claim_id returning * into v_coord;
    else
        update public.claim_transport_coordination
        set ngo_response = p_response,
            ngo_captain_name = case when p_response = 'yes' then btrim(p_captain_name) else null end,
            ngo_captain_phone = case when p_response = 'yes' then p_captain_phone else null end,
            responsible_role = case
                when p_response = 'yes' then 'ngo'
                else responsible_role
            end,
            status = case
                when p_response = 'yes' then 'ngo_transport'
                else status
            end,
            updated_at = now()
        where claim_id = p_claim_id returning * into v_coord;
    end if;

    if v_coord.provider_response = 'no' and v_coord.ngo_response = 'no' then
        select * into v_ngo from public.ngos where id = v_coord.ngo_id;
        select * into v_delivery from public.deliveries
        where donation_id = v_coord.donation_id
        for update;
        if found then
            if v_delivery.volunteer_id is not null then
                update public.claim_transport_coordination
                set responsible_role = 'volunteer',
                    status = 'volunteer_assigned',
                    updated_at = now()
                where claim_id = p_claim_id returning * into v_coord;
            elsif v_delivery.status = 'unassigned' then
                if v_delivery.claim_id <> p_claim_id then
                    select * into v_prior_claim
                    from public.claims
                    where id = v_delivery.claim_id
                    for update;
                    if not found or v_prior_claim.status not in ('cancelled', 'rejected') then
                        raise exception 'existing delivery task belongs to another live claim';
                    end if;
                    update public.deliveries
                    set claim_id = p_claim_id,
                        delivery_address = v_ngo.address,
                        pickup_time = v_donation.pickup_deadline,
                        pickup_latitude = v_donation.latitude,
                        pickup_longitude = v_donation.longitude,
                        dropoff_latitude = v_ngo.latitude,
                        dropoff_longitude = v_ngo.longitude,
                        updated_at = now()
                    where id = v_delivery.id
                    returning * into v_delivery;
                end if;
                update public.claim_transport_coordination
                set status = 'searching_for_volunteers',
                    updated_at = now()
                where claim_id = p_claim_id returning * into v_coord;
            else
                raise exception 'existing delivery task is not available for this claim';
            end if;
        else
            insert into public.deliveries
            (
                donation_id, claim_id, pickup_address, delivery_address,
                pickup_time, pickup_latitude, pickup_longitude,
                dropoff_latitude, dropoff_longitude, status, notes
            )
            values
            (
                v_coord.donation_id,
                p_claim_id,
                v_donation.pickup_address,
                v_ngo.address,
                v_donation.pickup_deadline,
                v_donation.latitude,
                v_donation.longitude,
                v_ngo.latitude,
                v_ngo.longitude,
                'unassigned',
                    'Transport is needed after both claim participants declined.'
                )
            returning * into v_delivery;
            update public.claim_transport_coordination
            set status = 'searching_for_volunteers',
                updated_at = now()
            where claim_id = p_claim_id returning * into v_coord;
        end if;
    end if;

    update public.donations d
    set volunteer_transport_required = exists (
        select 1
        from public.claim_transport_coordination c
        join public.claims cl on cl.id = c.claim_id
        where c.donation_id = d.id
          and cl.status in ('pending', 'accepted', 'completed')
          and c.status in ('searching_for_volunteers', 'volunteer_assigned')
    )
    where d.id = v_coord.donation_id;

    return to_jsonb(v_coord);
end;
$$;

create or replace function public.confirm_claim_volunteer_assignment(
    p_delivery_id uuid,
    p_volunteer_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_delivery public.deliveries%rowtype;
    v_coord public.claim_transport_coordination%rowtype;
    v_donation_id uuid;
    v_claim_id uuid;
    v_claim public.claims%rowtype;
begin
    select donation_id, claim_id into v_donation_id, v_claim_id
    from public.deliveries where id = p_delivery_id;
    if v_donation_id is null then
        raise exception 'delivery not found';
    end if;
    perform 1 from public.donations
    where id = v_donation_id for update;
    select * into v_claim from public.claims
    where id = v_claim_id for update;
    if not found or v_claim.status not in ('pending', 'accepted') then
        raise exception 'claim is not open for volunteer transport';
    end if;
    select * into v_coord from public.claim_transport_coordination
    where claim_id = v_claim_id
    for update;
    if not found or v_coord.status <> 'searching_for_volunteers' then
        raise exception 'volunteer search is not open for this donation';
    end if;
    select * into v_delivery from public.deliveries
    where id = p_delivery_id
    for update;
    if not found or v_delivery.status <> 'unassigned'
       or v_delivery.volunteer_id is not null then
        raise exception 'transport task has already been accepted';
    end if;

    update public.deliveries
    set volunteer_id = p_volunteer_id, status = 'assigned', updated_at = now()
    where id = p_delivery_id and volunteer_id is null
    returning * into v_delivery;
    if not found then
        raise exception 'transport task has already been accepted';
    end if;
    update public.claim_transport_coordination
    set responsible_role = 'volunteer',
        status = 'volunteer_assigned',
        updated_at = now()
    where id = v_coord.id
    returning * into v_coord;

    update public.donations d
    set volunteer_transport_required = exists (
        select 1
        from public.claim_transport_coordination c
        join public.claims cl on cl.id = c.claim_id
        where c.donation_id = d.id
          and cl.status in ('pending', 'accepted', 'completed')
          and c.status in ('searching_for_volunteers', 'volunteer_assigned')
    )
    where d.id = v_coord.donation_id;

    return jsonb_build_object(
        'delivery', to_jsonb(v_delivery),
        'coordination', to_jsonb(v_coord)
    );
end;
$$;

-- Keep the new coordination state in the same transaction as the existing
-- secure handover completion. The code-validation contract is unchanged.
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

    update public.claim_transport_coordination
    set status = 'completed',
        updated_at = v_now
    where claim_id = p_claim_id;

    update public.donations d
    set volunteer_transport_required = exists (
        select 1
        from public.claim_transport_coordination c
        join public.claims cl on cl.id = c.claim_id
        where c.donation_id = d.id
          and cl.status in ('pending', 'accepted', 'completed')
          and c.status in ('searching_for_volunteers', 'volunteer_assigned')
    )
    where d.id = p_donation_id;

    return jsonb_build_object(
        'status', 'verified',
        'verified_at', v_now
    );
end;
$function$;

revoke all on function public.initialize_claim_transport_coordination() from public, anon, authenticated;
revoke all on function public.respond_to_claim_transport(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.confirm_claim_volunteer_assignment(uuid, uuid) from public, anon, authenticated;
grant execute on function public.respond_to_claim_transport(uuid, text, text, text, text) to service_role;
grant execute on function public.confirm_claim_volunteer_assignment(uuid, uuid) to service_role;

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
            'handover_completed',
            'pickup_updated',
            'acknowledgment_ready',
            'donation_offer',
            'donation_offers_exhausted',
            'donation_no_match',
            'ngo_demo_verification',
            'transport_coordination'
        ]::text[])
    );
