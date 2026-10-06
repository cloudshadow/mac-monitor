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
import { Overview } from "./pages/Overview";
import { Applications } from "./pages/Applications";
import { History } from "./pages/History";
import "./style.css";
const fragment = new URLSearchParams(location.hash.slice(1)),
  setupTicket = fragment.get("setup") ?? "";
if (location.hash)
  history.replaceState(null, "", location.pathname + location.search);
function App() {
  const { t, language } = useI18n(),
    [status, setStatus] = useState("loading"),
    [page, setPage] = useState("overview"),
    [error, setError] = useState(""),
    [ready, setReady] = useState(false),
    [age, setAge] = useState(0),
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
    void selectLanguage(preferredLanguage(), ["auth"])
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
    void ensureNamespaces([ns, "auth", "settings"]).catch(() =>
      setError("serviceUnavailable"),
    );
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
  if (!ready) return <main>Mac Monitor…</main>;
  return (
    <>
      <header>
        <div className="brand-block">
          <a className="brand" href="/">
            <img className="brand-mark" src="/logo.png" alt="" />
            <span>{t("common:title")}</span>
          </a>
          <span className="version">v{__APP_VERSION__}</span>
        </div>

        {status === "authenticated" && (
            <nav>
              {(
                ["overview", "applications", "history"] as const
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
        )}
        <div className="header-actions">
        {status === "authenticated" && <span className={"connection-badge " + metrics.connection}><i />{metrics.connection === "connected" ? t("common:online") : t("common:loading")}</span>}
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
        </div>
      </header>
      <main className={status === "authenticated" && page === "overview" ? "overview-main" : undefined}>
        {status === "authenticated" ? (
          <>
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
            ) : (
              <History />
            )}
          </>
        ) : status === "loading" ? (
          <p>{t("common:loading")}</p>
        ) : status === "offline" ? (
          <button onClick={() => void restore()}>{t("common:retry")}</button>
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
