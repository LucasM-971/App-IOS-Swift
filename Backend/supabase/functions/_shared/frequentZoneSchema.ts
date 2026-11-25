/// <reference path="./deno-shim.d.ts" />

import postgres from "npm:postgres@3.4.4";

const allowedTableNames = new Set(["frequent_zone", "frequent_zones"]);
let bootstrapInFlight: Promise<void> | null = null;

function databaseUrl(): string {
  const value = Deno.env.get("SUPABASE_DB_URL");
  if (!value) {
    throw new Error("Missing SUPABASE_DB_URL env var");
  }
  return value;
}

export function isFrequentZoneSchemaMismatch(message?: string | null): boolean {
  const normalized = (message ?? "").trim().toLowerCase();
  if (!normalized) {
    return false;
  }

  const mentionsFrequentZones = normalized.includes("frequent_zone")
    || normalized.includes("frequent_zones");

  if (!mentionsFrequentZones) {
    return false;
  }

  return normalized.includes("schema cache")
    || normalized.includes("does not exist")
    || normalized.includes("column");
}

export async function ensureFrequentZoneSchema(preferredTableName?: string): Promise<void> {
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
      const requestedTable = allowedTableNames.has(preferredTableName ?? "")
        ? preferredTableName!
        : "frequent_zones";

      const existingPlural = await sql<{ exists: string | null }[]>`
        select to_regclass('public.frequent_zones')::text as exists
      `;
      const existingSingular = await sql<{ exists: string | null }[]>`
        select to_regclass('public.frequent_zone')::text as exists
      `;

      const targetTable = existingPlural[0]?.exists
        ? "frequent_zones"
        : existingSingular[0]?.exists
          ? "frequent_zone"
          : requestedTable;

      if (!allowedTableNames.has(targetTable)) {
        throw new Error(`Unsupported frequent zone table: ${targetTable}`);
      }

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
        create table if not exists public.${targetTable} (
          id uuid primary key default gen_random_uuid(),
          user_id uuid not null references auth.users(id) on delete cascade,
          name text not null default 'Zone fréquente',
          details text,
          landmark_level text,
          latitude double precision not null,
          longitude double precision not null,
          visits integer not null default 1,
          last_visited_at timestamptz not null default now(),
          preferred_duration_minutes integer,
          parking_type text not null default 'Inconnu',
          deleted_at timestamptz,
          created_at timestamptz not null default now(),
          updated_at timestamptz not null default now()
        );
      `);

      await sql.unsafe(`
        alter table public.${targetTable}
          add column if not exists details text,
          add column if not exists landmark_level text,
          add column if not exists preferred_duration_minutes integer,
          add column if not exists parking_type text not null default 'Inconnu',
          add column if not exists deleted_at timestamptz,
          add column if not exists created_at timestamptz not null default now(),
          add column if not exists updated_at timestamptz not null default now();
      `);

      await sql.unsafe(`
        create index if not exists idx_${targetTable}_user_last_visited
          on public.${targetTable} (user_id, last_visited_at desc);
      `);
      await sql.unsafe(`
        create index if not exists idx_${targetTable}_user_visits
          on public.${targetTable} (user_id, visits desc);
      `);
      await sql.unsafe(`
        create index if not exists idx_${targetTable}_user_deleted
          on public.${targetTable} (user_id, deleted_at);
      `);

      await sql.unsafe(`
        drop trigger if exists trg_${targetTable}_updated_at on public.${targetTable};
      `);
      await sql.unsafe(`
        create trigger trg_${targetTable}_updated_at
        before update on public.${targetTable}
        for each row
        execute function public.set_updated_at();
      `);

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
