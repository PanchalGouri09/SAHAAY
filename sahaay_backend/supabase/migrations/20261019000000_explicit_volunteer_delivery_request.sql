-- Make volunteer transport an explicit, claim-linked request after both
-- participants decline, and reject coordination/assignment after real expiry.
-- Existing assignments and delivery rows are retained.

alter table public.claim_transport_coordination
    drop constraint if exists claim_transport_coordination_status_check;

alter table public.claim_transport_coordination
    add constraint claim_transport_coordination_status_check
    check (status in (
        'awaiting_responses',
        'awaiting_volunteer_request',
        'provider_transport',
        'ngo_transport',
        'searching_for_volunteers',
        'volunteer_assigned',
        'completed'
    ));

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
    v_claim public.claims%rowtype;
    v_coord public.claim_transport_coordination%rowtype;
    v_donation public.donations%rowtype;
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

    select * into v_claim from public.claims where id = p_claim_id;
    if not found then
        raise exception 'claim is not open for transport coordination';
    end if;
    perform 1 from public.donations
    where id = v_claim.donation_id for update;
    select * into v_donation from public.donations
    where id = v_claim.donation_id;
    select * into v_claim from public.claims
    where id = p_claim_id for update;
    if not found or v_claim.status not in ('pending', 'accepted')
       or v_donation.status in ('expired', 'cancelled', 'completed', 'delivered')
       or v_donation.expiry_time is null
       or v_donation.expiry_time <= clock_timestamp()
       or v_donation.pickup_deadline is null
       or v_donation.pickup_deadline <= clock_timestamp() then
        raise exception 'claim or delivery has expired or is not open';
    end if;

    select * into v_coord from public.claim_transport_coordination
    where claim_id = p_claim_id for update;
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

    if p_actor_role = 'provider' then
        update public.claim_transport_coordination
        set provider_response = p_response,
            provider_captain_name = case when p_response = 'yes' then btrim(p_captain_name) else null end,
            provider_captain_phone = case when p_response = 'yes' then p_captain_phone else null end,
            responsible_role = case
                when p_response = 'yes' and responsible_role is null then 'provider'
                else responsible_role
            end,
            status = case
                when p_response = 'yes' and responsible_role is null then 'provider_transport'
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
                when p_response = 'yes' and responsible_role is null then 'ngo'
                else responsible_role
            end,
            status = case
                when p_response = 'yes' and responsible_role is null then 'ngo_transport'
                else status
            end,
            updated_at = now()
        where claim_id = p_claim_id returning * into v_coord;
    end if;

    if v_coord.provider_response = 'no' and v_coord.ngo_response = 'no'
       and v_coord.responsible_role is null then
        update public.claim_transport_coordination
        set status = 'awaiting_volunteer_request', updated_at = now()
        where claim_id = p_claim_id returning * into v_coord;
    end if;
    return to_jsonb(v_coord);
end;
$$;

