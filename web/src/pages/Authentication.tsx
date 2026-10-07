import { showError } from "../components/ErrorToast";
import { useState, type FormEvent } from "react";
import { api, setCSRF } from "../store/api";
import { useI18n } from "../i18n";
export function Authentication({
  status,
  ticket,
  onLogin,
}: {
  status: string;
  ticket: string;
  onLogin: () => void;
}) {
  const { t } = useI18n(),
    [username, setUsername] = useState(""),
    [password, setPassword] = useState(""),
    [busy, setBusy] = useState(false);
  const setup = status === "setupRequired";
  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    try {
      const result = await api(setup ? "/auth/setup" : "/auth/login", {
        method: "POST",
        body: JSON.stringify({ username, password, setupTicket: ticket }),
      });
      setCSRF(result.csrfToken);
      setPassword("");
      onLogin();
    } catch (e) {
      showError(e);
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="auth card">
      <h1>{t(setup ? "auth:setup.title" : "auth:login.title")}</h1>
      {status === "returnToMac" ? (
        <p>{t("auth:setupRequired")}</p>
      ) : status === "recoveryRequired" ? (
        <p>{t("auth:recoveryRequired")}</p>
      ) : (
        <form onSubmit={submit}>
          <label>
            {t("auth:username")}
            <input
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              autoComplete="username"
              maxLength={64}
              required
            />
          </label>
          <label>
            {t("auth:password")}
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete={setup ? "new-password" : "current-password"}
              minLength={setup ? 12 : undefined}
              maxLength={128}
              required
            />
          </label>
          <button disabled={busy}>{t("auth:submit")}</button>
        </form>
      )}
    </section>
  );
}
