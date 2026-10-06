import { useEffect, useRef, useState } from "react";
import { useI18n, errorMessage } from "../i18n";
import { useMetrics } from "../store/metrics";
import { api, APIError } from "../store/api";
export function Applications() {
  const { t, number } = useI18n(),
    { appsSequence } = useMetrics(),
    [sort, setSort] = useState("cpu"),
    [query, setQuery] = useState(""),
    [cursor, setCursor] = useState<string | undefined>(),
    [table, setTable] = useState<Record<string, any>>({ rows: [] }),
    [error, setError] = useState(""),
    [members, setMembers] = useState<Record<string, any> | undefined>(),
    inflight = useRef(false),
    latest = useRef<(() => void) | undefined>(undefined),
    revision = useRef(0);
  useEffect(() => {
    const id = ++revision.current;
    let alive = true;
    const load = () => {
      if (inflight.current) {
        latest.current = load;
        return;
      }
      inflight.current = true;
      const params = new URLSearchParams({ sort, q: query, limit: "20" });
      if (cursor) params.set("cursor", cursor);
      void api("/apps?" + params)
        .catch((e) => {
          if (e instanceof APIError && e.status === 409 && !cursor)
            return api("/apps?" + params);
          throw e;
        })
        .then((result) => {
          if (alive && id === revision.current) {
            setTable(result);
            setError("");
          }
        })
        .catch((e) => {
          if (alive)
            setError(e instanceof APIError ? e.code : "serviceUnavailable");
        })
        .finally(() => {
          inflight.current = false;
          const next = latest.current;
          latest.current = undefined;
          next?.();
        });
    };
    const timer = setTimeout(load, query ? 250 : 0);
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [sort, query, cursor, cursor ? "" : appsSequence]);
  async function expand(id: string, cursor?: string) {
    try {
      setMembers({
        ...(await api(
          "/apps/" +
            id +
            "/processes" +
            (cursor ? "?cursor=" + encodeURIComponent(cursor) : ""),
        )),
        appId: id,
      });
    } catch (e) {
      setError(e instanceof APIError ? e.code : "serviceUnavailable");
    }
  }
  return (
    <section className="card">
      <div className="toolbar">
        <input
          aria-label={t("apps:search")}
          placeholder={t("apps:search")}
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setCursor(undefined);
          }}
        />
        <select
          value={sort}
          onChange={(e) => {
            setSort(e.target.value);
            setCursor(undefined);
          }}
        >
          {(["cpu", "memory", "diskRead", "diskWrite"] as const).map((s) => (
            <option key={s} value={s}>
              {t(("apps:" + s) as "apps:cpu")}
            </option>
          ))}
        </select>
        <button
          onClick={() => {
            setCursor(undefined);
            setQuery("");
          }}
        >
          {t("common:retry")}
        </button>
      </div>
      {table.coverage && (
        <p>
          {t("apps:coverage", {
            readable: number(table.coverage.readable),
            attempted: number(table.coverage.attempted),
          })}
        </p>
      )}
      {cursor && appsSequence !== table.scanSequence && (
        <p>{t("apps:newScan")}</p>
      )}
      <div className="table-scroll" tabIndex={0} role="region" aria-label={t("common:apps")}>
        <table>
          <thead>
            <tr>
              <th>{t("common:apps")}</th>
              <th>{t("apps:cpu")}</th>
              <th>{t("apps:memory")}</th>
              <th>{t("apps:diskRead")}</th>
              <th>{t("apps:diskWrite")}</th>
            </tr>
          </thead>
          <tbody>
            {table.rows.map((row: Record<string, any>) => (
              <tr key={row.id}>
                <td>
                  <button className="link" onClick={() => void expand(row.id)}>
                    {row.name}
                  </button>
                </td>
                {[
                  "cpuPercentCore",
                  "physicalFootprintBytes",
                  "diskReadBytesPerSecond",
                  "diskWriteBytesPerSecond",
                ].map((field, i) => (
                  <td key={field}>
                    {typeof row[field] === "number"
                      ? number(i === 0 ? row[field] : row[field] / 1048576, {
                          maximumFractionDigits: 2,
                        }) + (i === 0 ? " %" : " MiB" + (i > 1 ? "/s" : ""))
                      : t("common:unknown")}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="toolbar">
        {cursor && (
          <button onClick={() => setCursor(undefined)}>
            {t("common:back")}
          </button>
        )}
        {table.nextCursor && (
          <button onClick={() => setCursor(table.nextCursor)}>
            {t("common:next")}
          </button>
        )}
      </div>
      {members && (
        <details open>
          <summary>
            {t("apps:members")}{" "}
            <button onClick={() => setMembers(undefined)}>×</button>
          </summary>
          {members.rows.map((row: Record<string, any>) => (
            <p key={row.processKey}>
              {row.name} · PID {row.pid} ·{" "}
              {typeof row.cpuPercentCore === "number"
                ? number(row.cpuPercentCore, { maximumFractionDigits: 1 }) +
                  " %"
                : t("common:unknown")}
            </p>
          ))}
          {members.nextCursor && (
            <button
              onClick={() => void expand(members.appId, members.nextCursor)}
            >
              {t("common:next")}
            </button>
          )}
        </details>
      )}
      {error && <p role="alert">{errorMessage(error)}</p>}
    </section>
  );
}
