/// <reference path="../_shared/deno-shim.d.ts" />

type AuthResponse = {
  accessToken?: string;
  refreshToken?: string;
  user?: {
    id: string;
    email: string;
  };
};

async function postJson<T>(
  url: string,
  payload: unknown,
  bearer?: string,
): Promise<T> {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}),
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const message = await response.text();
    throw new Error(`HTTP ${response.status}: ${message}`);
  }

  return await response.json() as T;
}

Deno.test("auth e2e: login -> refresh -> logout", async () => {
  const baseUrl = Deno.env.get("PARKSPOT_E2E_AUTH_BASE_URL") ?? "";
  const email = Deno.env.get("PARKSPOT_E2E_AUTH_EMAIL") ?? "";
  const password = Deno.env.get("PARKSPOT_E2E_AUTH_PASSWORD") ?? "";

  // Skip gracefully when CI secrets are not configured.
  if (!baseUrl || !email || !password) {
    return;
  }

  const login = await postJson<AuthResponse>(`${baseUrl}/login`, {
    email,
    password,
  });
  if (!login.accessToken || !login.refreshToken || !login.user?.id) {
    throw new Error("Login response missing tokens or user.");
  }

  const refreshed = await postJson<AuthResponse>(`${baseUrl}/refresh`, {
    refreshToken: login.refreshToken,
  });
  if (!refreshed.accessToken || !refreshed.refreshToken) {
    throw new Error("Refresh response missing tokens.");
  }

  await postJson<{ ok: boolean }>(
    `${baseUrl}/logout`,
    {},
    refreshed.accessToken,
  );
});
