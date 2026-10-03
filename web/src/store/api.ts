let csrf = "";
export class APIError extends Error {
  constructor(
    public status: number,
    public code: string,
    public details: Record<string, unknown> = {},
  ) {
    super(code);
  }
}
export function setCSRF(value: string) {
  csrf = value;
}
export async function api<T = Record<string, any>>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const write = options.method && options.method !== "GET";
  const response = await fetch("/api/v1" + path, {
    credentials: "same-origin",
    ...options,
    headers: {
      ...(write
        ? { "content-type": "application/json", "x-csrf-token": csrf }
        : {}),
      ...options.headers,
    },
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new APIError(
      response.status,
      body.error?.code ?? "serviceUnavailable",
      body.error ?? {},
    );
  }
  if (response.status === 204) return undefined as T;
  return response.json();
}
