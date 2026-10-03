import { useState, type FormEvent } from "react";
import { api, APIError } from "../store/api";
import { useI18n, errorMessage } from "../i18n";
export function Pairing({
  ticket,
  onPaired,
}: {
  ticket: string;
  onPaired: () => void;
}) {
  const { t } = useI18n(),
    [label, setLabel] = useState(""),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false);
  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      await api("/pairing/exchange", {
        method: "POST",
        body: JSON.stringify({ ticket, deviceLabel: label }),
      });
      onPaired();
    } catch (e) {
      setError(e instanceof APIError ? e.code : "serviceUnavailable");
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="card auth">
      <h1>{t("pairing:title")}</h1>
      <p>{t("pairing:trust")}</p>
      {ticket ? (
        <form onSubmit={submit}>
          <label>
            {t("pairing:label")}
            <input
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              maxLength={64}
              required
            />
          </label>
          <button disabled={busy}>{t("pairing:submit")}</button>
        </form>
      ) : (
        <p>{t("pairing:required")}</p>
      )}
      {error && <p role="alert">{errorMessage(error)}</p>}
    </section>
  );
}
