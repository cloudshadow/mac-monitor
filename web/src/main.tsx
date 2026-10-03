import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  languages,
  selectLanguage,
  preferredLanguage,
  ensureNamespaces,
  useI18n,
  errorMessage,
} from "./i18n";
import type { Language } from "./i18n/generated/registry";
import { api, setCSRF, APIError } from "./store/api";
import { startConnection, stopConnection, useMetrics } from "./store/metrics";
import { Authentication } from "./pages/Authentication";
import { Pairing } from "./pages/Pairing";
import { Overview } from "./pages/Overview";
import { Applications } from "./pages/Applications";
import { History } from "./pages/History";
import "./style.css";
const fragment = new URLSearchParams(location.hash.slice(1)),
  setupTicket = fragment.get("setup") ?? "",
  pairTicket = fragment.get("pair") ?? "";
if (location.hash)
  history.replaceState(null, "", location.pathname + location.search);
function App() {
  const { t, language, number } = useI18n(),
    [status, setStatus] = useState("loading"),
    [page, setPage] = useState("overview"),
    [error, setError] = useState(""),
    [ready, setReady] = useState(false),
    [age, setAge] = useState(0),
    [storage, setStorage] = useState<Record<string, any>>(),
    metrics = useMetrics();
  async function restore() {
    try {
      const result = await api("/auth/status");
      if (result.status === "authenticated") {
        const session = await api("/auth/session");
        setCSRF(session.csrfToken);
        startConnection();
      }
      setStatus(result.status);
    } catch (e) {
      setError(e instanceof APIError ? e.code : "serviceUnavailable");
      setStatus("offline");
    }
  }
  useEffect(() => {
    void selectLanguage(preferredLanguage(), ["auth", "pairing"])
      .then(() => setReady(true))
      .catch(() => setReady(true));
    void restore();
    const required = () => {
      stopConnection();
      setStatus("loginRequired");
    };
    window.addEventListener("authentication-required", required);
    return () => {
      window.removeEventListener("authentication-required", required);
      stopConnection();
    };
  }, []);
  useEffect(() => {
    if (!ready) return;
    const ns =
      page === "overview"
        ? "dashboard"
        : page === "applications"
          ? "apps"
          : page;
    void ensureNamespaces([ns, "auth", "pairing"]).catch(() =>
      setError("serviceUnavailable"),
    );
    if (page === "settings" && status === "authenticated")
      void api("/history/status")
        .then(setStorage)
        .catch(() => {});
  }, [page, status, ready]);
  useEffect(() => {
    const timer = setInterval(
      () =>
        !document.hidden &&
        setAge(
          metrics.receivedAt
            ? (performance.now() - metrics.receivedAt) / 1000
            : 0,
        ),
      1000,
    );
    return () => clearInterval(timer);
  }, [metrics.receivedAt]);
  async function logout() {
    try {
      await api("/auth/logout", { method: "POST", body: "{}" });
      stopConnection();
      setCSRF("");
      setStatus("loginRequired");
    } catch (e) {
      setError(e instanceof APIError ? e.code : "serviceUnavailable");
    }
  }
  if (!ready) return <main>Cloud Mac Monitor…</main>;
  return (
    <>
      <header>
        <a className="brand" href="/">
          {t("common:title")}
        </a>
        <span className="version">v{__APP_VERSION__}</span>
        <select
          aria-label={t("settings:language")}
          value={language}
          onChange={(e) =>
            void selectLanguage(e.target.value as Language).catch(() =>
              setError("serviceUnavailable"),
            )
          }
        >
          {languages.map((l) => (
            <option value={l.tag} key={l.tag}>
              {l.nativeName}
            </option>
          ))}
        </select>
        {status === "authenticated" && (
          <button onClick={() => void logout()}>{t("common:logout")}</button>
        )}
      </header>
      <main>
        {status === "authenticated" ? (
          <>
            <nav>
              {(
                ["overview", "applications", "history", "settings"] as const
              ).map((p) => (
                <button
                  aria-current={page === p ? "page" : undefined}
                  key={p}
                  onClick={() => setPage(p)}
                >
                  {t(
                    ("common:" +
                      (p === "applications" ? "apps" : p)) as "common:overview",
                  )}
                </button>
              ))}
            </nav>
            {metrics.connection === "offline" && (
              <p role="status" className="notice">
                {t("common:offline")}
              </p>
            )}
            {age > Math.max(15, (metrics.snapshot.samplingPolicy?.intervalMs ?? 10000) / 1000 * 2) && <p className="notice">{t("common:stale")}</p>}
            {page === "overview" ? (
              <Overview />
            ) : page === "applications" ? (
              <Applications />
            ) : page === "history" ? (
              <History />
            ) : (
              <section className="card">
                <h1>{t("common:settings")}</h1>
                <p>{t("settings:local")}</p>
                {storage && (
                  <p>
                    {t("settings:storage", {
                      size:
                        number(storage.diskBytes / 1048576, {
                          maximumFractionDigits: 1,
                        }) + " MiB",
                    })}
                  </p>
                )}
              </section>
            )}
          </>
        ) : status === "loading" ? (
          <p>{t("common:loading")}</p>
        ) : status === "offline" ? (
          <button onClick={() => void restore()}>{t("common:retry")}</button>
        ) : status === "pairingRequired" ||
          (pairTicket && status !== "loginRequired") ? (
          <Pairing
            ticket={pairTicket}
            onPaired={() => setStatus("loginRequired")}
          />
        ) : (
          <Authentication
            status={status}
            ticket={setupTicket}
            onLogin={() => {
              startConnection();
              setStatus("authenticated");
            }}
          />
        )}
        {error && <p role="alert">{errorMessage(error)}</p>}
      </main>
    </>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
