-- Demo eligibility is deliberately distinct from production NGO verification.
-- No registry or legal-status claim is made by this flag.
alter table public.ngos
    add column if not exists demo_verified boolean not null default false,
    add column if not exists demo_verified_at timestamptz;

create or replace function public.protect_ngo_demo_verification()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if coalesce(auth.role(), '') <> 'service_role' then
        if tg_op = 'INSERT' then
            if coalesce(new.verified, false)
               or new.demo_verified
               or new.demo_verified_at is not null then
                raise exception using
                    errcode = '42501',
                    message = 'ngo_verification_server_only';
            end if;
        elsif new.verified is distinct from old.verified
           or new.demo_verified is distinct from old.demo_verified
           or new.demo_verified_at is distinct from old.demo_verified_at then
            raise exception using
                errcode = '42501',
                message = 'ngo_verification_server_only';
        end if;
    end if;
    return new;
end;
$$;

drop trigger if exists protect_ngo_demo_verification on public.ngos;
create trigger protect_ngo_demo_verification
    before insert or update of verified, demo_verified, demo_verified_at
    on public.ngos
    for each row execute function public.protect_ngo_demo_verification();

revoke all on function public.protect_ngo_demo_verification()
    from public, anon, authenticated;
