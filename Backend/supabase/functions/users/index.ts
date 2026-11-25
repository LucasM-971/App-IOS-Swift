/// <reference path="../_shared/deno-shim.d.ts" />

import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { checkRateLimit, getClientIp } from "../_shared/rateLimit.ts";
import { errorResponse, jsonResponse } from "../_shared/response.ts";
import { createServiceClient, requireUser } from "../_shared/supabase.ts";
import { isUuid } from "../_shared/validation.ts";

function isMissingRelationError(message: string | undefined): boolean {
  const normalized = (message ?? "").toLowerCase();
  return normalized.includes("relation") &&
    normalized.includes("does not exist");
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
      scope: "users",
      key: `${ip}:${auth.user.id}:${req.method}:${path}`,
      limit: 120,
      windowSeconds: 60,
    });
    if (!rate.allowed) {
      return errorResponse(
        `Trop de requêtes. Réessaie dans ${rate.retryAfterSeconds}s.`,
        429,
        headers,
      );
    }

    if (req.method === "DELETE" && path.includes("data")) {
      const userId = path.split("/").filter((x) => x && x !== "data").pop();
      if (!userId || !isUuid(userId)) {
        return errorResponse("User ID invalide.", 400, headers);
      }
      if (auth.user.id !== userId) {
        return errorResponse("Forbidden", 403, headers);
      }

      const service = createServiceClient();
      const { error } = await service
        .from("parking_sessions")
        .delete()
        .eq("user_id", userId);

      if (error) return errorResponse("Failed to delete data.", 500, headers);

      const historyDelete = await service
        .from("parking_history_events")
        .delete()
        .eq("user_id", userId);

      if (
        historyDelete.error &&
        !isMissingRelationError(historyDelete.error.message)
      ) {
        return errorResponse(
          "Failed to delete history backup data.",
          500,
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
