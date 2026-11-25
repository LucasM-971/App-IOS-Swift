/// <reference path="../_shared/deno-shim.d.ts" />

import { corsHeaders, handleCors } from "../_shared/cors.ts";
import {
  ensureParkingSchema,
  isParkingSchemaCacheMiss,
} from "../_shared/parkingSchema.ts";
import { checkRateLimit, getClientIp } from "../_shared/rateLimit.ts";
import { errorResponse, jsonResponse } from "../_shared/response.ts";
import {
  createServiceClient,
  createUserClient,
  requireUser,
} from "../_shared/supabase.ts";
import { clamp, isUuid, parseJson } from "../_shared/validation.ts";

type CreateParkingBody = {
  id?: string;
  latitude?: number;
  longitude?: number;
  address?: string | null;
  note?: string | null;
  parkingLevel?: string | null;
  parking_level?: string | null;
  zone?: string;
  startTime?: string;
  start_time?: string;
  endTime?: string | null;
  end_time?: string | null;
  maxDuration?: number | null;
  max_duration?: number | null;
};

type PurgeHistoryBody = {
  userId?: string;
  user_id?: string;
  before?: string;
};

const FREE_HISTORY_RETENTION_DAYS = 7;
const PREMIUM_HISTORY_RETENTION_DAYS = 90;

function mapRow(row: Record<string, unknown>) {
  return {
    id: row.id,
    userId: row.user_id,
    latitude: row.latitude,
    longitude: row.longitude,
    address: row.address,
    note: row.note,
    parkingLevel: row.parking_level,
    zone: row.zone,
    startTime: row.start_time,
    endTime: row.end_time,
    maxDuration: row.max_duration,
  };
}

function explainParkingDatabaseError(
  message: string | undefined,
  fallback: string,
): string {
  const normalized = (message ?? "").trim().toLowerCase();

  if (!normalized) {
    return fallback;
  }

  if (
    normalized.includes("relation") &&
    normalized.includes("parking_sessions") &&
    normalized.includes("does not exist")
  ) {
    return "Parking database table missing. Apply Backend/supabase/sql/schema.sql in Supabase, then retry.";
  }

  if (
    normalized.includes("permission denied") ||
    normalized.includes("row-level security") ||
    normalized.includes("violates row-level security")
  ) {
    return "Parking database permissions are not aligned with the current schema. Apply Backend/supabase/sql/schema.sql in Supabase, then retry.";
  }

  return message ?? fallback;
}

async function retryAfterParkingSchemaBootstrap<T>(
  operation: () => Promise<
    { data: T | null; error: { message?: string } | null }
  >,
): Promise<{ data: T | null; error: { message?: string } | null }> {
  let result = await operation();

  if (result.error && isParkingSchemaCacheMiss(result.error.message)) {
    try {
      await ensureParkingSchema();
      result = await operation();
    } catch (bootstrapError) {
      console.error(
        "[parking] Failed to bootstrap parking schema:",
        bootstrapError instanceof Error
          ? bootstrapError.message
          : String(bootstrapError),
      );
    }
  }

  return result;
}

function normalizeStatusToken(value: string): string {
  return value.trim().toLowerCase().replace(/[\s-]+/g, "_");
}

function isPremiumLikeStatus(status: unknown): boolean {
  if (typeof status !== "string") return false;
  const normalized = normalizeStatusToken(status);
  return normalized === "paid" ||
    normalized === "premium" ||
    normalized === "paid_monthly" ||
    normalized === "paid_lifetime";
}

function isFreeStatusId(value: unknown): boolean {
  if (typeof value === "number" && Number.isInteger(value)) {
    return value === 1;
  }

  if (typeof value === "string") {
    const parsed = Number(value.trim());
    return Number.isInteger(parsed) && parsed === 1;
  }

  return false;
}

