-- vehicle_feature.sql
-- Schéma Supabase pour la fonctionnalité "Mon véhicule"

-- Table vehicles
create table if not exists vehicles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users not null,
  brand text not null,
  model text not null,
  year int not null,
  fuel_type text not null,
  license_plate text,
  vin text,
  current_km int default 0,
  annual_km int default 15000,
  fuel_consumption float,
  fuel_price float,
  notes text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Table maintenance_items
create table if not exists maintenance_items (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid references vehicles(id) on delete cascade not null,
  name text not null,
  last_done_km int,
  last_done_date timestamptz,
  interval_km int,
  interval_months int,
  urgency_level text default 'ok'
);

-- Table ai_diagnostics
create table if not exists ai_diagnostics (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid references vehicles(id) on delete cascade not null,
  date timestamptz default now(),
  symptoms text[],
  obd_code text,
  health_score int,
  urgency_level text,
  can_drive bool,
  causes text[],
  immediate_actions text[],
  week_actions text[],
  cost_min int,
  cost_max int,
  raw_response text
);

-- RLS
alter table vehicles enable row level security;
alter table maintenance_items enable row level security;
alter table ai_diagnostics enable row level security;

-- Policies vehicles
create policy if not exists "user owns vehicle"
  on vehicles for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Policies maintenance
create policy if not exists "user owns maintenance via vehicle"
  on maintenance_items for all
  using (
    exists (
      select 1 from vehicles v
      where v.id = maintenance_items.vehicle_id
      and v.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from vehicles v
      where v.id = maintenance_items.vehicle_id
      and v.user_id = auth.uid()
    )
  );

-- Policies diagnostics
create policy if not exists "user owns diagnostics via vehicle"
  on ai_diagnostics for all
  using (
    exists (
      select 1 from vehicles v
      where v.id = ai_diagnostics.vehicle_id
      and v.user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from vehicles v
      where v.id = ai_diagnostics.vehicle_id
      and v.user_id = auth.uid()
    )
  );
