/// <reference path="../_shared/deno-shim.d.ts" />

import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { errorResponse, jsonResponse } from "../_shared/response.ts";
import { checkRateLimit, getClientIp } from "../_shared/rateLimit.ts";
import { createAnonClient, createServiceClient, createUserClient, requireUser } from "../_shared/supabase.ts";
import { parseJson } from "../_shared/validation.ts";

type RegisterBody = {
  email?: string;
  password?: string;
  displayName?: string;
  display_name?: string;
  gdprConsent?: boolean;
  gdpr_consent?: boolean;
};

type LoginBody = {
  email?: string;
  password?: string;
};

type RefreshBody = {
  refreshToken?: string;
  refresh_token?: string;
};

type UpdateEmailBody = {
  newEmail?: string;
  new_email?: string;
  email?: string;
  redirectTo?: string;
  redirect_to?: string;
};

type ConfirmEmailChangeBody = {
  newEmail?: string;
  new_email?: string;
  email?: string;
  code?: string;
  token?: string;
};

type UpdatePasswordBody = {
  currentPassword?: string;
  current_password?: string;
  newPassword?: string;
  new_password?: string;
};

type UpdateProfileBody = {
  displayName?: string;
  display_name?: string;
  name?: string;
};

type UpdatePremiumBody = {
  isPremium?: boolean | number | string;
  is_premium?: boolean | number | string;
  plan?: string;
  productId?: string;
  product_id?: string;
  transactionId?: string | number;
  transaction_id?: string | number;
};

type RecoverBody = {
  email?: string;
  redirectTo?: string;
  redirect_to?: string;
};

type VerifyEmailCodeBeforeResetBody = {
  email?: string;
  code?: string;
  token?: string;
  redirectTo?: string;
  redirect_to?: string;
};

type AppleSignInBody = {
  idToken?: string;
  id_token?: string;
  token?: string;
  nonce?: string;
};

type RecoveryPasswordBody = {
  password?: string;
  newPassword?: string;
  new_password?: string;
};

type RefreshSessionPayload = {
  access_token: string;
  refresh_token: string;
  user: {
    id: string;
    email?: string;
    created_at?: string;
  };
};

function authHeaders() {
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  return {
    apikey: anon,
    "Content-Type": "application/json",
  };
}

function isRateLimited(message?: string | null) {
  return (message ?? "").toLowerCase().includes("rate limit");
}

function isEmailNotConfirmed(message?: string | null) {
  const lowered = (message ?? "").toLowerCase();
  return lowered.includes("email not confirmed") || lowered.includes("email_not_confirmed");
}

function isDatabaseErrorSavingNewUser(message?: string | null) {
  const lowered = (message ?? "").toLowerCase();
  return lowered.includes("database error saving new user") || lowered.includes("error saving new user");
}

function isEmailAlreadyInUse(message?: string | null) {
  const lowered = (message ?? "").toLowerCase();
  return lowered.includes("already registered")
    || lowered.includes("already exists")
    || lowered.includes("already in use")
    || lowered.includes("duplicate key")
    || lowered.includes("unique constraint")
    || lowered.includes("user already exists");
}

function isUnsupportedNativeAppleJWTAlgorithm(message?: string | null) {
  const lowered = (message ?? "")
    .trim()
    .toLowerCase();

  if (!lowered) {
    return false;
  }

  return lowered.includes("unsupported jwt algorithm")
    || (lowered.includes("es256") && lowered.includes("jwt"));
}

async function ensureFreeSubscriptionStatus(
  service: ReturnType<typeof createServiceClient>,
): Promise<number | null> {
  const { data: existing, error: selectError } = await service
    .from("subscription_statuses")
    .select("id")
    .eq("code", "free")
    .maybeSingle();

  if (!selectError && existing && typeof existing === "object" && typeof (existing as Record<string, unknown>).id === "number") {
    return (existing as Record<string, unknown>).id as number;
  }

  const { data: upserted, error: upsertError } = await service
    .from("subscription_statuses")
    .upsert(
      { code: "free", label: "Free" },
      { onConflict: "code" },
    )
    .select("id")
    .maybeSingle();

  if (upsertError) {
    console.warn("[auth/register] Unable to ensure free subscription status:", upsertError.message ?? "unknown error");
    return null;
  }

  if (upserted && typeof upserted === "object" && typeof (upserted as Record<string, unknown>).id === "number") {
    return (upserted as Record<string, unknown>).id as number;
  }

  const { data: fallback } = await service
    .from("subscription_statuses")
    .select("id")
    .eq("code", "free")
    .maybeSingle();

  if (fallback && typeof fallback === "object" && typeof (fallback as Record<string, unknown>).id === "number") {
    return (fallback as Record<string, unknown>).id as number;
  }

  return null;
}

type SubscriptionStatusCode = "free" | "paid_monthly" | "paid_lifetime";

function statusLabelForCode(code: SubscriptionStatusCode): string {
  switch (code) {
  case "free":
    return "Free";
  case "paid_monthly":
    return "Paid Monthly";
  case "paid_lifetime":
    return "Paid Lifetime";
  }
}

async function ensureSubscriptionStatusId(
  service: ReturnType<typeof createServiceClient>,
  code: SubscriptionStatusCode,
): Promise<number | null> {
  const { data: existing, error: selectError } = await service
    .from("subscription_statuses")
    .select("id")
    .eq("code", code)
    .maybeSingle();

  if (!selectError && existing && typeof existing === "object" && typeof (existing as Record<string, unknown>).id === "number") {
    return (existing as Record<string, unknown>).id as number;
  }

  const { data: upserted, error: upsertError } = await service
    .from("subscription_statuses")
    .upsert(
      { code, label: statusLabelForCode(code) },
      { onConflict: "code" },
    )
    .select("id")
    .maybeSingle();

  if (upsertError) {
    console.warn(`[auth/premium] Unable to ensure subscription status '${code}':`, upsertError.message ?? "unknown error");
    return null;
  }

  if (upserted && typeof upserted === "object" && typeof (upserted as Record<string, unknown>).id === "number") {
    return (upserted as Record<string, unknown>).id as number;
  }

  const { data: fallback } = await service
    .from("subscription_statuses")
    .select("id")
    .eq("code", code)
    .maybeSingle();

  if (fallback && typeof fallback === "object" && typeof (fallback as Record<string, unknown>).id === "number") {
    return (fallback as Record<string, unknown>).id as number;
  }

  return null;
}

function inferPaidStatusCodeFromBody(body: UpdatePremiumBody): SubscriptionStatusCode {
  const rawTokens = [
    body.plan,
    body.productId,
    body.product_id,
  ]
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
    .map((value) => normalizeStatusToken(value));

  for (const token of rawTokens) {
    if (token.includes("monthly") || token.includes("mensuel") || token.includes("mois")) {
      return "paid_monthly";
    }
    if (token.includes("lifetime") || token.includes("a_vie") || token.includes("life_time")) {
      return "paid_lifetime";
    }
    if (token === "paid_monthly" || token === "paid_lifetime") {
      return token === "paid_monthly" ? "paid_monthly" : "paid_lifetime";
    }
  }

  // Compat legacy payload (`isPremium: true`) => fallback à vie.
  return "paid_lifetime";
}

function normalizeTransactionID(raw: unknown): string | null {
  if (typeof raw === "string") {
    const trimmed = raw.trim();
    return trimmed.length > 0 ? trimmed : null;
  }

  if (typeof raw === "number" && Number.isFinite(raw)) {
    const integerValue = Math.trunc(raw);
    return integerValue > 0 ? String(integerValue) : null;
  }

  return null;
}