create or replace function public.request_claim_volunteer_delivery(
    p_claim_id uuid,
    p_actor_role text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_claim public.claims%rowtype;
    v_coord public.claim_transport_coordination%rowtype;
    v_donation public.donations%rowtype;
    v_ngo public.ngos%rowtype;
    v_delivery public.deliveries%rowtype;
    v_prior_claim public.claims%rowtype;
begin
    if p_actor_role not in ('provider', 'ngo') then
        raise exception 'provider or NGO access is required';
    end if;
    select * into v_claim from public.claims where id = p_claim_id;
    if not found then
        raise exception 'claim not found';
    end if;
    perform 1 from public.donations
    where id = v_claim.donation_id for update;
    select * into v_donation from public.donations
    where id = v_claim.donation_id;
    select * into v_claim from public.claims
    where id = p_claim_id for update;
    select * into v_coord from public.claim_transport_coordination
    where claim_id = p_claim_id for update;

    if not found or v_claim.status not in ('pending', 'accepted')
       or v_coord.provider_response is distinct from 'no'
       or v_coord.ngo_response is distinct from 'no' then
        raise exception 'both participants must decline delivery before requesting a volunteer';
    end if;
    if v_donation.status in ('expired', 'cancelled', 'completed', 'delivered')
       or v_donation.expiry_time is null
       or v_donation.expiry_time <= clock_timestamp()
       or v_donation.pickup_deadline is null
       or v_donation.pickup_deadline <= clock_timestamp() then
        raise exception 'donation or delivery has expired';
    end if;
    if v_coord.status = 'searching_for_volunteers'
       or v_coord.status = 'volunteer_assigned' then
        select * into v_delivery from public.deliveries
        where donation_id = v_coord.donation_id;
        if not found then
            raise exception 'volunteer request has no delivery task';
        end if;
        return jsonb_build_object(
            'coordination', to_jsonb(v_coord),
            'delivery', to_jsonb(v_delivery),
            'created', false
        );
    end if;
    if v_coord.status <> 'awaiting_volunteer_request' then
        raise exception 'volunteer request is not available';
    end if;

    select * into v_ngo from public.ngos where id = v_coord.ngo_id;
    if v_donation.pickup_address is null or v_ngo.address is null then
        raise exception 'pickup and drop-off addresses are required to request a volunteer';
    end if;

    select * into v_delivery from public.deliveries
    where donation_id = v_coord.donation_id for update;
    if found then
        if v_delivery.volunteer_id is not null
           or v_delivery.status <> 'unassigned' then
            raise exception 'existing delivery task is not available';
        end if;
        if v_delivery.claim_id <> p_claim_id then
            select * into v_prior_claim from public.claims
            where id = v_delivery.claim_id for update;
            if found and v_prior_claim.status not in ('cancelled', 'rejected') then
                raise exception 'existing delivery task belongs to another live claim';
            end if;
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
        where id = v_delivery.id returning * into v_delivery;
    else
        insert into public.deliveries (
            donation_id, claim_id, pickup_address, delivery_address,
            pickup_time, pickup_latitude, pickup_longitude,
            dropoff_latitude, dropoff_longitude, status, notes
        ) values (
            v_coord.donation_id, p_claim_id, v_donation.pickup_address,
            v_ngo.address, v_donation.pickup_deadline,
            v_donation.latitude, v_donation.longitude,
            v_ngo.latitude, v_ngo.longitude, 'unassigned',
            'Transport requested after both claim participants declined.'
        ) returning * into v_delivery;
    end if;

    update public.claim_transport_coordination
    set status = 'searching_for_volunteers', updated_at = now()
    where claim_id = p_claim_id returning * into v_coord;
    update public.donations set volunteer_transport_required = true
    where id = v_coord.donation_id;
    return jsonb_build_object(
        'coordination', to_jsonb(v_coord),
        'delivery', to_jsonb(v_delivery),
        'created', true
    );
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
    v_donation public.donations%rowtype;
    v_claim public.claims%rowtype;
begin
    select donation_id, claim_id into v_donation.id, v_claim.id
    from public.deliveries where id = p_delivery_id;
    if v_donation.id is null then
        raise exception 'delivery not found';
    end if;
    perform 1 from public.donations where id = v_donation.id for update;
    select * into v_donation from public.donations where id = v_donation.id;
    select * into v_claim from public.claims where id = v_claim.id for update;
    if not found or v_claim.status not in ('pending', 'accepted')
       or v_donation.status in ('expired', 'cancelled', 'completed', 'delivered')
       or v_donation.expiry_time is null
       or v_donation.expiry_time <= clock_timestamp()
       or v_donation.pickup_deadline is null
       or v_donation.pickup_deadline <= clock_timestamp() then
        raise exception 'donation, claim, or delivery has expired or is closed';
    end if;
    select * into v_coord from public.claim_transport_coordination
    where claim_id = v_claim.id for update;
    if not found or v_coord.status <> 'searching_for_volunteers' then
        raise exception 'volunteer search is not open for this delivery';
    end if;
    select * into v_delivery from public.deliveries
    where id = p_delivery_id for update;
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
    set responsible_role = 'volunteer', status = 'volunteer_assigned',
        updated_at = now()
    where claim_id = v_claim.id returning * into v_coord;
    update public.donations d
    set volunteer_transport_required = exists (
        select 1
        from public.claim_transport_coordination c
        join public.claims cl on cl.id = c.claim_id
        where c.donation_id = d.id
          and cl.status in ('pending', 'accepted')
          and c.status in ('searching_for_volunteers', 'volunteer_assigned')
    )
    where d.id = v_donation.id;
    return jsonb_build_object(
        'delivery', to_jsonb(v_delivery),
        'coordination', to_jsonb(v_coord)
    );
end;
$$;

revoke all on function public.respond_to_claim_transport(uuid, text, text, text, text)
    from public, anon, authenticated;
revoke all on function public.request_claim_volunteer_delivery(uuid, text)
    from public, anon, authenticated;
revoke all on function public.confirm_claim_volunteer_assignment(uuid, uuid)
    from public, anon, authenticated;
grant execute on function public.respond_to_claim_transport(uuid, text, text, text, text)
    to service_role;
grant execute on function public.request_claim_volunteer_delivery(uuid, text)
    to service_role;
grant execute on function public.confirm_claim_volunteer_assignment(uuid, uuid)
    to service_role;