function isPaidStatusId(value: unknown): boolean {
  if (typeof value === "number" && Number.isInteger(value)) {
    return value === 2 || value === 3;
  }

  if (typeof value === "string") {
    const parsed = Number(value.trim());
    return Number.isInteger(parsed) && (parsed === 2 || parsed === 3);
  }

  return false;
}

function coerceBoolean(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (value === 1) return true;
    if (value === 0) return false;
    return null;
  }

  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (
      ["1", "true", "yes", "y", "on", "paid", "premium"].includes(normalized)
    ) return true;
    if (["0", "false", "no", "n", "off", "free"].includes(normalized)) {
      return false;
    }
  }

  return null;
}

function pickString(value: Record<string, unknown>, ...keys: string[]): string {
  for (const key of keys) {
    const candidate = value[key];
    if (typeof candidate === "string" && candidate.trim().length > 0) {
      return candidate.trim();
    }
  }
  return "";
}

function pickNullableString(
  value: Record<string, unknown>,
  ...keys: string[]
): string | null {
  for (const key of keys) {
    const candidate = value[key];
    if (candidate === null) {
      return null;
    }
    if (typeof candidate === "string") {
      const trimmed = candidate.trim();
      return trimmed.length > 0 ? trimmed : null;
    }
  }
  return null;
}

function pickNumber(
  value: Record<string, unknown>,
  ...keys: string[]
): number | null {
  for (const key of keys) {
    const candidate = value[key];
    if (typeof candidate === "number" && Number.isFinite(candidate)) {
      return candidate;
    }
  }
  return null;
}

async function readUserProfileRecord(
  service: ReturnType<typeof createServiceClient>,
  userId: string,
): Promise<Record<string, unknown> | null> {
  const selectVariants = [
    "status,status_id,is_premium,ads_enabled,role_id",
    "status,status_id,is_premium",
    "status,status_id",
    "status,is_premium",
    "status",
    "is_premium",
  ];

  for (const select of selectVariants) {
    const { data, error } = await service
      .from("user_profiles")
      .select(select)
      .eq("id", userId)
      .maybeSingle();

    if (error) {
      const message = (error.message ?? "").toLowerCase();
      const isUnknownColumn = message.includes("column") &&
        message.includes("does not exist");
      if (isUnknownColumn) {
        continue;
      }
      console.warn(
        "[parking/history] Unable to read history retention status:",
        error.message ?? "unknown error",
      );
      return null;
    }

    if (data && typeof data === "object") {
      return data as Record<string, unknown>;
    }

    return null;
  }

  return null;
}