async function ensurePremiumEntitlementOwnership(
  service: ReturnType<typeof createServiceClient>,
  params: {
    userId: string;
    transactionId: string;
    productId: string | null;
  },
): Promise<{ ok: true } | { ok: false; status: number; message: string }> {
  const nowIso = new Date().toISOString();

  const { data: existing, error: selectError } = await service
    .from("premium_entitlement_claims")
    .select("transaction_id,user_id")
    .eq("transaction_id", params.transactionId)
    .maybeSingle();

  if (selectError) {
    const lowered = (selectError.message ?? "").toLowerCase();
    if (lowered.includes("premium_entitlement_claims")) {
      return {
        ok: false,
        status: 500,
        message: "Migration manquante: table premium_entitlement_claims absente.",
      };
    }
    return {
      ok: false,
      status: 500,
      message: selectError.message ?? "Failed to read premium entitlements.",
    };
  }

  const existingRow = (existing && typeof existing === "object") ? existing as Record<string, unknown> : null;
  const existingOwnerId = typeof existingRow?.user_id === "string" ? existingRow.user_id : null;

  if (existingOwnerId && existingOwnerId !== params.userId) {
    return {
      ok: false,
      status: 409,
      message: "This purchase is already linked to another ParkSpot account.",
    };
  }

  if (existingOwnerId === params.userId) {
    const { error: updateClaimError } = await service
      .from("premium_entitlement_claims")
      .update({
        product_id: params.productId,
        updated_at: nowIso,
      })
      .eq("transaction_id", params.transactionId);

    if (updateClaimError) {
      return {
        ok: false,
        status: 500,
        message: updateClaimError.message ?? "Failed to update the purchase-account link.",
      };
    }

    return { ok: true };
  }

  const { error: insertClaimError } = await service
    .from("premium_entitlement_claims")
    .insert({
      transaction_id: params.transactionId,
      user_id: params.userId,
      product_id: params.productId,
      claimed_at: nowIso,
      updated_at: nowIso,
    });

  if (!insertClaimError) {
    return { ok: true };
  }

  // Conflit concurrent possible: relire pour déterminer le propriétaire final.
  const { data: afterInsert } = await service
    .from("premium_entitlement_claims")
    .select("user_id")
    .eq("transaction_id", params.transactionId)
    .maybeSingle();
  const afterOwnerId = (
    afterInsert
    && typeof afterInsert === "object"
    && typeof (afterInsert as Record<string, unknown>).user_id === "string"
  ) ? (afterInsert as Record<string, unknown>).user_id as string : null;

  if (afterOwnerId === params.userId) {
    return { ok: true };
  }
  if (afterOwnerId && afterOwnerId !== params.userId) {
    return {
      ok: false,
      status: 409,
      message: "This purchase is already linked to another ParkSpot account.",
    };
  }

  return {
    ok: false,
    status: 500,
    message: insertClaimError.message ?? "Failed to create the purchase-account link.",
  };
}

async function ensureUserProfileRecord(
  service: ReturnType<typeof createServiceClient>,
  params: {
    userId: string;
    email: string;
    displayName: string;
    freeStatusId: number | null;
  },
): Promise<void> {
  const payloads: Record<string, unknown>[] = [];

  if (typeof params.freeStatusId === "number") {
    payloads.push({
      id: params.userId,
      display_name: params.displayName,
      email: params.email,
      status: "free",
      status_id: params.freeStatusId,
    });
  }

  payloads.push({
    id: params.userId,
    display_name: params.displayName,
    email: params.email,
    status: "free",
  });

  payloads.push({
    id: params.userId,
    display_name: params.displayName,
    email: params.email,
  });

  let lastError: string | null = null;

  for (const payload of payloads) {
    const { error } = await service
      .from("user_profiles")
      .upsert(payload, { onConflict: "id" });

    if (!error) {
      return;
    }

    lastError = error.message ?? "unknown error";
  }

  if (lastError) {
    console.warn("[auth/register] Unable to ensure user profile row:", lastError);
  }
}

function extractSupabaseMessage(payload: unknown, fallback: string): string {
  if (!payload || typeof payload !== "object") return fallback;

  const record = payload as Record<string, unknown>;
  const candidates = [
    record.message,
    record.error_description,
    record.error,
    record.msg,
  ];

  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim()) {
      return candidate.trim();
    }
  }

  return fallback;
}

function isAllowedRecoveryRedirect(raw: string): boolean {
  const trimmed = raw.trim();
  if (!trimmed) return false;

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return false;
  }

  const scheme = parsed.protocol.replace(":", "").toLowerCase();
  const appScheme = (Deno.env.get("PARKSPOT_PASSWORD_RESET_APP_SCHEME") ?? "parkspot").toLowerCase();

  if (scheme === appScheme) {
    return true;
  }

  if (scheme !== "https") {
    return false;
  }

  const allowedHosts = (Deno.env.get("PARKSPOT_ALLOWED_RECOVERY_REDIRECT_HOSTS") ?? "")
    .split(",")
    .map((host) => host.trim().toLowerCase())
    .filter((host) => host.length > 0);

  if (!allowedHosts.length) {
    return true;
  }

  return allowedHosts.includes(parsed.host.toLowerCase());
}

function normalizeStatusToken(value: string): string {
  return value.trim().toLowerCase().replace(/[\s-]+/g, "_");
}

function isFreeLikeStatus(status: unknown): boolean {
  if (typeof status === "string") {
    return normalizeStatusToken(status) === "free";
  }

  if (status && typeof status === "object") {
    const record = status as Record<string, unknown>;
    return isFreeLikeStatus(
      record.code
      ?? record.status
      ?? record.value
      ?? record.name,
    );
  }

  return false;
}

function isPremiumLikeStatus(status: unknown): boolean {
  const numericRole = coerceRoleId(status);
  if (isPaidRoleId(numericRole)) {
    return true;
  }

  if (typeof status === "string") {
    const normalized = normalizeStatusToken(status);
    return normalized === "paid"
      || normalized === "premium"
      || normalized === "paid_monthly"
      || normalized === "paid_lifetime";
  }

  if (status && typeof status === "object") {
    const record = status as Record<string, unknown>;
    return isPremiumLikeStatus(
      record.code
      ?? record.status
      ?? record.value
      ?? record.name,
    );
  }

  return false;
}

function coerceRoleId(value: unknown): number | null {
  if (typeof value === "number" && Number.isInteger(value)) {
    return value;
  }

  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!/^[-+]?\d+$/.test(trimmed)) return null;
    const parsed = Number(trimmed);
    if (Number.isInteger(parsed)) {
      return parsed;
    }
  }

  return null;
}

function isPaidRoleId(roleId: number | null): boolean {
  return roleId === 2 || roleId === 3;
}

function isFreeRoleId(roleId: number | null): boolean {
  return roleId === 1;
}

function coerceBoolean(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;

  if (typeof value === "number") {
    if (value === 1) return true;
    if (value === 0) return false;
  }

  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["true", "t", "1", "yes", "y", "on"].includes(normalized)) return true;
    if (["false", "f", "0", "no", "n", "off"].includes(normalized)) return false;
  }

  return null;
}

function pickFirstRecordValue(record: Record<string, unknown> | null, keys: string[]): unknown {
  if (!record) return null;
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(record, key)) {
      return record[key];
    }
  }
  return null;
}

function toRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object") return null;
  return value as Record<string, unknown>;
}

function extractProfileStatus(profile: unknown): unknown {
  return pickFirstRecordValue(toRecord(profile), [
    "status",
    "subscription_status",
    "subscriptionStatus",
    "code",
  ]);
}

function extractProfileStatusId(profile: unknown): unknown {
  return pickFirstRecordValue(toRecord(profile), [
    "status_id",
    "statusId",
    "role_id",
    "roleId",
    "status_role_id",
    "statusRoleId",
  ]);
}

function extractProfileDisplayName(profile: unknown): string | null {
  const value = pickFirstRecordValue(toRecord(profile), [
    "display_name",
    "displayName",
    "name",
    "full_name",
    "fullName",
  ]);
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

async function resolveUserStatusRow(
  service: ReturnType<typeof createServiceClient>,
  userId: string,
): Promise<Record<string, unknown> | null> {
  const candidates: Array<{ table: string; userIdColumn: string }> = [
    { table: "user_status", userIdColumn: "user_id" },
    { table: "user_status", userIdColumn: "id_user" },
    { table: "user_status", userIdColumn: "id" },
    { table: "user_status", userIdColumn: "profile_id" },
    { table: "user_status", userIdColumn: "auth_user_id" },
    { table: "user_status", userIdColumn: "auth_id" },
    { table: "user_status", userIdColumn: "uid" },
    { table: "user_statuses", userIdColumn: "user_id" },
    { table: "user_statuses", userIdColumn: "id_user" },
    { table: "user_statuses", userIdColumn: "id" },
    { table: "user_statuses", userIdColumn: "profile_id" },
    { table: "user_statuses", userIdColumn: "auth_user_id" },
    { table: "user_statuses", userIdColumn: "auth_id" },
    { table: "user_statuses", userIdColumn: "uid" },
    { table: "users_status", userIdColumn: "user_id" },
    { table: "users_status", userIdColumn: "id_user" },
    { table: "users_status", userIdColumn: "id" },
    { table: "users_status", userIdColumn: "profile_id" },
    { table: "users_status", userIdColumn: "auth_user_id" },
    { table: "users_status", userIdColumn: "auth_id" },
    { table: "users_status", userIdColumn: "uid" },
  ];

  for (const candidate of candidates) {
    const { data, error } = await service
      .from(candidate.table)
      .select("*")
      .eq(candidate.userIdColumn, userId)
      .maybeSingle();

    if (error) {
      continue;
    }

    if (data && typeof data === "object") {
      return data as Record<string, unknown>;
    }
  }

  return null;
}

async function resolveUserPremiumState(
  service: ReturnType<typeof createServiceClient>,
  userId: string,
  fallbackStatus?: unknown,
  fallbackStatusId?: unknown,
): Promise<boolean> {
  // Business rule: status/role ids 2 and 3 are paid, id 1 is free.
  // The app uses this boolean to disable ads and unlock widgets.
  const profileRoleId = coerceRoleId(fallbackStatusId);
  if (isFreeRoleId(profileRoleId) || isFreeLikeStatus(fallbackStatus)) {
    return false;
  }
  if (isPaidRoleId(profileRoleId)) {
    return true;
  }

  const row = await resolveUserStatusRow(service, userId);

  const subscriptionStatus = pickFirstRecordValue(row, [
    "status",
    "code",
    "subscription_status",
    "subscriptionStatus",
  ]);
  const roleId = coerceRoleId(pickFirstRecordValue(row, [
    "role_id",
    "status_role_id",
    "status_id",
    "roleId",
    "statusRoleId",
    "statusId",
  ]));

  // Hard business rule requested: id 1 is always free, ids 2 & 3 are always paid.
  if (isFreeRoleId(roleId) || isFreeLikeStatus(subscriptionStatus)) {
    return false;
  }
  if (isPaidRoleId(roleId)) {
    return true;
  }

  const rowAdsEnabled = coerceBoolean(pickFirstRecordValue(row, [
    "ads_enabled",
    "adsEnabled",
  ]));
  if (rowAdsEnabled !== null) {
    return !rowAdsEnabled;
  }

  // Preferred source: role metadata (status_roles.ads_enabled / code)
  if (roleId !== null) {
    const { data: roleRow } = await service
      .from("status_roles")
      .select("code,ads_enabled")
      .eq("id", roleId)
      .maybeSingle();

    const role = (roleRow && typeof roleRow === "object") ? (roleRow as Record<string, unknown>) : null;
    const adsEnabled = coerceBoolean(role?.ads_enabled);
    if (adsEnabled !== null) {
      return !adsEnabled;
    }

    if (role?.code !== undefined && role?.code !== null) {
      if (isFreeLikeStatus(role.code)) {
        return false;
      }
      return isPremiumLikeStatus(role.code);
    }

  }

  // Legacy fallback source: user_profiles.status_id
  if (profileRoleId !== null) {
    if (isFreeRoleId(profileRoleId)) {
      return false;
    }
    return isPaidRoleId(profileRoleId);
  }

  if (subscriptionStatus !== undefined && subscriptionStatus !== null) {
    if (isFreeLikeStatus(subscriptionStatus)) {
      return false;
    }
    return isPremiumLikeStatus(subscriptionStatus);
  }

  if (isFreeLikeStatus(fallbackStatus)) {
    return false;
  }
  return isPremiumLikeStatus(fallbackStatus);
}

async function safeSelectByUserId(
  service: ReturnType<typeof createServiceClient>,
  table: string,
  userId: string,
  userIdColumn = "user_id",
) {
  const { data, error } = await service
    .from(table)
    .select("*")
    .eq(userIdColumn, userId);

  if (error) {
    return { rows: [], error: error.message ?? `Lecture ${table} échouée.` };
  }

  return { rows: data ?? [], error: null };
}

async function safeSelectByIds(
  service: ReturnType<typeof createServiceClient>,
  table: string,
  column: string,
  ids: string[],
) {
  if (!ids.length) return { rows: [], error: null };

  const { data, error } = await service
    .from(table)
    .select("*")
    .in(column, ids);

  if (error) {
    return { rows: [], error: error.message ?? `Lecture ${table} échouée.` };
  }

  return { rows: data ?? [], error: null };
}

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  const headers = corsHeaders(req.headers.get("Origin"));
  const url = new URL(req.url);
  const pathname = url.pathname.replace(/\/+$/g, "").toLowerCase();

  let route = pathname;
  if (route.startsWith("/functions/v1/auth")) route = route.slice("/functions/v1/auth".length);
  else if (route.startsWith("/auth")) route = route.slice("/auth".length);
  if (!route) route = "/";
  if (!route.startsWith("/")) route = `/${route}`;

  try {
    const rawBody = req.method === "GET" ? "" : await req.text();
    const parsed = rawBody ? parseJson<Record<string, unknown>>(rawBody) : {};
    const action = typeof parsed?.action === "string" ? parsed.action.toLowerCase() : "";

    const routeKey = route === "/" ? action : route.slice(1);
    console.log(`[auth] Request: ${req.method} ${url.pathname} -> route: ${route}, action: ${action}, routeKey: ${routeKey}`);

    const ip = getClientIp(req);
    const emailCandidate = (
      typeof parsed?.email === "string"
        ? parsed.email
        : typeof parsed?.newEmail === "string"
          ? parsed.newEmail
          : typeof parsed?.new_email === "string"
            ? parsed.new_email
            : ""
    ).trim().toLowerCase();

    const authRateRule = (() => {
      switch (routeKey) {
      case "register":
      case "register/confirm":
      case "login":
      case "apple":
      case "recover":
      case "recover/confirm-email":
      case "email/confirm":
        return {
          limit: 8,
          windowSeconds: 60,
          key: `${ip}:${emailCandidate || "no-email"}:${routeKey}`,
        };
      case "refresh":
        return {
          limit: 20,
          windowSeconds: 60,
          key: `${ip}:${routeKey}`,
        };
      default:
        return {
          limit: 120,
          windowSeconds: 60,
          key: `${ip}:${routeKey || "root"}`,
        };
      }
    })();

    const limitResult = checkRateLimit({
      scope: "auth",
      key: authRateRule.key,
      limit: authRateRule.limit,
      windowSeconds: authRateRule.windowSeconds,
    });

    if (!limitResult.allowed) {
      return errorResponse(
        `Trop de requêtes. Réessaie dans ${limitResult.retryAfterSeconds}s.`,
        429,
        headers,
      );
    }

    if (req.method === "POST" && (route === "/register" || (route === "/" && action === "register"))) {
      const body = parsed as RegisterBody;
      const displayName = body.displayName ?? body.display_name;
      const cleanDisplayName = displayName?.trim() ?? "";
      const gdprConsent = body.gdprConsent ?? body.gdpr_consent;
      const email = body.email?.trim().toLowerCase() ?? "";

      if (!body?.email || !body?.password || !cleanDisplayName) {
        return errorResponse("Champs obligatoires manquants.", 400, headers);
      }
      if (cleanDisplayName.length < 2 || cleanDisplayName.length > 80) {
        return errorResponse("First name must contain between 2 and 80 characters.", 400, headers);
      }
      if (body.password.length < 8) {
        return errorResponse("Password must contain at least 8 characters.", 400, headers);
      }
      if (gdprConsent !== true) {
        return errorResponse("Consentement RGPD requis.", 400, headers);
      }

      const service = createServiceClient();
      const freeStatusId = await ensureFreeSubscriptionStatus(service);

      const anonClient = createAnonClient();
      const emailRedirectTo = (Deno.env.get("PARKSPOT_AUTH_CALLBACK_URL") ?? "").trim();
      const signUp = await anonClient.auth.signUp({
        email,
        password: body.password,
        options: {
          data: { display_name: cleanDisplayName },
          ...(emailRedirectTo ? { emailRedirectTo } : {}),
        },
      });

      if (signUp.error || !signUp.data.user) {
        const msg = signUp.error?.message ?? "Sign-up failed.";
        if (isRateLimited(msg)) {
          return errorResponse("Too many sign-up attempts. Try again in a few minutes.", 429, headers);
        }
        if ((msg ?? "").toLowerCase().includes("already registered")) {
          return errorResponse("An account already exists with this email.", 409, headers);
        }
        if (isDatabaseErrorSavingNewUser(msg)) {
          return errorResponse(
            "Database error while creating the account. Apply the migration SQL (Backend/supabase/sql/schema.sql) in Supabase, then redeploy the auth function.",
            500,
            headers,
          );
        }
        return errorResponse(msg, 400, headers);
      }

      // Profile creation is deferred until confirmation to avoid unverified records.
      if (!signUp.data.session) {
          return jsonResponse(
            {
              requiresEmailConfirmation: true,
              confirmationEmail: signUp.data.user.email ?? email,
            },
            {
              status: 202,
              message: "Account created. Check your email to confirm your sign-up.",
              headers,
            },
          );
      }

      await ensureUserProfileRecord(service, {
        userId: signUp.data.user.id,
        email: signUp.data.user.email ?? email,
        displayName: cleanDisplayName,
        freeStatusId,
      });

      const { data: profile } = await service
        .from("user_profiles")
        .select("*")
        .eq("id", signUp.data.user.id)
        .maybeSingle();
      const isPremium = await resolveUserPremiumState(
        service,
        signUp.data.user.id,
        extractProfileStatus(profile),
        extractProfileStatusId(profile),
      );

      return jsonResponse(
        {
          accessToken: signUp.data.session?.access_token ?? "",
          refreshToken: signUp.data.session?.refresh_token ?? "",
          user: {
            id: signUp.data.user.id,
            email: signUp.data.user.email ?? email,
            displayName: (signUp.data.user.user_metadata?.display_name as string | undefined) ?? cleanDisplayName,
            isPremium,
            status: extractProfileStatus(profile),
            statusId: extractProfileStatusId(profile),
            createdAt: signUp.data.user.created_at ?? new Date().toISOString(),
          },
        },
        { headers },
      );
    }

    if (req.method === "DELETE" && (route === "/register" || (route === "/" && action === "register"))) {
      console.log(`[auth] DELETE /register for email: ${parsed?.email}`);
      const body = parsed as { email?: string };
      const email = body.email?.trim().toLowerCase() ?? "";

      if (!email) {
        return errorResponse("Email requis pour annuler l'inscription.", 400, headers);
      }

      const service = createServiceClient();
      const { data: existingProfile } = await service
        .from("user_profiles")
        .select("id")
        .ilike("email", email)
        .maybeSingle();

      if (!existingProfile) {
        return jsonResponse({ ok: true }, { headers });
      }

      const userId = existingProfile.id;
      const { data: authUser } = await service.auth.admin.getUserById(userId);
      if (authUser?.user?.email_confirmed_at) {
        return errorResponse("Impossible d'annuler une inscription déjà confirmée.", 403, headers);
      }

      await service.from("parking_sessions").delete().eq("user_id", userId);
      await service.from("user_profiles").delete().eq("id", userId);
      await service.auth.admin.deleteUser(userId);

      return jsonResponse({ ok: true }, { headers });
    }

    if (req.method === "POST" && route === "/register/confirm") {
      const body = parsed as { email?: string; code?: string };
      const email = body.email?.trim().toLowerCase() ?? "";
      const code = body.code?.trim() ?? "";

      if (!email || !code) {
        return errorResponse("Email et code requis.", 400, headers);
      }

      const anonClient = createAnonClient();
      const verify = await anonClient.auth.verifyOtp({
        email,
        token: code,
        type: "signup",
      });

      if (verify.error || !verify.data.user || !verify.data.session) {
        const msg = verify.error?.message ?? "Code de confirmation invalide.";
        return errorResponse(msg, 400, headers);
      }

      const service = createServiceClient();

      // Create the user profile upon successful confirmation if it doesn't exist yet.
      const freeStatusId = await ensureFreeSubscriptionStatus(service);
      const metadata = (verify.data.user.user_metadata ?? {}) as Record<string, unknown>;
      const displayNameFromMetadata = typeof metadata.display_name === "string" ? metadata.display_name : "Utilisateur";

      await ensureUserProfileRecord(service, {
        userId: verify.data.user.id,
        email: verify.data.user.email ?? email,
        displayName: displayNameFromMetadata,
        freeStatusId,
      });

      const { data: profile } = await service
        .from("user_profiles")
        .select("*")
        .eq("id", verify.data.user.id)
        .maybeSingle();

      const isPremium = await resolveUserPremiumState(
        service,
        verify.data.user.id,
        extractProfileStatus(profile),
        extractProfileStatusId(profile),
      );

      return jsonResponse(
        {
          accessToken: verify.data.session.access_token,
          refreshToken: verify.data.session.refresh_token,
          user: {
            id: verify.data.user.id,
            email: verify.data.user.email ?? email,
            displayName: extractProfileDisplayName(profile) ?? (verify.data.user.user_metadata?.display_name as string | undefined) ?? "Utilisateur",
            isPremium,
            status: extractProfileStatus(profile),
            statusId: extractProfileStatusId(profile),
            createdAt: verify.data.user.created_at ?? new Date().toISOString(),
          },
        },
        { headers },
      );
    }

    if (req.method === "POST" && (route === "/login" || (route === "/" && action === "login"))) {
      const body = parsed as LoginBody;
      if (!body?.email || !body?.password) {
        return errorResponse("Email et mot de passe requis.", 400, headers);
      }

      const anonClient = createAnonClient();
      const login = await anonClient.auth.signInWithPassword({
        email: body.email.trim().toLowerCase(),
        password: body.password,
      });

      if (login.error || !login.data.user || !login.data.session) {
        const msg = login.error?.message ?? "Sign-in failed.";
        if (isRateLimited(msg)) {
          return errorResponse("Too many sign-in attempts. Try again in a few minutes.", 429, headers);
        }
        if (isEmailNotConfirmed(msg)) {
          return errorResponse("Email not confirmed. Check your inbox before signing in.", 401, headers);
        }
        return errorResponse(msg, 401, headers);
      }

      const service = createServiceClient();
      const { data: profile } = await service
        .from("user_profiles")
        .select("*")
        .eq("id", login.data.user.id)
        .maybeSingle();
      const isPremium = await resolveUserPremiumState(
        service,
        login.data.user.id,
        extractProfileStatus(profile),
        extractProfileStatusId(profile),
      );

      return jsonResponse(
        {
          accessToken: login.data.session.access_token,
          refreshToken: login.data.session.refresh_token,
          user: {
            id: login.data.user.id,
            email: login.data.user.email ?? body.email.trim().toLowerCase(),
            displayName: extractProfileDisplayName(profile) ?? (login.data.user.user_metadata?.display_name as string | undefined) ?? "Utilisateur",
            isPremium,
            status: extractProfileStatus(profile),
            statusId: extractProfileStatusId(profile),
            createdAt: login.data.user.created_at ?? new Date().toISOString(),
          },
        },
        { headers },
      );
    }

    if (req.method === "POST" && route === "/apple") {
      const body = parsed as AppleSignInBody;
      const idToken = (body.idToken ?? body.id_token ?? body.token ?? "").trim();
      const nonce = (body.nonce ?? "").trim();

      if (!idToken) {
        return errorResponse("Jeton Apple manquant.", 400, headers);
      }
      if (!nonce) {
        return errorResponse("Nonce Apple manquant.", 400, headers);
      }

      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const resp = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=id_token`, {
        method: "POST",
        headers: authHeaders(),
        body: JSON.stringify({
          provider: "apple",
          id_token: idToken,
          token: idToken,
          nonce,
        }),
      });

      const payload = await resp.json().catch(() => null);
      if (!resp.ok) {
        const message = extractSupabaseMessage(payload, "Sign in with Apple failed.");
        if (isRateLimited(message)) {
          return errorResponse("Too many attempts. Try again in a few minutes.", 429, headers);
        }
        if (isUnsupportedNativeAppleJWTAlgorithm(message)) {
          // Force the app onto the web OAuth fallback when Supabase rejects
          // the native Apple identity token algorithm.
          return errorResponse(message, 404, headers);
        }
        return errorResponse(message, resp.status === 401 ? 401 : 400, headers);
      }

      const session = payload as Record<string, unknown> | null;
      const accessToken = typeof session?.access_token === "string" ? session.access_token : "";
      const refreshToken = typeof session?.refresh_token === "string" ? session.refresh_token : "";

      if (!accessToken) {
        return errorResponse("Invalid Apple response.", 502, headers);
      }

      return jsonResponse(
        {
          accessToken,
          refreshToken,
        },
        { headers },
      );
    }

    if (req.method === "POST" && route === "/recover") {
      const body = parsed as RecoverBody;
      const email = (body.email ?? "").trim().toLowerCase();
      const redirectTo = (body.redirectTo ?? body.redirect_to ?? "").trim();

      if (!email || !email.includes("@") || !email.includes(".")) {
        return errorResponse("Invalid email address.", 400, headers);
      }
      if (!redirectTo) {
        return errorResponse("URL de redirection manquante.", 400, headers);
      }
      if (!isAllowedRecoveryRedirect(redirectTo)) {
        return errorResponse("Redirect URL not allowed.", 400, headers);
      }

      const service = createServiceClient();
      const { data: existingProfile, error: profileError } = await service
        .from("user_profiles")
        .select("id")
        .ilike("email", email)
        .maybeSingle();

      if (profileError) {
        return errorResponse(profileError.message ?? "Unable to verify the account.", 500, headers);
      }

      if (!existingProfile) {
        return errorResponse("Cette adresse e-mail n'est pas inscrite.", 400, headers);
      }

      const { data: authUserResult, error: authUserError } = await service.auth.admin.getUserById(existingProfile.id);
      if (authUserError) {
        return errorResponse(authUserError.message ?? "Unable to verify the account.", 500, headers);
      }

      const anonClient = createAnonClient();

      if (!authUserResult?.user?.email_confirmed_at) {
        const confirmationRedirectTo = (Deno.env.get("PARKSPOT_AUTH_CALLBACK_URL") ?? "").trim() || redirectTo;
        const resend = await anonClient.auth.resend({
          type: "signup",
          email,
          options: confirmationRedirectTo ? { emailRedirectTo: confirmationRedirectTo } : undefined,
        });

        if (resend.error) {
          const msg = resend.error.message ?? "Failed to send the confirmation email.";
          if (isRateLimited(msg)) {
            return errorResponse("Too many attempts. Try again in a few minutes.", 429, headers);
          }
          return errorResponse(msg, 400, headers);
        }

        return jsonResponse(
          {
            ok: true,
            requiresEmailConfirmation: true,
          },
          {
            status: 202,
            message: "A confirmation code has been sent. Enter it in the app to receive the reset link.",
            headers,
          },
        );
      }

      const reset = await anonClient.auth.resetPasswordForEmail(email, { redirectTo });

      if (reset.error) {
        const msg = reset.error.message ?? "Failed to send the recovery link.";
        if (isRateLimited(msg)) {
          return errorResponse("Too many attempts. Try again in a few minutes.", 429, headers);
        }
        return errorResponse(msg, 400, headers);
      }

      return jsonResponse({ ok: true }, { headers });
    }

    if (req.method === "POST" && route === "/recover/confirm-email") {
      const body = parsed as VerifyEmailCodeBeforeResetBody;
      const email = (body.email ?? "").trim().toLowerCase();
      const code = (body.code ?? body.token ?? "").trim();
      const redirectTo = (body.redirectTo ?? body.redirect_to ?? "").trim();

      if (!email || !email.includes("@") || !email.includes(".")) {
        return errorResponse("Invalid email address.", 400, headers);
      }
      if (!code) {
        return errorResponse("Code de confirmation manquant.", 400, headers);
      }
      if (!redirectTo) {
        return errorResponse("URL de redirection manquante.", 400, headers);
      }
      if (!isAllowedRecoveryRedirect(redirectTo)) {
        return errorResponse("Redirect URL not allowed.", 400, headers);
      }

      const anonClient = createAnonClient();

      const verifyWithType = async (type: "signup" | "email") =>
        await anonClient.auth.verifyOtp({
          email,
          token: code,
          type,
        });

      let verify = await verifyWithType("signup");
      if (verify.error) {
        verify = await verifyWithType("email");
      }

      if (verify.error) {
        const msg = verify.error.message ?? "Code de confirmation invalide.";
        if (isRateLimited(msg)) {
          return errorResponse("Too many attempts. Try again in a few minutes.", 429, headers);
        }
        return errorResponse(msg, 400, headers);
      }

      const reset = await anonClient.auth.resetPasswordForEmail(email, { redirectTo });
      if (reset.error) {
        const msg = reset.error.message ?? "Failed to send the recovery link.";
        if (isRateLimited(msg)) {
          return errorResponse("Too many attempts. Try again in a few minutes.", 429, headers);
        }
        return errorResponse(msg, 400, headers);
      }

      return jsonResponse(
        { ok: true },
        {
          headers,
          message: "Email confirmed. The reset email has been sent.",
        },
      );
    }

    if (req.method === "GET" && route === "/me") {
      const authResult = await requireUser(req);
      if (!authResult.user) return errorResponse("Unauthorized", 401, headers);

      const service = createServiceClient();
      const { data: profile } = await service
        .from("user_profiles")
        .select("*")
        .eq("id", authResult.user.id)
        .maybeSingle();
      const isPremium = await resolveUserPremiumState(
        service,
        authResult.user.id,
        extractProfileStatus(profile),
        extractProfileStatusId(profile),
      );

      return jsonResponse(
        {
          id: authResult.user.id,
          email: authResult.user.email ?? "",
          displayName: extractProfileDisplayName(profile) ?? "Utilisateur",
          isPremium,
          status: extractProfileStatus(profile),
          statusId: extractProfileStatusId(profile),
          createdAt: authResult.user.created_at ?? new Date().toISOString(),
        },
        { headers },
      );
    }

    if (req.method === "PUT" && route === "/premium") {
      const authResult = await requireUser(req);
      if (!authResult.user) return errorResponse("Unauthorized", 401, headers);

      const body = parsed as UpdatePremiumBody;
      const premiumRaw = body.isPremium ?? body.is_premium;
      const isPremium = coerceBoolean(premiumRaw);

      if (isPremium === null) {
        return errorResponse("Invalid isPremium parameter.", 400, headers);
      }

      const service = createServiceClient();
      const statusCode: SubscriptionStatusCode = isPremium
        ? inferPaidStatusCodeFromBody(body)
        : "free";
      const statusId = await ensureSubscriptionStatusId(service, statusCode);
      const incomingProductId = (typeof body.productId === "string" && body.productId.trim().length > 0)
        ? body.productId.trim()
        : (typeof body.product_id === "string" && body.product_id.trim().length > 0)
          ? body.product_id.trim()
          : null;

      if (isPremium) {
        const transactionId = normalizeTransactionID(body.transactionId ?? body.transaction_id);
        if (!transactionId) {
          return errorResponse("transactionId requis pour activer Premium.", 400, headers);
        }

        const ownership = await ensurePremiumEntitlementOwnership(service, {
          userId: authResult.user.id,
          transactionId,
          productId: incomingProductId,
        });
        if (!ownership.ok) {
          return errorResponse(ownership.message, ownership.status, headers);
        }
      }

      const patch: Record<string, unknown> = {
        status: statusCode,
        updated_at: new Date().toISOString(),
      };
      if (typeof statusId === "number") {
        patch.status_id = statusId;
      }

      const userMetadata = (authResult.user.user_metadata ?? {}) as Record<string, unknown>;
      const metadataDisplayName =
        typeof userMetadata.display_name === "string"
          ? userMetadata.display_name.trim()
          : "";
      const defaultDisplayName = metadataDisplayName || "Utilisateur";
      const freeStatusId = await ensureFreeSubscriptionStatus(service);
      await ensureUserProfileRecord(service, {
        userId: authResult.user.id,
        email: authResult.user.email ?? "",
        displayName: defaultDisplayName,
        freeStatusId,
      });

      let { error: updateError } = await service
        .from("user_profiles")
        .update(patch)
        .eq("id", authResult.user.id);

      const patchWithoutStatusId: Record<string, unknown> = {
        status: patch.status,
        updated_at: patch.updated_at,
      };

      if (updateError && Object.prototype.hasOwnProperty.call(patch, "status_id")) {
        // Compatibilité avec schémas où status_id n'est pas numérique (ex: uuid).
        const retryWithoutStatusId = await service
          .from("user_profiles")
          .update(patchWithoutStatusId)
          .eq("id", authResult.user.id);
        updateError = retryWithoutStatusId.error;
      }

      if (updateError && statusCode === "paid_lifetime") {
        // Compatibilité avec d'anciennes contraintes SQL qui autorisent "premium"
        // mais pas encore "paid_lifetime".
        const legacyPatch: Record<string, unknown> = {
          ...patchWithoutStatusId,
          status: "premium",
        };
        const retry = await service
          .from("user_profiles")
          .update(legacyPatch)
          .eq("id", authResult.user.id);
        updateError = retry.error;
      }

      if (updateError) {
        return errorResponse(updateError.message ?? "Failed to update premium status.", 500, headers);
      }

      const { data: profile } = await service
        .from("user_profiles")
        .select("*")
        .eq("id", authResult.user.id)
        .maybeSingle();
      const resolvedPremium = await resolveUserPremiumState(
        service,
        authResult.user.id,
        extractProfileStatus(profile),
        extractProfileStatusId(profile),
      );

      return jsonResponse(
        {
          id: authResult.user.id,
          email: authResult.user.email ?? "",
          displayName: extractProfileDisplayName(profile) ?? defaultDisplayName,
          isPremium: resolvedPremium,
          status: extractProfileStatus(profile),
          statusId: extractProfileStatusId(profile),
          createdAt: authResult.user.created_at ?? new Date().toISOString(),
        },
        { headers },
      );
    }

    if (req.method === "GET" && route === "/export") {
      const authResult = await requireUser(req);
      if (!authResult.user) return errorResponse("Unauthorized", 401, headers);

      const service = createServiceClient();
      const userId = authResult.user.id;

      const unavailableTables: Record<string, string> = {};

      const { data: profile, error: profileError } = await service
        .from("user_profiles")
        .select("*")
        .eq("id", userId)
        .maybeSingle();

      if (profileError) {
        unavailableTables.user_profiles = profileError.message ?? "Read failed";
      }

      const parkingSessionsResult = await safeSelectByUserId(service, "parking_sessions", userId);
      if (parkingSessionsResult.error) unavailableTables.parking_sessions = parkingSessionsResult.error;

      const vehiclesResult = await safeSelectByUserId(service, "vehicles", userId);
      if (vehiclesResult.error) unavailableTables.vehicles = vehiclesResult.error;

      const vehicleIds = (vehiclesResult.rows ?? [])
        .map((row: Record<string, unknown>) => row.id)
        .filter((id: unknown) => typeof id === "string") as string[];

      const maintenanceItemsResult = await safeSelectByIds(service, "maintenance_items", "vehicle_id", vehicleIds);
      if (maintenanceItemsResult.error) unavailableTables.maintenance_items = maintenanceItemsResult.error;

      const diagnosticsResult = await safeSelectByIds(service, "ai_diagnostics", "vehicle_id", vehicleIds);
      if (diagnosticsResult.error) unavailableTables.ai_diagnostics = diagnosticsResult.error;

      const { data: authUserResult, error: authUserError } = await service.auth.admin.getUserById(userId);
      if (authUserError) {
        unavailableTables.auth_user = authUserError.message ?? "Read failed";
      }

      const exportPayload = {
        exportedAt: new Date().toISOString(),
        scope: "all-known-user-data",
        user: {
          id: authResult.user.id,
          email: authResult.user.email ?? "",
          createdAt: authResult.user.created_at ?? null,
          lastSignInAt: authResult.user.last_sign_in_at ?? null,
          appMetadata: authUserResult?.user?.app_metadata ?? authResult.user.app_metadata ?? {},
          userMetadata: authUserResult?.user?.user_metadata ?? authResult.user.user_metadata ?? {},
          emailConfirmedAt: authUserResult?.user?.email_confirmed_at ?? authResult.user.email_confirmed_at ?? null,
          phone: authUserResult?.user?.phone ?? authResult.user.phone ?? null,
          role: authUserResult?.user?.role ?? authResult.user.role ?? null,
          identities: authUserResult?.user?.identities ?? [],
        },
        profile: profile ?? null,
        parkingSessions: parkingSessionsResult.rows,
        vehicles: vehiclesResult.rows,
        maintenanceItems: maintenanceItemsResult.rows,
        diagnostics: diagnosticsResult.rows,
        unavailableTables,
      };

      const content = JSON.stringify(exportPayload, null, 2);
      const generatedAt = new Date().toISOString();
      const safeTimestamp = generatedAt.replace(/[.:]/g, "-");

      return jsonResponse(
        {
          fileName: `parkspot-export-${userId}-${safeTimestamp}.json`,
          contentType: "application/json",
          content,
          generatedAt,
        },
        { headers },
      );
    }

    if (req.method === "PUT" && route === "/email") {
      const authResult = await requireUser(req);
      if (!authResult.user || !authResult.token) return errorResponse("Unauthorized", 401, headers);

      const body = parsed as UpdateEmailBody;
      const newEmail = (body.newEmail ?? body.new_email ?? body.email ?? "").trim().toLowerCase();
      if (!newEmail || !newEmail.includes("@") || !newEmail.includes(".")) {
        return errorResponse("Invalid email address.", 400, headers);
      }

      const currentEmail = (authResult.user.email ?? "").trim().toLowerCase();
      if (currentEmail && currentEmail === newEmail) {
        return errorResponse("This email address is already the account email.", 400, headers);
      }

      const redirectFromBody = (body.redirectTo ?? body.redirect_to ?? "").trim();
      const redirectTo = redirectFromBody
        || (Deno.env.get("PARKSPOT_CHANGE_EMAIL_REDIRECT_URL") ?? "").trim()
        || (Deno.env.get("PARKSPOT_AUTH_CALLBACK_URL") ?? "").trim();

      if (!redirectTo) {
        return errorResponse("URL de redirection manquante.", 400, headers);
      }

      if (!isAllowedRecoveryRedirect(redirectTo)) {
        return errorResponse("Redirect URL not allowed.", 400, headers);
      }

      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const updateUrl = new URL(`${supabaseUrl}/auth/v1/user`);
      if (redirectTo) updateUrl.searchParams.set("redirect_to", redirectTo);

      const updateResp = await fetch(updateUrl.toString(), {
        method: "PUT",
        headers: {
          ...authHeaders(),
          Authorization: `Bearer ${authResult.token}`,
        },
        body: JSON.stringify({ email: newEmail }),
      });

      if (!updateResp.ok) {
        const updatePayload = await updateResp.json().catch(() => null);
        const msg = extractSupabaseMessage(updatePayload, "Email update failed.");
        if (isRateLimited(msg)) {
          return errorResponse("Too many attempts. Try again in a few minutes.", 429, headers);
        }
        if (isEmailAlreadyInUse(msg)) {
          return errorResponse("Cette adresse e-mail est deja utilisee.", 409, headers);
        }
        return errorResponse(msg, updateResp.status >= 500 ? 502 : 400, headers);
      }

      return jsonResponse(
        {
          ok: true,
          pendingEmail: newEmail,
          requiresEmailConfirmation: true,
        },
        {
          status: 202,
          headers,
          message: "Un code de confirmation a ete envoye a la nouvelle adresse. Saisis-le dans l'app pour finaliser le changement.",
        },
      );
    }

    if (req.method === "POST" && route === "/email/confirm") {
      const authResult = await requireUser(req);
      if (!authResult.user) return errorResponse("Unauthorized", 401, headers);

      const body = parsed as ConfirmEmailChangeBody;
      const newEmail = (body.newEmail ?? body.new_email ?? body.email ?? "").trim().toLowerCase();
      const code = (body.code ?? body.token ?? "").trim();

      if (!newEmail || !newEmail.includes("@") || !newEmail.includes(".")) {
        return errorResponse("Invalid email address.", 400, headers);
      }
      if (!code) {
        return errorResponse("Code de confirmation manquant.", 400, headers);
      }

      const anonClient = createAnonClient();
      const verifyWithType = async (type: "email_change" | "email") =>
        await anonClient.auth.verifyOtp({
          email: newEmail,
          token: code,
          type,
        });

      let verify = await verifyWithType("email_change");
      if (verify.error) {
        verify = await verifyWithType("email");
      }

      if (verify.error) {
        const msg = verify.error.message ?? "Code de confirmation invalide.";
        if (isRateLimited(msg)) {
          return errorResponse("Trop de tentatives. Reessaie dans quelques minutes.", 429, headers);
        }
        return errorResponse(msg, 400, headers);
      }

      const verifiedUserId = verify.data?.user?.id;
      if (typeof verifiedUserId === "string" && verifiedUserId !== authResult.user.id) {
        return errorResponse("Ce code ne correspond pas a l'utilisateur connecte.", 403, headers);
      }

      const service = createServiceClient();

      // Force finalization on the new email after OTP verification.
      // This intentionally bypasses any project-level "Secure email change"
      // requirement for validating the old email.
      const { data: updatedAuthUser, error: forceUpdateError } = await service.auth.admin.updateUserById(authResult.user.id, {
        email: newEmail,
        email_confirm: true,
      });

      if (forceUpdateError) {
        const msg = forceUpdateError.message ?? "Email update failed.";
        if (isEmailAlreadyInUse(msg)) {
          return errorResponse("Cette adresse e-mail est deja utilisee.", 409, headers);
        }
        return errorResponse(msg, 400, headers);
      }

      if (!updatedAuthUser?.user) {
        return errorResponse("Verification du compte impossible (user missing).", 500, headers);
      }

      // Explicitly update the user profile email to ensure synchronization
      // in case the database trigger is delayed or restricted.
      await service
        .from("user_profiles")
        .update({ email: newEmail, updated_at: new Date().toISOString() })
        .eq("id", authResult.user.id);

      const refreshedAuthUser = updatedAuthUser;

      const { data: profile } = await service
        .from("user_profiles")
        .select("*")
        .eq("id", authResult.user.id)
        .maybeSingle();
      const isPremium = await resolveUserPremiumState(
        service,
        authResult.user.id,
        extractProfileStatus(profile),
        extractProfileStatusId(profile),
      );

      const resolvedEmail = (refreshedAuthUser.user.email ?? authResult.user.email ?? "")
        .trim()
        .toLowerCase();

      return jsonResponse(
        {
          ok: true,
          requiresCurrentEmailConfirmation: false,
          user: {
            id: refreshedAuthUser.user.id,
            email: newEmail,
            displayName:
              extractProfileDisplayName(profile)
              ?? (refreshedAuthUser.user.user_metadata?.display_name as string | undefined)
              ?? "Utilisateur",
            isPremium,
            status: extractProfileStatus(profile),
            statusId: extractProfileStatusId(profile),
            createdAt: refreshedAuthUser.user.created_at ?? new Date().toISOString(),
          },
        },
        {
          status: 200,
          headers,
          message: "Adresse e-mail mise a jour.",
        },
      );
    }

    if (req.method === "PUT" && route === "/password") {
      const authResult = await requireUser(req);
      if (!authResult.user) return errorResponse("Unauthorized", 401, headers);

      const body = parsed as UpdatePasswordBody;
      const currentPassword = body.currentPassword ?? body.current_password ?? "";
      const newPassword = body.newPassword ?? body.new_password ?? "";

      if (!currentPassword) return errorResponse("Veuillez renseigner le mot de passe actuel.", 400, headers);
      if (newPassword.length < 8) {
        return errorResponse("The new password must contain at least 8 characters.", 400, headers);
      }

      const email = authResult.user.email ?? "";
      if (!email) return errorResponse("Utilisateur invalide.", 400, headers);

      const anonClient = createAnonClient();
      const checkCurrent = await anonClient.auth.signInWithPassword({
        email,
        password: currentPassword,
      });

      if (checkCurrent.error || !checkCurrent.data.user) {
        return errorResponse("Current password is incorrect.", 401, headers);
      }

      const service = createServiceClient();
      const { error } = await service.auth.admin.updateUserById(authResult.user.id, {
        password: newPassword,
      });

      if (error) return errorResponse(error.message ?? "Password update failed.", 400, headers);
      return jsonResponse({ ok: true }, { headers });
    }

    if (req.method === "PUT" && route === "/password/recovery") {
      const authResult = await requireUser(req);
      if (!authResult.user || !authResult.token) return errorResponse("Unauthorized", 401, headers);

      const body = parsed as RecoveryPasswordBody;
      const nextPassword = (body.newPassword ?? body.new_password ?? body.password ?? "").trim();

      if (nextPassword.length < 8) {
        return errorResponse("The new password must contain at least 8 characters.", 400, headers);
      }

      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const resp = await fetch(`${supabaseUrl}/auth/v1/user`, {
        method: "PUT",
        headers: {
          ...authHeaders(),
          Authorization: `Bearer ${authResult.token}`,
        },
        body: JSON.stringify({ password: nextPassword }),
      });

      const payload = await resp.json().catch(() => null);
      if (!resp.ok) {
        const message = extractSupabaseMessage(payload, "Password update failed.");
        if (resp.status === 401) {
          return errorResponse("Unauthorized", 401, headers);
        }
        return errorResponse(message, resp.status >= 500 ? 502 : 400, headers);
      }

      return jsonResponse({ ok: true }, { headers });
    }

    if (req.method === "PUT" && route === "/profile") {
      const authResult = await requireUser(req);
      if (!authResult.user) return errorResponse("Unauthorized", 401, headers);

      const body = parsed as UpdateProfileBody;
      const nextDisplayName = (body.displayName ?? body.display_name ?? body.name ?? "")
        .trim();

      if (!nextDisplayName || nextDisplayName.length < 2 || nextDisplayName.length > 80) {
        return errorResponse("Invalid display name (2 to 80 characters).", 400, headers);
      }

      const service = createServiceClient();

      const { error: profileError } = await service
        .from("user_profiles")
        .update({ display_name: nextDisplayName, updated_at: new Date().toISOString() })
        .eq("id", authResult.user.id);

      if (profileError) {
        return errorResponse("Profile update failed.", 500, headers);
      }

      // Keep auth metadata aligned with profile display name.
      await service.auth.admin.updateUserById(authResult.user.id, {
        user_metadata: {
          ...(authResult.user.user_metadata ?? {}),
          display_name: nextDisplayName,
        },
      });

      const { data: profile } = await service
        .from("user_profiles")
        .select("*")
        .eq("id", authResult.user.id)
        .maybeSingle();
      const isPremium = await resolveUserPremiumState(
        service,
        authResult.user.id,
        extractProfileStatus(profile),
        extractProfileStatusId(profile),
      );

      return jsonResponse(
        {
          id: authResult.user.id,
          email: authResult.user.email ?? "",
          displayName: extractProfileDisplayName(profile) ?? nextDisplayName,
          isPremium,
          status: extractProfileStatus(profile),
          statusId: extractProfileStatusId(profile),
          createdAt: authResult.user.created_at ?? new Date().toISOString(),
        },
        { headers },
      );
    }

    if (req.method === "POST" && (route === "/refresh" || (route === "/" && action === "refresh"))) {
      const body = parsed as RefreshBody;
      const refreshToken = body.refreshToken ?? body.refresh_token;
      if (!refreshToken) {
        return errorResponse("Refresh token requis.", 400, headers);
      }

      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const resp = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=refresh_token`, {
        method: "POST",
        headers: authHeaders(),
        body: JSON.stringify({ refresh_token: refreshToken }),
      });

      if (!resp.ok) return errorResponse("Refresh failed.", 401, headers);
      const session = await resp.json() as RefreshSessionPayload;

      const service = createServiceClient();
      const { data: profile } = await service
        .from("user_profiles")
        .select("*")
        .eq("id", session.user?.id)
        .maybeSingle();
      const isPremium = await resolveUserPremiumState(
        service,
        session.user.id,
        extractProfileStatus(profile),
        extractProfileStatusId(profile),
      );

      return jsonResponse(
        {
          accessToken: session.access_token,
          refreshToken: session.refresh_token,
          user: {
            id: session.user.id,
            email: session.user.email,
            displayName: extractProfileDisplayName(profile) ?? "Utilisateur",
            isPremium,
            status: extractProfileStatus(profile),
            statusId: extractProfileStatusId(profile),
            createdAt: session.user.created_at ?? new Date().toISOString(),
          },
        },
        { headers },
      );
    }

    if (req.method === "POST" && route === "/logout") {
      const auth = req.headers.get("Authorization") ?? "";
      const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
      if (!token) return errorResponse("Unauthorized", 401, headers);

      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      await fetch(`${supabaseUrl}/auth/v1/logout`, {
        method: "POST",
        headers: { ...authHeaders(), Authorization: `Bearer ${token}` },
      });

      return jsonResponse({ ok: true }, { headers });
    }

    if (req.method === "DELETE" && route === "/account") {
      const authResult = await requireUser(req);
      if (!authResult.user) return errorResponse("Unauthorized", 401, headers);

      const service = createServiceClient();
      const userId = authResult.user.id;

      await service.from("parking_sessions").delete().eq("user_id", userId);
      await service.from("user_profiles").delete().eq("id", userId);

      const { error } = await service.auth.admin.deleteUser(userId);
      if (error) return errorResponse("Account deletion failed.", 500, headers);

      return jsonResponse({ ok: true }, { headers });
    }

    return errorResponse("Route not found.", 404, headers);
  } catch (e) {
    return errorResponse(`Erreur serveur: ${e instanceof Error ? e.message : "unknown"}`, 500, headers);
  }
});
