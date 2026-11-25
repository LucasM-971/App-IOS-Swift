/// <reference path="../_shared/deno-shim.d.ts" />

import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { ensureFrequentZoneSchema, isFrequentZoneSchemaMismatch } from "../_shared/frequentZoneSchema.ts";
import { checkRateLimit, getClientIp } from "../_shared/rateLimit.ts";
import { errorResponse, jsonResponse } from "../_shared/response.ts";
import { createServiceClient, requireUser } from "../_shared/supabase.ts";
import { clamp, isUuid, parseJson } from "../_shared/validation.ts";

type FrequentZonePayload = {
  id?: string;
  userId?: string;
  user_id?: string;
  name?: string;
  details?: string | null;
  landmarkLevel?: string | null;
  landmark_level?: string | null;
  latitude?: number;
  longitude?: number;
  visits?: number;
  lastVisitedAt?: string;
  last_visited_at?: string;
  deletedAt?: string | null;
  deleted_at?: string | null;
  preferredDurationMinutes?: number | null;
  preferred_duration_minutes?: number | null;
  parkingType?: string;
  parking_type?: string;
};

type SyncFrequentZonesBody = {
  userId?: string;
  user_id?: string;
  zones?: FrequentZonePayload[];
};

const frequentZoneTableCandidates = ["frequent_zone", "frequent_zones"];
const allowedParkingTypes = new Set(["Gratuit", "Payant", "Resident", "Souterrain", "Inconnu"]);

function isMissingRelationError(message: string | undefined): boolean {
  const normalized = (message ?? "").toLowerCase();
  return normalized.includes("relation") && normalized.includes("does not exist");
}

function normalizeStatusToken(value: unknown): string {
  return typeof value === "string"
    ? value.trim().toLowerCase().replace(/[\s-]+/g, "_")
    : "";
}

function isPaidStatusId(value: unknown): boolean {
  if (typeof value === "number" && Number.isInteger(value)) return value === 2 || value === 3;
  if (typeof value === "string") {
    const parsed = Number(value.trim());
    return Number.isInteger(parsed) && (parsed === 2 || parsed === 3);
  }
  return false;
}

function isPremiumLikeStatus(value: unknown): boolean {
  const normalized = normalizeStatusToken(value);
  return normalized === "paid"
    || normalized === "premium"
    || normalized === "paid_monthly"
    || normalized === "paid_lifetime";
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

function pickNullableString(value: Record<string, unknown>, maxLength: number, ...keys: string[]): string | null {
  for (const key of keys) {
    const candidate = value[key];
    if (candidate === null) return null;
    if (typeof candidate === "string") {
      const trimmed = candidate.trim();
      return trimmed.length > 0 ? trimmed.slice(0, maxLength) : null;
    }
  }
  return null;
}

function pickNumber(value: Record<string, unknown>, ...keys: string[]): number | null {
  for (const key of keys) {
    const candidate = value[key];
    if (typeof candidate === "number" && Number.isFinite(candidate)) return candidate;
  }
  return null;
}

function pickInteger(value: Record<string, unknown>, ...keys: string[]): number | null {
  const valueNumber = pickNumber(value, ...keys);
  return valueNumber !== null && Number.isInteger(valueNumber) ? valueNumber : null;
}

function mapZoneRow(row: Record<string, unknown>) {
  return {
    id: row.id,
    userId: row.user_id,
    name: row.name,
    details: row.details,
    landmarkLevel: row.landmark_level,
    latitude: row.latitude,
    longitude: row.longitude,
    visits: row.visits,
    lastVisitedAt: row.last_visited_at,
    deletedAt: row.deleted_at,
    preferredDurationMinutes: row.preferred_duration_minutes,
    parkingType: row.parking_type,
  };
}

async function resolveFrequentZoneTable(
  service: ReturnType<typeof createServiceClient>,
): Promise<string> {
  for (const tableName of frequentZoneTableCandidates) {
    const { error } = await service.from(tableName).select("id").limit(1);
    if (!error || !isMissingRelationError(error.message)) {
      return tableName;
    }
  }
  return frequentZoneTableCandidates[0];
}

async function retryAfterFrequentZoneSchemaBootstrap<T>(
  tableName: string,
  operation: () => Promise<{ data: T | null; error: { message?: string } | null }>,
): Promise<{ data: T | null; error: { message?: string } | null }> {
  let result = await operation();

  if (result.error && isFrequentZoneSchemaMismatch(result.error.message)) {
    try {
      await ensureFrequentZoneSchema(tableName);
      result = await operation();
    } catch (bootstrapError) {
      console.error(
        "[frequent-zones] Failed to bootstrap schema:",
        bootstrapError instanceof Error ? bootstrapError.message : String(bootstrapError),
      );
    }
  }

  return result;
}

async function userHasFrequentZonesAccess(
  service: ReturnType<typeof createServiceClient>,
  userId: string,
): Promise<boolean> {
  const selectVariants = [
    "status,status_id,is_premium,role_id",
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
      const isUnknownColumn = message.includes("column") && message.includes("does not exist");
      if (isUnknownColumn) continue;
      console.warn("[frequent-zones] Unable to read user profile:", error.message ?? "unknown error");
      return false;
    }

    const profile = data as Record<string, unknown> | null;
    if (!profile) return false;
    if (isPaidStatusId(profile.status_id) || isPaidStatusId(profile.role_id)) return true;
    if (profile.is_premium === true) return true;
    return isPremiumLikeStatus(profile.status);
  }

  return false;
}

