-- Hotfix signup: resilient trigger for heterogeneous schemas
-- Objective: prevent "database error saving new user" during auth sign-up.
-- Run in Supabase SQL Editor on the target project.

begin;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  meta_name text;
  email_local_part text;
  safe_display_name text;
  has_status boolean;
  has_status_id boolean;
  fk_schema text;
  fk_table text;
  fk_column text;
begin
  meta_name := nullif(trim(coalesce(new.raw_user_meta_data->>'display_name', '')), '');
  email_local_part := nullif(trim(split_part(coalesce(new.email, ''), '@', 1)), '');
  safe_display_name := left(coalesce(meta_name, email_local_part, 'Utilisateur'), 80);

  if char_length(safe_display_name) < 2 then
    safe_display_name := 'Utilisateur';
  end if;

  if new.email is null or trim(new.email) = '' then
    -- Do not block auth user creation.
    return new;
  end if;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'user_profiles'
      and column_name = 'status'
  )
  into has_status;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'user_profiles'
      and column_name = 'status_id'
  )
  into has_status_id;

  if has_status_id then
    select ccu.table_schema, ccu.table_name, ccu.column_name
    into fk_schema, fk_table, fk_column
    from information_schema.table_constraints tc
    join information_schema.key_column_usage kcu
      on tc.constraint_name = kcu.constraint_name
     and tc.table_schema = kcu.table_schema
    join information_schema.constraint_column_usage ccu
      on ccu.constraint_name = tc.constraint_name
     and ccu.table_schema = tc.table_schema
    where tc.constraint_type = 'FOREIGN KEY'
      and kcu.table_schema = 'public'
      and kcu.table_name = 'user_profiles'
      and kcu.column_name = 'status_id'
    limit 1;
  end if;

  -- Attempt 1: insert with status_id (works for UUID or numeric FK, no type assumption).
  if has_status_id and fk_table is not null and fk_column is not null then
    begin
      if has_status then
        execute format(
          'insert into public.user_profiles (id, display_name, email, status, status_id)
           values ($1, $2, $3, ''free'', (select %1$I from %2$I.%3$I limit 1))
           on conflict (id) do update
             set email = excluded.email',
          fk_column, fk_schema, fk_table
        )
        using new.id, safe_display_name, new.email;
      else
        execute format(
          'insert into public.user_profiles (id, display_name, email, status_id)
           values ($1, $2, $3, (select %1$I from %2$I.%3$I limit 1))
           on conflict (id) do update
             set email = excluded.email',
          fk_column, fk_schema, fk_table
        )
        using new.id, safe_display_name, new.email;
      end if;
      return new;
    exception
      when others then
        -- Fall through to safer attempts.
        null;
    end;
  end if;

  -- Attempt 2: insert with status only.
  if has_status then
    begin
      insert into public.user_profiles (id, display_name, email, status)
      values (new.id, safe_display_name, new.email, 'free')
      on conflict (id) do update
        set email = excluded.email;
      return new;
    exception
      when others then
        null;
    end;
  end if;

  -- Attempt 3: minimal insert.
  begin
    insert into public.user_profiles (id, display_name, email)
    values (new.id, safe_display_name, new.email)
    on conflict (id) do update
      set email = excluded.email;
  exception
    when others then
      -- Critical: never block auth sign-up.
      raise warning 'handle_new_user fallback failed for auth user %: %', new.id, sqlerrm;
  end;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

commit;
