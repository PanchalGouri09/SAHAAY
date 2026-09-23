-- Add AI-surplus input columns plus the food-photo reference to donations.
-- Idempotent so it can be re-applied against any state of the schema.

alter table public.donations
    add column if not exists food_prepared_kg numeric,
    add column if not exists food_sold_kg numeric,
    add column if not exists food_image_url text;

do $$
begin
    if not exists (
        select 1 from pg_constraint where conname = 'donations_food_prepared_kg_check'
    ) then
        alter table public.donations
            add constraint donations_food_prepared_kg_check
            check (food_prepared_kg is null or food_prepared_kg > 0);
    end if;

    if not exists (
        select 1 from pg_constraint where conname = 'donations_food_sold_kg_check'
    ) then
        alter table public.donations
            add constraint donations_food_sold_kg_check
            check (food_sold_kg is null or food_sold_kg >= 0);
    end if;

    if not exists (
        select 1 from pg_constraint where conname = 'donations_food_sold_le_prepared_check'
    ) then
        alter table public.donations
            add constraint donations_food_sold_le_prepared_check
            check (
                food_prepared_kg is null
                or food_sold_kg is null
                or food_sold_kg <= food_prepared_kg
            );
    end if;
end $$;