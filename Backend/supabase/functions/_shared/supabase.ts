/// <reference path="./deno-shim.d.ts" />
/// <reference path="./supabase-js-shim.d.ts" />

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.49.1";

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing ${name} env var`);
  }
  return value;
}

const supabaseUrl = requireEnv("SUPABASE_URL");
const anonKey = requireEnv("SUPABASE_ANON_KEY");
const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");

export function createAnonClient(): SupabaseClient {
  return createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function createServiceClient(): SupabaseClient {
  return createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function createUserClient(jwt: string): SupabaseClient {
  return createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
}

type RequireUserResult = {
  user: { id: string; email?: string | null; [key: string]: unknown } | null;
  token: string;
};

export async function requireUser(req: Request): Promise<RequireUserResult> {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) return { user: null, token: "" };

  const anon = createAnonClient();
  const { data, error } = await anon.auth.getUser(token);
  if (error || !data.user) return { user: null, token: "" };

  return {
    user: {
      id: data.user.id,
      email: data.user.email,
      ...data.user,
    },
    token,
  };
}
