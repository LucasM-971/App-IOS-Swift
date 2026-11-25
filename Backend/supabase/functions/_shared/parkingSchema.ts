/// <reference path="./deno-shim.d.ts" />

import postgres from "npm:postgres@3.4.4";

let bootstrapInFlight: Promise<void> | null = null;

function databaseUrl(): string {
  const value = Deno.env.get("SUPABASE_DB_URL");
  if (!value) {
    throw new Error("Missing SUPABASE_DB_URL env var");
  }
  return value;
}

export function isParkingSchemaCacheMiss(message?: string | null): boolean {
  const normalized = (message ?? "").trim().toLowerCase();
  if (!normalized.includes("parking_sessions")) {
    return false;
  }

  return normalized.includes("schema cache")
    || (normalized.includes("relation") && normalized.includes("does not exist"));
}

export async function ensureParkingSchema(): Promise<void> {
  if (bootstrapInFlight) {
    return bootstrapInFlight;
  }

  bootstrapInFlight = (async () => {
    const sql = postgres(databaseUrl(), {
      connect_timeout: 10,
      idle_timeout: 5,
      max: 1,
      prepare: false,
    });

    try {
      await sql`create extension if not exists pgcrypto`;

      await sql.unsafe(`
        create or replace function public.set_updated_at()
        returns trigger
        language plpgsql
        as $$
        begin
          new.updated_at = now();
          return new;
        end;
        $$;
      `);

      await sql.unsafe(`
        create table if not exists public.parking_sessions (
          id uuid primary key default gen_random_uuid(),
          user_id uuid not null references auth.users(id) on delete cascade,
          latitude double precision not null check (latitude between -90 and 90),
          longitude double precision not null check (longitude between -180 and 180),
          address text,
          note text,
          parking_level text,
          zone text not null default 'Inconnu',
          start_time timestamptz not null default now(),
          end_time timestamptz,
          max_duration double precision,
          created_at timestamptz not null default now(),
          updated_at timestamptz not null default now(),
          constraint parking_sessions_end_after_start check (end_time is null or end_time >= start_time),
          constraint parking_sessions_duration_positive check (
            max_duration is null or (max_duration > 0 and max_duration <= 172800)
          )
        );
      `);

      await sql.unsafe(`
        create index if not exists idx_parking_sessions_user_start
          on public.parking_sessions (user_id, start_time desc);
      `);
      await sql.unsafe(`
        create index if not exists idx_parking_sessions_user_end
          on public.parking_sessions (user_id, end_time);
      `);
      await sql.unsafe(`
        create index if not exists idx_parking_sessions_user_active
          on public.parking_sessions (user_id)
          where end_time is null;
      `);

      await sql.unsafe(`
        drop trigger if exists trg_parking_sessions_updated_at on public.parking_sessions;
      `);
      await sql.unsafe(`
        create trigger trg_parking_sessions_updated_at
        before update on public.parking_sessions
        for each row
        execute function public.set_updated_at();
      `);

      await sql.unsafe(`alter table public.parking_sessions enable row level security;`);
      await sql.unsafe(`alter table public.parking_sessions force row level security;`);

      await sql.unsafe(`drop policy if exists parking_sessions_select_own on public.parking_sessions;`);
      await sql.unsafe(`
        create policy parking_sessions_select_own
        on public.parking_sessions
        for select
        to authenticated
        using (auth.uid() = user_id);
      `);

      await sql.unsafe(`drop policy if exists parking_sessions_insert_own on public.parking_sessions;`);
      await sql.unsafe(`
        create policy parking_sessions_insert_own
        on public.parking_sessions
        for insert
        to authenticated
        with check (auth.uid() = user_id);
      `);

      await sql.unsafe(`drop policy if exists parking_sessions_update_own on public.parking_sessions;`);
      await sql.unsafe(`
        create policy parking_sessions_update_own
        on public.parking_sessions
        for update
        to authenticated
        using (auth.uid() = user_id)
        with check (auth.uid() = user_id);
      `);

      await sql.unsafe(`drop policy if exists parking_sessions_delete_own on public.parking_sessions;`);
      await sql.unsafe(`
        create policy parking_sessions_delete_own
        on public.parking_sessions
        for delete
        to authenticated
        using (auth.uid() = user_id);
      `);

      await sql.unsafe(`revoke all on table public.parking_sessions from anon, authenticated;`);
      await sql.unsafe(`grant select, insert, update, delete on table public.parking_sessions to authenticated;`);

      await sql`select pg_notify('pgrst', 'reload schema')`;
    } finally {
      await sql.end({ timeout: 5 });
    }
  })();

  try {
    await bootstrapInFlight;
  } finally {
    bootstrapInFlight = null;
  }
}
