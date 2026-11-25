export type ApiPayload<T> = {
  success: boolean;
  message?: string;
  data: T;
};

export function jsonResponse<T>(
  data: T,
  init?: { status?: number; message?: string; headers?: HeadersInit },
): Response {
  const payload: ApiPayload<T> = {
    success: (init?.status ?? 200) < 400,
    message: init?.message,
    data,
  };

  return new Response(JSON.stringify(payload), {
    status: init?.status ?? 200,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...init?.headers,
    },
  });
}

export function errorResponse(
  message: string,
  status = 400,
  headers?: HeadersInit,
): Response {
  return jsonResponse<null>(null, { status, message, headers });
}
