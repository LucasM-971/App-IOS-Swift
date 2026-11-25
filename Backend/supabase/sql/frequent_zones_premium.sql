begin;

create table if not exists public.frequent_zones (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null default 'Zone fréquente'
    check (char_length(trim(name)) between 1 and 80),
  details text,
  landmark_level text,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  visits integer not null default 1 check (visits >= 1),
  last_visited_at timestamptz not null default now(),
  preferred_duration_minutes integer
    check (preferred_duration_minutes is null or preferred_duration_minutes between 5 and 720),
  parking_type text not null default 'Inconnu'
    check (parking_type in ('Gratuit', 'Payant', 'Resident', 'Souterrain', 'Inconnu')),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.frequent_zones
  add column if not exists deleted_at timestamptz;

create index if not exists idx_frequent_zones_user_last_visited
  on public.frequent_zones (user_id, last_visited_at desc);

create index if not exists idx_frequent_zones_user_visits
  on public.frequent_zones (user_id, visits desc);

create index if not exists idx_frequent_zones_user_updated_at
  on public.frequent_zones (user_id, updated_at desc);

create index if not exists idx_frequent_zones_user_deleted
  on public.frequent_zones (user_id, deleted_at);

drop trigger if exists trg_frequent_zones_updated_at on public.frequent_zones;
create trigger trg_frequent_zones_updated_at
before update on public.frequent_zones
for each row
execute function public.set_updated_at();

create or replace function public.user_has_frequent_zones_access(target_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.user_profiles up
    where up.id = target_user_id
      and lower(up.status) in ('premium', 'paid_monthly', 'paid_lifetime')
  );
$$;

revoke all on function public.user_has_frequent_zones_access(uuid) from public;
grant execute on function public.user_has_frequent_zones_access(uuid) to authenticated;

alter table public.frequent_zones enable row level security;
alter table public.frequent_zones force row level security;

drop policy if exists frequent_zones_select_own_premium on public.frequent_zones;
create policy frequent_zones_select_own_premium
on public.frequent_zones
for select
to authenticated
using (
  auth.uid() = user_id
  and public.user_has_frequent_zones_access(auth.uid())
);

drop policy if exists frequent_zones_insert_own_premium on public.frequent_zones;
create policy frequent_zones_insert_own_premium
on public.frequent_zones
for insert
to authenticated
with check (
  auth.uid() = user_id
  and public.user_has_frequent_zones_access(auth.uid())
);

drop policy if exists frequent_zones_update_own_premium on public.frequent_zones;
create policy frequent_zones_update_own_premium
on public.frequent_zones
for update
to authenticated
using (
  auth.uid() = user_id
  and public.user_has_frequent_zones_access(auth.uid())
)
with check (
  auth.uid() = user_id
  and public.user_has_frequent_zones_access(auth.uid())
);

drop policy if exists frequent_zones_delete_own_premium on public.frequent_zones;
create policy frequent_zones_delete_own_premium
on public.frequent_zones
for delete
to authenticated
using (
  auth.uid() = user_id
  and public.user_has_frequent_zones_access(auth.uid())
);

revoke all on table public.frequent_zones from anon, authenticated;
grant select, insert, update, delete on table public.frequent_zones to authenticated;

commit;
