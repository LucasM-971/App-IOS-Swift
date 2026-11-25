/// <reference path="../_shared/deno-shim.d.ts" />

import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { checkRateLimit, getClientIp } from "../_shared/rateLimit.ts";
import { errorResponse, jsonResponse } from "../_shared/response.ts";
import { createServiceClient, requireUser } from "../_shared/supabase.ts";
import { clamp, isUuid, parseJson } from "../_shared/validation.ts";

type HistoryEventPayload = {
  id?: string;
  userId?: string;
  user_id?: string;
  latitude?: number;
  longitude?: number;
  addressName?: string | null;
  address_name?: string | null;
  eventType?: string;
  event_type?: string;
  createdAt?: string;
  created_at?: string;
  syncedAt?: string | null;
  synced_at?: string | null;
  deletedAt?: string | null;
  deleted_at?: string | null;
  metadata?: Record<string, string> | null;
};

type HistoryUpsertBody = {
  events?: HistoryEventPayload[];
};

type HistoryDeleteBody = {
  userId?: string;
  user_id?: string;
  ids?: string[];
};

const allowedEventTypes = new Set([
  "parking_saved",
  "parking_ended",
  "manual_checkpoint",
  "imported",
]);

function isMissingRelationError(message: string | undefined): boolean {
  const normalized = (message ?? "").toLowerCase();
  return normalized.includes("relation") &&
    normalized.includes("does not exist");
}

function normalizeMetadata(value: unknown): Record<string, string> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  const sanitized = Object.entries(value as Record<string, unknown>).reduce<
    Record<string, string>
  >((result, [key, entry]) => {
    const trimmedKey = key.trim();
    const normalizedValue = typeof entry === "string" ? entry.trim() : "";
    if (!trimmedKey || !normalizedValue) {
      return result;
    }
    result[trimmedKey] = normalizedValue;
    return result;
  }, {});

  return Object.keys(sanitized).length > 0 ? sanitized : null;
}

