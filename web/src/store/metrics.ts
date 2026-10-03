import { useSyncExternalStore } from "react";
import { api, APIError } from "./api";
type Snapshot = Record<string, any>;
let state: {
  snapshot: Snapshot;
  appsSequence: string;
  connection: string;
  receivedAt: number;
} = { snapshot: {}, appsSequence: "", connection: "connecting", receivedAt: 0 };
const listeners = new Set<() => void>();
let source: EventSource | undefined,
  viewer: string | undefined,
  timer: ReturnType<typeof setTimeout> | undefined,
  renew: ReturnType<typeof setInterval> | undefined;
let active = false,
  connecting = false,
  generation = 0;
function publish(change: Partial<typeof state>) {
  state = { ...state, ...change };
  listeners.forEach((fn) => fn());
}
export function useMetrics() {
  return useSyncExternalStore(
    (fn) => {
      listeners.add(fn);
      return () => {
        listeners.delete(fn);
      };
    },
    () => state,
  );
}
async function connect() {
  if (!active || document.hidden || connecting || source) return;
  const revision = generation;
  connecting = true;
  try {
    await api("/auth/session");
    const lease = await api("/viewers", {
      method: "POST",
      body: JSON.stringify({ channels: ["system", "apps"] }),
    });
    if (revision !== generation) {
      void api("/viewers/" + lease.viewerId, { method: "DELETE" }).catch(
        () => {},
      );
      return;
    }
    viewer = lease.viewerId;
    source = new EventSource(
      "/api/v1/events?viewerId=" + encodeURIComponent(viewer!),
    );
    source.onopen = () => publish({ connection: "connected" });
    source.addEventListener("system", (event) =>
      publish({
        snapshot: JSON.parse((event as MessageEvent).data),
        receivedAt: performance.now(),
      }),
    );
    source.addEventListener("apps", (event) =>
      publish({
        appsSequence: JSON.parse((event as MessageEvent).data).scanSequence,
      }),
    );
    source.onerror = () => {
      close();
      publish({ connection: "offline" });
      void verifyAndRetry();
    };
    renew = setInterval(() => {
      if (viewer)
        void api("/viewers/" + viewer, {
          method: "PATCH",
          body: JSON.stringify({ visible: true, channels: ["system", "apps"] }),
        }).catch(() => {
          close();
          void verifyAndRetry();
        });
    }, 15000);
  } catch (error) {
    if (error instanceof APIError && [401, 403].includes(error.status))
      window.dispatchEvent(new Event("authentication-required"));
    else schedule();
  } finally {
    connecting = false;
  }
}
function schedule() {
  if (active && !document.hidden) {
    clearTimeout(timer);
    timer = setTimeout(() => void connect(), 3000);
  }
}
async function verifyAndRetry() {
  try {
    await api("/auth/session");
    schedule();
  } catch (error) {
    if (error instanceof APIError && [401, 403].includes(error.status))
      window.dispatchEvent(new Event("authentication-required"));
    else schedule();
  }
}
function close() {
  source?.close();
  source = undefined;
  if (renew) clearInterval(renew);
  const old = viewer;
  viewer = undefined;
  if (old) void api("/viewers/" + old, { method: "DELETE" }).catch(() => {});
}
function visibility() {
  generation++;
  close();
  if (!document.hidden) void connect();
}
export function startConnection() {
  if (active) return;
  active = true;
  document.addEventListener("visibilitychange", visibility);
  void api("/snapshot")
    .then((snapshot) => publish({ snapshot, receivedAt: performance.now() }))
    .catch(() => {});
  void connect();
}
export function stopConnection() {
  active = false;
  generation++;
  close();
  clearTimeout(timer);
  document.removeEventListener("visibilitychange", visibility);
  publish({
    snapshot: {},
    appsSequence: "",
    receivedAt: 0,
    connection: "connecting",
  });
}
