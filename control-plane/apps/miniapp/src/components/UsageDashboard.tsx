// M5.13 UsageDashboard — per-tenant token usage from usage_records (metering
// Stop hook → audit-collector). Tokens only: the subscription is flat-rate, so
// there is no $ anywhere — this screen is fair-use visibility. Cache traffic
// dominates raw volume (~50-100k cache-read per turn vs hundreds in/out), so it
// gets its OWN chart with its own scale instead of being stacked with in+out.
// Charts are plain CSS flex bars — no chart library.

import { useEffect, useState } from "react";

import { usageSummary, type UsageDay, type UsageSummary } from "../api";
import { t } from "../i18n";

type Range = 7 | 30 | 90;

/** 1234567 → "1.2M", 68454 → "68k", 562 → "562". */
function fmt(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n >= 10_000_000 ? 0 : 1)}M`;
  if (n >= 1_000) return `${Math.round(n / 1_000)}k`;
  return String(n);
}

function sumDays(days: UsageDay[]): { inout: number; turns: number } {
  let inout = 0;
  let turns = 0;
  for (const d of days) {
    inout += d.in + d.out + d.legacy;
    turns += d.turns;
  }
  return { inout, turns };
}

export function UsageDashboard({ token, onClose }: { token: string; onClose: () => void }) {
  const [range, setRange] = useState<Range>(30);
  const [data, setData] = useState<UsageSummary | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setData(null);
    setError(null);
    usageSummary(token, range)
      .then(setData)
      .catch((e) => setError(e instanceof Error ? e.message : String(e)));
  }, [token, range]);

  const days = data?.days ?? [];
  const today = days.length > 0 ? days[days.length - 1] : null;
  const week = sumDays(days.slice(-7));
  const total = sumDays(days);
  const hasAny = total.turns > 0;

  const maxInOut = Math.max(1, ...days.map((d) => d.in + d.out + d.legacy));
  const maxCache = Math.max(1, ...days.map((d) => d.cacheRead + d.cacheWrite));
  // Label roughly every ~week so the axis stays readable on narrow screens.
  const labelEvery = days.length > 10 ? 7 : 2;

  const models = Object.entries(data?.byModel ?? {}).sort((a, b) => b[1].tokens - a[1].tokens);

  return (
    <div className="fileview">
      <div className="fileview-header">
        <button className="ghost" onClick={onClose}>
          ←
        </button>
        <span className="path">📊 {t("usage.title")}</span>
        <span className="usage-range">
          {([7, 30, 90] as Range[]).map((r) => (
            <button
              key={r}
              className={r === range ? "primary" : "ghost"}
              onClick={() => setRange(r)}
            >
              {t(`usage.range.${r}` as Parameters<typeof t>[0])}
            </button>
          ))}
        </span>
      </div>

      {error && <p className="error">{error}</p>}
      {!error && data === null && <p className="muted">{t("usage.loading")}</p>}

      {data !== null && !hasAny && <p className="muted">{t("usage.empty")}</p>}

      {data !== null && hasAny && (
        <div className="usage-body">
          <div className="usage-cards">
            <div className="usage-card">
              <div className="usage-card-value">{fmt(data.last5h.in + data.last5h.out)}</div>
              <div className="usage-card-label">{t("usage.last5h")}</div>
              <div className="usage-card-sub">
                {data.last5h.turns} {t("usage.turns")} · {t("usage.last5hHint")}
              </div>
            </div>
            <div className="usage-card">
              <div className="usage-card-value">{today ? fmt(today.in + today.out + today.legacy) : "0"}</div>
              <div className="usage-card-label">{t("usage.today")}</div>
              <div className="usage-card-sub">
                {today?.turns ?? 0} {t("usage.turns")}
              </div>
            </div>
            <div className="usage-card">
              <div className="usage-card-value">{fmt(week.inout)}</div>
              <div className="usage-card-label">{t("usage.week")}</div>
              <div className="usage-card-sub">
                {week.turns} {t("usage.turns")}
              </div>
            </div>
          </div>

          <h4 className="usage-section">{t("usage.chartTitle")}</h4>
          <div className="usage-chart">
            {days.map((d, i) => (
              <div key={d.date} className="usage-col" title={`${d.date}: ↑${fmt(d.in)} ↓${fmt(d.out)}${d.legacy ? ` +${fmt(d.legacy)}` : ""} · ${d.turns} ${t("usage.turns")}`}>
                <div className="usage-bar">
                  <div className="usage-seg usage-seg-legacy" style={{ height: `${(d.legacy / maxInOut) * 100}%` }} />
                  <div className="usage-seg usage-seg-out" style={{ height: `${(d.out / maxInOut) * 100}%` }} />
                  <div className="usage-seg usage-seg-in" style={{ height: `${(d.in / maxInOut) * 100}%` }} />
                </div>
                <div className="usage-x">{i % labelEvery === 0 ? d.date.slice(8) : " "}</div>
              </div>
            ))}
          </div>
          <div className="usage-legend">
            <span><i className="usage-dot usage-seg-in" /> {t("usage.in")}</span>
            <span><i className="usage-dot usage-seg-out" /> {t("usage.out")}</span>
            {days.some((d) => d.legacy > 0) && (
              <span><i className="usage-dot usage-seg-legacy" /> {t("usage.legacy")}</span>
            )}
          </div>

          <h4 className="usage-section">{t("usage.cacheChartTitle")}</h4>
          <div className="usage-chart usage-chart-cache">
            {days.map((d, i) => (
              <div key={d.date} className="usage-col" title={`${d.date}: r${fmt(d.cacheRead)} w${fmt(d.cacheWrite)}`}>
                <div className="usage-bar">
                  <div className="usage-seg usage-seg-cw" style={{ height: `${(d.cacheWrite / maxCache) * 100}%` }} />
                  <div className="usage-seg usage-seg-cr" style={{ height: `${(d.cacheRead / maxCache) * 100}%` }} />
                </div>
                <div className="usage-x">{i % labelEvery === 0 ? d.date.slice(8) : " "}</div>
              </div>
            ))}
          </div>
          <div className="usage-legend">
            <span><i className="usage-dot usage-seg-cr" /> {t("usage.cacheRead")}</span>
            <span><i className="usage-dot usage-seg-cw" /> {t("usage.cacheWrite")}</span>
          </div>

          <h4 className="usage-section">{t("usage.byModel")}</h4>
          <ul className="usage-models">
            {models.map(([m, v]) => (
              <li key={m}>
                <span className="usage-model-name">{m}</span>
                <span className="muted">
                  {fmt(v.tokens)} · {v.turns} {t("usage.turns")}
                </span>
              </li>
            ))}
          </ul>

          <p className="muted usage-note">{t("usage.flatNote")}</p>
        </div>
      )}
    </div>
  );
}
