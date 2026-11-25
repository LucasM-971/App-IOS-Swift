type RateLimitParams = {
  scope: string;
  key: string;
  limit: number;
  windowSeconds: number;
};

type RateLimitResult = {
  allowed: boolean;
  remaining: number;
  retryAfterSeconds: number;
};

type Bucket = {
  count: number;
  resetAt: number;
};

const buckets = new Map<string, Bucket>();

export function getClientIp(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for") ?? "";
  const firstForwarded = forwarded.split(",")[0]?.trim();
  if (firstForwarded) return firstForwarded;

  const realIp = req.headers.get("x-real-ip")?.trim();
  if (realIp) return realIp;

  return "unknown";
}

export function checkRateLimit(params: RateLimitParams): RateLimitResult {
  const now = Date.now();
  const windowMs = params.windowSeconds * 1000;
  const bucketKey = `${params.scope}:${params.key}`;

  const current = buckets.get(bucketKey);
  if (!current || now >= current.resetAt) {
    buckets.set(bucketKey, { count: 1, resetAt: now + windowMs });
    return {
      allowed: true,
      remaining: Math.max(0, params.limit - 1),
      retryAfterSeconds: params.windowSeconds,
    };
  }

  if (current.count >= params.limit) {
    const retryAfterSeconds = Math.max(1, Math.ceil((current.resetAt - now) / 1000));
    return {
      allowed: false,
      remaining: 0,
      retryAfterSeconds,
    };
  }

  current.count += 1;
  buckets.set(bucketKey, current);

  return {
    allowed: true,
    remaining: Math.max(0, params.limit - current.count),
    retryAfterSeconds: Math.max(1, Math.ceil((current.resetAt - now) / 1000)),
  };
}