function normalizeZonePayload(
  zone: FrequentZonePayload,
  userId: string,
): { row: Record<string, unknown> } | { message: string; status: number } {
  const normalizedZone = (zone ?? {}) as Record<string, unknown>;
  const zoneId = pickString(normalizedZone, "id");
  const zoneUserId = pickString(normalizedZone, "userId", "user_id");
  const latitude = pickNumber(normalizedZone, "latitude");
  const longitude = pickNumber(normalizedZone, "longitude");
  const visits = pickInteger(normalizedZone, "visits") ?? 1;
  const rawName = pickString(normalizedZone, "name") || "Zone fréquente";
  const lastVisitedAtRaw = pickString(normalizedZone, "lastVisitedAt", "last_visited_at");
  const lastVisitedAt = lastVisitedAtRaw ? new Date(lastVisitedAtRaw) : new Date();
  const parkingType = pickString(normalizedZone, "parkingType", "parking_type") || "Inconnu";
  const preferredDuration = pickInteger(
    normalizedZone,
    "preferredDurationMinutes",
    "preferred_duration_minutes",
  );

  if (!isUuid(zoneId)) return { message: "ID de zone invalide.", status: 400 };
  if (zoneUserId && zoneUserId !== userId) return { message: "Forbidden", status: 403 };
  if (latitude === null || latitude < -90 || latitude > 90) {
    return { message: "Latitude invalide.", status: 400 };
  }
  if (longitude === null || longitude < -180 || longitude > 180) {
    return { message: "Longitude invalide.", status: 400 };
  }
  if (visits < 1) return { message: "Nombre de visites invalide.", status: 400 };
  if (Number.isNaN(lastVisitedAt.getTime())) return { message: "lastVisitedAt invalide.", status: 400 };
  if (!allowedParkingTypes.has(parkingType)) return { message: "Type de stationnement invalide.", status: 400 };

  const row: Record<string, unknown> = {
    id: zoneId,
    user_id: userId,
    name: rawName.trim().slice(0, 80),
    details: pickNullableString(normalizedZone, 1_000, "details"),
    landmark_level: pickNullableString(normalizedZone, 80, "landmarkLevel", "landmark_level"),
    latitude,
    longitude,
    visits,
    last_visited_at: lastVisitedAt.toISOString(),
    deleted_at: null,
    preferred_duration_minutes: preferredDuration === null ? null : clamp(preferredDuration, 5, 720),
    parking_type: parkingType,
  };

  return { row };
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
      scope: "frequent-zones",
      key: `${ip}:${auth.user.id}:${req.method}:${path}`,
      limit: 180,
      windowSeconds: 60,
    });
    if (!rate.allowed) {
      return errorResponse(`Trop de requêtes. Réessaie dans ${rate.retryAfterSeconds}s.`, 429, headers);
    }

    const service = createServiceClient();
    const userId = auth.user.id;
    const requestedUserId = url.searchParams.get("userId")?.trim() || userId;
    if (requestedUserId !== userId) return errorResponse("Forbidden", 403, headers);

    const tableName = await resolveFrequentZoneTable(service);

    if (req.method === "GET") {
      const includeDeletedRaw = (url.searchParams.get("includeDeleted") ?? "").trim().toLowerCase();
      const includeDeleted = includeDeletedRaw === "1" || includeDeletedRaw == "true";
      const { data, error } = await retryAfterFrequentZoneSchemaBootstrap(tableName, () => {
        let query = service
          .from(tableName)
          .select("*")
          .eq("user_id", userId)
          .order("last_visited_at", { ascending: false });

        if (!includeDeleted) {
          query = query.is("deleted_at", null);
        }

        return query;
      });

      if (error) return errorResponse(error.message ?? "Impossible de charger les zones fréquentes.", 500, headers);
      return jsonResponse((data ?? []).map(mapZoneRow), { headers });
    }

    if (req.method === "POST" && path.includes("/sync")) {
      const body = parseJson<SyncFrequentZonesBody>(await req.text());
      const normalizedBody = (body ?? {}) as Record<string, unknown>;
      const bodyUserId = pickString(normalizedBody, "userId", "user_id");
      if (bodyUserId !== userId) return errorResponse("Forbidden", 403, headers);

      const zones = Array.isArray(body?.zones) ? body.zones : [];
      if (zones.length > 100) return errorResponse("Trop de zones fréquentes.", 400, headers);

      const rows: Record<string, unknown>[] = [];
      for (const zone of zones) {
        const normalized = normalizeZonePayload(zone, userId);
        if ("message" in normalized) {
          return errorResponse(normalized.message, normalized.status, headers);
        }
        rows.push(normalized.row);
      }

      if (rows.length > 0) {
        const { error } = await retryAfterFrequentZoneSchemaBootstrap(tableName, () =>
          service
            .from(tableName)
            .upsert(rows, { onConflict: "id" })
        );

        if (error) return errorResponse(error.message ?? "Impossible de sauvegarder les zones fréquentes.", 500, headers);
      }

      const deletedAt = new Date().toISOString();
      const deleteResult = await retryAfterFrequentZoneSchemaBootstrap(tableName, () => {
        const deleteQuery = service
          .from(tableName)
          .update({ deleted_at: deletedAt })
          .eq("user_id", userId)
          .is("deleted_at", null);
        const idList = rows
          .map((row) => `"${String(row.id)}"`)
          .join(",");

        return rows.length > 0
          ? deleteQuery.not("id", "in", `(${idList})`)
          : deleteQuery;
      });

      if (deleteResult.error) {
        return errorResponse(deleteResult.error.message ?? "Impossible de nettoyer les zones fréquentes.", 500, headers);
      }

      const { data, error } = await retryAfterFrequentZoneSchemaBootstrap(tableName, () =>
        service
          .from(tableName)
          .select("*")
          .eq("user_id", userId)
          .order("last_visited_at", { ascending: false })
      );

      if (error) return errorResponse(error.message ?? "Impossible de relire les zones fréquentes.", 500, headers);
      return jsonResponse((data ?? []).map(mapZoneRow), { headers });
    }

    if (req.method === "DELETE") {
      const segments = path.split("/").filter(Boolean);
      const zoneId = segments[segments.length - 1] ?? "";
      if (!isUuid(zoneId)) return errorResponse("ID de zone invalide.", 400, headers);

      const { error } = await retryAfterFrequentZoneSchemaBootstrap(tableName, () =>
        service
          .from(tableName)
          .update({ deleted_at: new Date().toISOString() })
          .eq("user_id", userId)
          .eq("id", zoneId)
          .is("deleted_at", null)
      );

      if (error) return errorResponse(error.message ?? "Impossible de supprimer la zone fréquente.", 500, headers);
      return jsonResponse({ ok: true }, { headers });
    }

    return errorResponse("Route not found.", 404, headers);
  } catch (e) {
    return errorResponse(`Erreur serveur: ${e instanceof Error ? e.message : "unknown"}`, 500, headers);
  }
});
