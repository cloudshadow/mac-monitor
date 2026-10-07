import { useSyncExternalStore } from "react";
import { APIError } from "../store/api";
import { errorMessage, useI18n } from "../i18n";

let code = "";
let timer: ReturnType<typeof setTimeout>;
const listeners = new Set<() => void>();
function dismiss() {
  clearTimeout(timer);
  code = "";
  listeners.forEach(fn => fn());
}
export function showError(error: unknown) {
  const next = error instanceof APIError ? error.code : typeof error === "string" ? error : "serviceUnavailable";
  if (code === next) return;
  clearTimeout(timer);
  code = next;
  listeners.forEach(fn => fn());
  timer = setTimeout(dismiss, 6000);
}
function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}
export function ErrorToast() {
  const { t } = useI18n();
  const error = useSyncExternalStore(subscribe, () => code);
  return error ? <div className="error-toast" role="alert" aria-atomic="true">
    <span>{errorMessage(error)}</span>
    <button aria-label={t("common:close")} onClick={dismiss}>×</button>
  </div> : null;
}