function parseDate(
  value: unknown,
  _fieldName: string,
  required = false,
): Date | null {
  if (value === null || value === undefined || value === "") {
    return required ? new Date(Number.NaN) : null;
  }

  if (typeof value !== "string") {
    return new Date(Number.NaN);
  }

  return new Date(value);
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

function mapHistoryRow(row: Record<string, unknown>) {
  return {
    id: row.id,
    userId: row.user_id,
    latitude: row.latitude,
    longitude: row.longitude,
    addressName: row.address_name,
    eventType: row.event_type,
    createdAt: row.created_at,
    syncedAt: row.synced_at,
    deletedAt: row.deleted_at,
    metadata: row.metadata ?? null,
  };
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
      scope: "history",
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
    const userId = auth.user.id;

    if (req.method === "POST" && path.includes("/events/upsert")) {
      const body = parseJson<HistoryUpsertBody>(await req.text());
      const events = Array.isArray(body?.events) ? body.events : [];

      if (events.length === 0) {
        return jsonResponse([], { headers });
      }

      const rows: Record<string, unknown>[] = [];
      for (const event of events) {
        const normalizedEvent = event as Record<string, unknown>;
        const eventId = pickString(normalizedEvent, "id");
        const eventUserId = pickString(normalizedEvent, "userId", "user_id");
        const eventType = pickString(
          normalizedEvent,
          "eventType",
          "event_type",
        );
        const latitude = pickNumber(normalizedEvent, "latitude");
        const longitude = pickNumber(normalizedEvent, "longitude");

        if (!isUuid(eventId)) {
          return errorResponse("ID d'historique invalide.", 400, headers);
        }
        if (eventUserId !== userId) {
          return errorResponse("Forbidden", 403, headers);
        }
        if (
          latitude === null ||
          longitude === null
        ) {
          return errorResponse(
            "Coordonnées d'historique invalides.",
            400,
            headers,
          );
        }
        if (!allowedEventTypes.has(eventType)) {
          return errorResponse("Type d'historique invalide.", 400, headers);
        }

        const createdAt = parseDate(
          normalizedEvent.createdAt ?? normalizedEvent.created_at,
          "createdAt",
          true,
        );
        const syncedAt = parseDate(
          normalizedEvent.syncedAt ?? normalizedEvent.synced_at,
          "syncedAt",
        );
        const deletedAt = parseDate(
          normalizedEvent.deletedAt ?? normalizedEvent.deleted_at,
          "deletedAt",
        );

        if (!createdAt || Number.isNaN(createdAt.getTime())) {
          return errorResponse("createdAt invalide.", 400, headers);
        }
        if (syncedAt && Number.isNaN(syncedAt.getTime())) {
          return errorResponse("syncedAt invalide.", 400, headers);
        }
        if (deletedAt && Number.isNaN(deletedAt.getTime())) {
          return errorResponse("deletedAt invalide.", 400, headers);
        }

        rows.push({
          id: eventId,
          user_id: userId,
          latitude,
          longitude,
          address_name: pickNullableString(
            normalizedEvent,
            "addressName",
            "address_name",
          ),
          event_type: eventType,
          created_at: createdAt.toISOString(),
          synced_at: (syncedAt ?? new Date()).toISOString(),
          deleted_at: deletedAt ? deletedAt.toISOString() : null,
          metadata: normalizeMetadata(normalizedEvent.metadata),
        });
      }

      const { data, error } = await service
        .from("parking_history_events")
        .upsert(rows, { onConflict: "id" })
        .select("*");

      if (error) {
        if (isMissingRelationError(error.message)) {
          return errorResponse(
            "Migration manquante: table parking_history_events absente.",
            500,
            headers,
          );
        }
        return errorResponse(
          error.message ?? "Impossible de sauvegarder l'historique.",
          500,
          headers,
        );
      }

      return jsonResponse((data ?? []).map(mapHistoryRow), { headers });
    }

    if (req.method === "POST" && path.includes("/events/delete")) {
      const body = parseJson<HistoryDeleteBody>(await req.text());
      const normalizedBody = (body ?? {}) as Record<string, unknown>;
      const requestedUserId = pickString(normalizedBody, "userId", "user_id");
      const ids = Array.isArray(body?.ids)
        ? body.ids.map((value) => typeof value === "string" ? value.trim() : "")
          .filter(Boolean)
        : [];

      if (requestedUserId !== userId) {
        return errorResponse("Forbidden", 403, headers);
      }
      if (ids.some((value) => !isUuid(value))) {
        return errorResponse(
          "Identifiants d'historique invalides.",
          400,
          headers,
        );
      }
      if (ids.length === 0) {
        return jsonResponse({ ok: true, deleted: 0 }, { headers });
      }

      const { error } = await service
        .from("parking_history_events")
        .delete()
        .eq("user_id", userId)
        .in("id", ids);

      if (error) {
        if (isMissingRelationError(error.message)) {
          return errorResponse(
            "Migration manquante: table parking_history_events absente.",
            500,
            headers,
          );
        }
        return errorResponse(
          error.message ?? "Impossible de supprimer l'historique.",
          500,
          headers,
        );
      }

      return jsonResponse({ ok: true, deleted: ids.length }, { headers });
    }

    if (req.method === "GET" && path.includes("/events")) {
      const limit = clamp(
        Number(url.searchParams.get("limit") ?? "20") || 20,
        1,
        100,
      );
      const offset = Math.max(
        0,
        Number(url.searchParams.get("offset") ?? "0") || 0,
      );
      const includeDeleted = url.searchParams.get("includeDeleted") === "1";

      let query = service
        .from("parking_history_events")
        .select("*")
        .eq("user_id", userId)
        .order("created_at", { ascending: false })
        .range(offset, offset + limit - 1);

      if (!includeDeleted) {
        query = query.is("deleted_at", null);
      }

      const { data, error } = await query;

      if (error) {
        if (isMissingRelationError(error.message)) {
          return errorResponse(
            "Migration manquante: table parking_history_events absente.",
            500,
            headers,
          );
        }
        return errorResponse(
          error.message ?? "Impossible de lire l'historique.",
          500,
          headers,
        );
      }

      return jsonResponse((data ?? []).map(mapHistoryRow), { headers });
    }

    if (req.method === "DELETE" && path.includes("/events/user/")) {
      const requestedUserId = path.split("/").pop()?.trim() ?? "";
      if (!isUuid(requestedUserId)) {
        return errorResponse("User ID invalide.", 400, headers);
      }
      if (requestedUserId !== userId) {
        return errorResponse("Forbidden", 403, headers);
      }

      const { error } = await service
        .from("parking_history_events")
        .delete()
        .eq("user_id", userId);

      if (error) {
        if (isMissingRelationError(error.message)) {
          return errorResponse(
            "Migration manquante: table parking_history_events absente.",
            500,
            headers,
          );
        }
        return errorResponse(
          error.message ?? "Impossible de supprimer l'historique.",
          500,
          headers,
        );
      }

      return jsonResponse({ ok: true }, { headers });
    }

    return errorResponse("Route not found.", 404, headers);
  } catch (error) {
    return errorResponse(
      `Erreur serveur: ${error instanceof Error ? error.message : "unknown"}`,
      500,
      headers,
    );
  }
});