async function resolveUserHistoryRetentionDays(
  service: ReturnType<typeof createServiceClient>,
  userId: string,
): Promise<number> {
  const profile = await readUserProfileRecord(service, userId);
  if (!profile) {
    return FREE_HISTORY_RETENTION_DAYS;
  }

  if (isFreeStatusId(profile.status_id)) {
    return FREE_HISTORY_RETENTION_DAYS;
  }

  if (isPaidStatusId(profile.status_id)) {
    return PREMIUM_HISTORY_RETENTION_DAYS;
  }

  const explicitPremium = coerceBoolean(profile.is_premium);
  if (explicitPremium !== null) {
    return explicitPremium
      ? PREMIUM_HISTORY_RETENTION_DAYS
      : FREE_HISTORY_RETENTION_DAYS;
  }

  const adsEnabled = coerceBoolean(profile.ads_enabled);
  if (adsEnabled !== null) {
    return adsEnabled
      ? FREE_HISTORY_RETENTION_DAYS
      : PREMIUM_HISTORY_RETENTION_DAYS;
  }

  if (isPaidStatusId(profile.role_id)) {
    return PREMIUM_HISTORY_RETENTION_DAYS;
  }

  if (isFreeStatusId(profile.role_id)) {
    return FREE_HISTORY_RETENTION_DAYS;
  }

  return isPremiumLikeStatus(profile.status)
    ? PREMIUM_HISTORY_RETENTION_DAYS
    : FREE_HISTORY_RETENTION_DAYS;
}

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  const headers = corsHeaders(req.headers.get("Origin"));
  const url = new URL(req.url);
  const path = url.pathname.toLowerCase();

  try {
    const auth = await requireUser(req);
    if (!auth.user) return errorResponse("Unauthorized", 401, headers);

    const ip = getClientIp(req);
    const rate = checkRateLimit({
      scope: "parking",
      key: `${ip}:${auth.user.id}:${req.method}:${path}`,
      limit: 240,
      windowSeconds: 60,
    });
    if (!rate.allowed) {
      return errorResponse(
        `Trop de requêtes. Réessaie dans ${rate.retryAfterSeconds}s.`,
        429,
        headers,
      );
    }

    const service = createServiceClient();
    const database = createUserClient(auth.token);
    const userId = auth.user.id;

    if (
      req.method === "POST" && !path.includes("active") &&
      !path.includes("history")
    ) {
      const body = parseJson<CreateParkingBody>(await req.text());
      const normalizedBody = (body ?? {}) as Record<string, unknown>;
      const requestedId = typeof normalizedBody.id === "string" &&
          normalizedBody.id.trim().length > 0
        ? normalizedBody.id.trim()
        : null;
      const latitude = pickNumber(normalizedBody, "latitude");
      const longitude = pickNumber(normalizedBody, "longitude");
      if (
        latitude === null ||
        longitude === null
      ) {
        return errorResponse("Invalid coordinates.", 400, headers);
      }
      if (requestedId !== null && !isUuid(requestedId)) {
        return errorResponse("ID invalide.", 400, headers);
      }

      const startTimeRaw = pickString(
        normalizedBody,
        "startTime",
        "start_time",
      );
      const endTimeRaw = pickString(normalizedBody, "endTime", "end_time");
      const startTime = startTimeRaw ? new Date(startTimeRaw) : new Date();
      if (Number.isNaN(startTime.getTime())) {
        return errorResponse("startTime invalide.", 400, headers);
      }
      const endTime = endTimeRaw ? new Date(endTimeRaw) : null;
      if (endTime && Number.isNaN(endTime.getTime())) {
        return errorResponse("endTime invalide.", 400, headers);
      }
      if (endTime && endTime.getTime() < startTime.getTime()) {
        return errorResponse("endTime must be after startTime.", 400, headers);
      }

      const payload: Record<string, unknown> = {
        user_id: userId,
        latitude,
        longitude,
        address: pickNullableString(normalizedBody, "address"),
        note: pickNullableString(normalizedBody, "note"),
        parking_level: pickNullableString(
          normalizedBody,
          "parkingLevel",
          "parking_level",
        ),
        zone: pickString(normalizedBody, "zone") || "Inconnu",
        start_time: startTime.toISOString(),
        end_time: endTime ? endTime.toISOString() : null,
        max_duration: pickNumber(normalizedBody, "maxDuration", "max_duration"),
      };
      if (requestedId) {
        payload.id = requestedId;
      }

      const { data, error } = await retryAfterParkingSchemaBootstrap(() =>
        database
          .from("parking_sessions")
          .upsert(payload, { onConflict: "id" })
          .select("*")
          .single()
      );

      if (error || !data) {
        return errorResponse(
          explainParkingDatabaseError(
            error?.message,
            "Failed to create or update parking entry.",
          ),
          400,
          headers,
        );
      }
      return jsonResponse(mapRow(data), { status: 201, headers });
    }

    if (req.method === "GET" && path.includes("active")) {
      const { data, error } = await retryAfterParkingSchemaBootstrap(() =>
        database
          .from("parking_sessions")
          .select("*")
          .eq("user_id", userId)
          .is("end_time", null)
          .order("start_time", { ascending: false })
          .limit(1)
          .maybeSingle()
      );

      if (error) {
        return errorResponse(
          explainParkingDatabaseError(
            error.message,
            "Failed to read active parking entry.",
          ),
          500,
          headers,
        );
      }
      return jsonResponse(data ? mapRow(data) : null, { headers });
    }

    if (
      req.method === "POST" && path.includes("history") &&
      path.includes("purge")
    ) {
      const body = parseJson<PurgeHistoryBody>(await req.text());
      const normalizedBody = (body ?? {}) as Record<string, unknown>;
      const requestedUserId = pickString(normalizedBody, "userId", "user_id");
      if (requestedUserId && requestedUserId !== userId) {
        return errorResponse("Forbidden", 403, headers);
      }

      const before = typeof body?.before === "string"
        ? new Date(body.before)
        : null;
      if (!before || Number.isNaN(before.getTime())) {
        return errorResponse("Date de purge invalide.", 400, headers);
      }

      const { error } = await retryAfterParkingSchemaBootstrap(() =>
        database
          .from("parking_sessions")
          .delete()
          .eq("user_id", userId)
          .not("end_time", "is", null)
          .lt("start_time", before.toISOString())
      );

      if (error) {
        return errorResponse(
          explainParkingDatabaseError(
            error.message,
            "Failed to purge history.",
          ),
          500,
          headers,
        );
      }
      return jsonResponse({ ok: true }, { headers });
    }

    if (req.method === "GET" && path.includes("history")) {
      const limit = clamp(
        Number(url.searchParams.get("limit") ?? "20") || 20,
        1,
        100,
      );
      const offset = Math.max(
        0,
        Number(url.searchParams.get("offset") ?? "0") || 0,
      );
      const retentionDays = await resolveUserHistoryRetentionDays(
        service,
        userId,
      );
      const cutoff = new Date();
      cutoff.setUTCDate(cutoff.getUTCDate() - retentionDays);

      const { data, error } = await retryAfterParkingSchemaBootstrap(() =>
        database
          .from("parking_sessions")
          .select("*")
          .eq("user_id", userId)
          .gte("start_time", cutoff.toISOString())
          .order("start_time", { ascending: false })
          .range(offset, offset + limit - 1)
      );

      if (error) {
        return errorResponse(
          explainParkingDatabaseError(error.message, "Failed to read history."),
          500,
          headers,
        );
      }
      return jsonResponse((data ?? []).map(mapRow), { headers });
    }

    if (req.method === "PATCH" && path.includes("end")) {
      const id = path.split("/end")[0].split("/").pop();
      if (!id || !isUuid(id)) {
        return errorResponse("ID invalide.", 400, headers);
      }

      const { data, error } = await retryAfterParkingSchemaBootstrap(() =>
        database
          .from("parking_sessions")
          .update({ end_time: new Date().toISOString() })
          .eq("id", id)
          .eq("user_id", userId)
          .select("*")
          .single()
      );

      if (error || !data) {
        return errorResponse(
          explainParkingDatabaseError(
            error?.message,
            "Unable to end the parking session.",
          ),
          404,
          headers,
        );
      }
      return jsonResponse(mapRow(data), { headers });
    }

    if (
      req.method === "DELETE" && !path.includes("active") &&
      !path.includes("history") && !path.includes("end")
    ) {
      const id = path.split("/").pop();
      if (!id || !isUuid(id)) {
        return errorResponse("ID invalide.", 400, headers);
      }

      const { error } = await retryAfterParkingSchemaBootstrap(() =>
        database
          .from("parking_sessions")
          .delete()
          .eq("id", id)
          .eq("user_id", userId)
      );

      if (error) {
        return errorResponse(
          explainParkingDatabaseError(
            error.message,
            "Unable to delete the parking session.",
          ),
          404,
          headers,
        );
      }
      return jsonResponse({ ok: true }, { headers });
    }

    return errorResponse("Route not found.", 404, headers);
  } catch (e) {
    return errorResponse(
      `Erreur serveur: ${e instanceof Error ? e.message : "unknown"}`,
      500,
      headers,
    );
  }
});
