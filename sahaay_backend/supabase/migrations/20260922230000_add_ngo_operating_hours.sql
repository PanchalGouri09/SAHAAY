-- Add NGO operating-hours support used by AI NGO matching.
-- Idempotent so it can be re-applied against any state of the schema.
--
-- Values are stored as 24-hour "HH:MM" strings, exactly matching the AI
-- service's NGOInput.available_from / available_to contract
-- (descriptions: "HH:MM, 24-hour format"). Both columns are nullable:
-- an NGO without operating hours is excluded from time-based matching
-- rather than being assigned invented hours.

alter table public.ngos
    add column if not exists available_from text,
    add column if not exists available_to text;

do $$
begin
    -- HH:MM (00:00-23:59) when present. Malformed or partial values are
    -- rejected at write time so matching never receives unusable hours.
    if not exists (
        select 1 from pg_constraint where conname = 'ngos_available_from_hhmm_check'
    ) then
        alter table public.ngos
            add constraint ngos_available_from_hhmm_check
            check (
                available_from is null
                or available_from ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
            );
    end if;

    if not exists (
        select 1 from pg_constraint where conname = 'ngos_available_to_hhmm_check'
    ) then
        alter table public.ngos
            add constraint ngos_available_to_hhmm_check
            check (
                available_to is null
                or available_to ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
            );
    end if;

    -- Hours come as a pair: a start without an end (or vice versa) is not a
    -- usable availability window and would break the AI feasibility check.
    if not exists (
        select 1 from pg_constraint where conname = 'ngos_available_hours_pair_check'
    ) then
        alter table public.ngos
            add constraint ngos_available_hours_pair_check
            check (
                (available_from is null and available_to is null)
                or (available_from is not null and available_to is not null)
            );
    end if;
end $$;