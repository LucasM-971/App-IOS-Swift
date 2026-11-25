-- Location history retention for the current Supabase schema
-- Free users: 7 days
-- Premium users: 90 days
-- Source tables detected in schema:
-- - public.location_history
-- - public.user_status
-- - public.status_roles
-- - public.user_profiles

begin;

create extension if not exists pg_cron;

create index if not exists idx_location_history_user_created
  on public.location_history (user_id, created_at desc);

create index if not exists idx_location_history_user_deleted
  on public.location_history (user_id, deleted_at)
  where deleted_at is not null;

create or replace function public.location_history_retention_days(target_user_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  status_is_premium boolean;
  status_role_id smallint;
  status_value text;
  role_code text;
  role_ads_enabled boolean;
  profile_status text;
  profile_status_id smallint;
begin
  select
    us.is_premium,
    us.role_id,
    us.status::text
  into
    status_is_premium,
    status_role_id,
    status_value
  from public.user_status us
  where us.user_id = target_user_id
  order by coalesce(us.updated_at, us.created_at, us.started_at) desc nulls last
  limit 1;

  if status_role_id is not null then
    select
      sr.code,
      sr.ads_enabled
    into
      role_code,
      role_ads_enabled
    from public.status_roles sr
    where sr.id = status_role_id
    limit 1;
  end if;

  select
    up.status,
    up.status_id
  into
    profile_status,
    profile_status_id
  from public.user_profiles up
  where up.id = target_user_id
  limit 1;

  if coalesce(status_is_premium, false) then
    return 90;
  end if;

  if status_role_id in (2, 3) then
    return 90;
  end if;

  if status_role_id = 1 then
    return 7;
  end if;

  if lower(coalesce(role_code, '')) in ('premium', 'paid', 'paid_monthly', 'paid_lifetime') then
    return 90;
  end if;

  if lower(coalesce(role_code, '')) = 'free' then
    return 7;
  end if;

  if role_ads_enabled is false then
    return 90;
  end if;

  if role_ads_enabled is true then
    return 7;
  end if;

  if lower(coalesce(status_value, '')) in ('premium', 'paid', 'paid_monthly', 'paid_lifetime') then
    return 90;
  end if;

  if lower(coalesce(status_value, '')) = 'free' then
    return 7;
  end if;

  if profile_status_id in (2, 3) then
    return 90;
  end if;

  if profile_status_id = 1 then
    return 7;
  end if;

  if lower(coalesce(profile_status, '')) in ('premium', 'paid', 'paid_monthly', 'paid_lifetime') then
    return 90;
  end if;

  if lower(coalesce(profile_status, '')) = 'free' then
    return 7;
  end if;

  return 7;
end;
$$;

grant execute on function public.location_history_retention_days(uuid) to authenticated, service_role;

create or replace function public.purge_expired_location_history(target_user_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  deleted_count integer;
begin
  with deleted_rows as (
    delete from public.location_history lh
    where (target_user_id is null or lh.user_id = target_user_id)
      and lh.created_at < now() - make_interval(days => public.location_history_retention_days(lh.user_id))
    returning 1
  )
  select count(*)
  into deleted_count
  from deleted_rows;

  return coalesce(deleted_count, 0);
end;
$$;

grant execute on function public.purge_expired_location_history(uuid) to service_role;

create or replace function public.enforce_location_history_retention()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.purge_expired_location_history(new.user_id);
  return new;
end;
$$;

drop trigger if exists trg_location_history_enforce_retention on public.location_history;
create trigger trg_location_history_enforce_retention
after insert or update of user_id, created_at on public.location_history
for each row
execute function public.enforce_location_history_retention();

create or replace function public.enforce_location_history_retention_from_user_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.purge_expired_location_history(new.user_id);
  return new;
end;
$$;

drop trigger if exists trg_user_status_enforce_location_history_retention on public.user_status;
create trigger trg_user_status_enforce_location_history_retention
after insert or update of status, role_id, is_premium, updated_at on public.user_status
for each row
execute function public.enforce_location_history_retention_from_user_status();

create or replace function public.enforce_location_history_retention_from_profile()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.purge_expired_location_history(new.id);
  return new;
end;
$$;

drop trigger if exists trg_user_profiles_enforce_location_history_retention on public.user_profiles;
create trigger trg_user_profiles_enforce_location_history_retention
after insert or update of status, status_id on public.user_profiles
for each row
execute function public.enforce_location_history_retention_from_profile();

do $$
begin
  if exists (
    select 1
    from pg_tables
    where schemaname = 'cron'
      and tablename = 'job'
  ) then
    if not exists (
      select 1
      from cron.job
      where jobname = 'purge_location_history_daily'
    ) then
      perform cron.schedule(
        'purge_location_history_daily',
        '17 3 * * *',
        $job$select public.purge_expired_location_history();$job$
      );
    end if;
  end if;
end $$;

commit;
