-- The device-token registration route uses ON CONFLICT (token). The original
-- table migration used CREATE TABLE IF NOT EXISTS, which does not add the
-- declared UNIQUE constraint when the table already exists.
--
-- Lock out token writes between the duplicate check and index creation. No rows
-- are modified or deleted here; if duplicate tokens exist, stop and resolve
-- them explicitly.
do $$
declare
    duplicate_token_values bigint;
    has_token_conflict_index boolean;
begin
    if to_regclass('public.user_device_tokens') is null then
        raise exception
            'public.user_device_tokens is missing; apply its table migration first.';
    end if;

    lock table public.user_device_tokens in share mode;

    select exists (
        select 1
        from pg_index i
        where i.indrelid = 'public.user_device_tokens'::regclass
          and i.indisunique
          and not i.indisexclusion
          and i.indisvalid
          and i.indisready
          and i.indimmediate
          and i.indpred is null
          and i.indnkeyatts = 1
          and pg_get_indexdef(i.indexrelid, 1, true) = 'token'
    )
    into has_token_conflict_index;

    if not has_token_conflict_index then
        select count(*)
        into duplicate_token_values
        from (
            select token
            from public.user_device_tokens
            where token is not null
            group by token
            having count(*) > 1
        ) duplicate_tokens;

        if duplicate_token_values > 0 then
            raise exception
                'Cannot add the user_device_tokens(token) unique index: % duplicate token values exist. Review and resolve those records without deleting user data, then rerun this migration.',
                duplicate_token_values
                using errcode = '23505';
        end if;

        create unique index user_device_tokens_token_conflict_idx
            on public.user_device_tokens (token);
    end if;
end
$$;
