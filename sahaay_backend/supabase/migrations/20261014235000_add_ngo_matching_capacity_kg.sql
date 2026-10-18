-- Store actual per-donation weight capacity separately from people served/day.
-- Existing values are intentionally not copied or converted: their units are
-- different and cannot be safely inferred.
alter table public.ngos
    add column if not exists max_capacity_kg numeric,
    add column if not exists dietary_preferences text[];

do $migration$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.ngos'::regclass
          and conname = 'ngos_max_capacity_kg_positive'
    ) then
        alter table public.ngos
            add constraint ngos_max_capacity_kg_positive
            check (max_capacity_kg is null or max_capacity_kg > 0);
    end if;
end;
$migration$;

comment on column public.ngos.max_capacity_kg is
    'Maximum food weight this NGO can accept in one donation, in kilograms.';

comment on column public.ngos.dietary_preferences is
    'Dietary restrictions accepted by this NGO; separate from food-category preferences.';
