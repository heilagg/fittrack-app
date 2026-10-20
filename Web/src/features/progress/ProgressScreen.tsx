// Экран «Прогресс» (SPEC §13.1, §13.7): объём по неделям и группам мышц с
// нормой и потолком, график базовой линии, календарь месяца со стриком,
// фазы цикла поверх графика и календаря. Всё считает сервер одним путём
// `/v1/progress`; здесь — только раскладка.
//
// Графики — SVG с `viewBox`: геометрия из данных, а цвет и размеры — классами
// из токенов (web-domain §8). Новых цветов нет: фаза подписывается текстом.

import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import type { ApiClient } from '../../api/client'
import type { Progress } from '../../api/schemas'
import { useExerciseNames } from '../../content/useExercises'
import { DEFAULT_WEEKS, lastWeeks, monthGrid, progressWindow, scaleTop, WEEK_WINDOWS, type WeekWindow } from '../../progress/view'
import { ErrorBlock } from '../today/TodayScreen'

export function ProgressScreen({ api }: { api: ApiClient }) {
  const [weeks, setWeeks] = useState<WeekWindow>(DEFAULT_WEEKS)
  const today = api.today().date
  const window = progressWindow(today, 12)
  const progress = useQuery({ queryKey: ['progress', window.from, window.to], queryFn: () => api.getProgress(window.from, window.to) })
  const names = useExerciseNames(api)

  if (progress.isPending) return <p role="status">Загрузка…</p>
  if (progress.isError) return <ErrorBlock error={progress.error} />
  const data = progress.data

  return (
    <main>
      <header className="screen-header">
        <h1>Прогресс</h1>
      </header>
      <p className="chip" data-testid="streak">
        Недель подряд с активностью: {data.streak_weeks}
      </p>
      <section aria-label="Объём по неделям" className="card">
        <h2 className="section-title">Объём по неделям</h2>
        <div className="option-row" role="group" aria-label="Окно">
          {WEEK_WINDOWS.map((w) => (
            <button key={w} type="button" className="chip" aria-pressed={w === weeks} onClick={() => setWeeks(w)}>
              {w} нед.
            </button>
          ))}
        </div>
        <VolumeChart data={data} weeks={weeks} />
      </section>
      <section aria-label="Базовая линия" className="card">
        <h2 className="section-title">Базовая линия</h2>
        <BaselineChart data={data} names={names.data} />
      </section>
      <section aria-label="Календарь активности" className="card">
        <h2 className="section-title">Календарь</h2>
        <Calendar data={data} today={today} />
      </section>
    </main>
  )
}

function VolumeChart({ data, weeks }: { data: Progress; weeks: WeekWindow }) {
  const shown = lastWeeks(data.weeks, weeks)
  return (
    // `rows--stacked` — на списке: правило стека действует на его `li`, и
    // подпись группы стоит над своим графиком, а не сбоку от него.
    <ul className="rows rows--stacked" data-testid="volume-groups">
      {data.group_norms.map((g) => {
        const values = shown.map((w) => w.groups[g.group] ?? 0)
        const top = scaleTop(values, [g.ceiling])
        const width = 100 / Math.max(1, shown.length)
        return (
          <li key={g.group} data-group={g.group}>
            <span data-testid="group-label">
              {g.name} <span className="caption">норма {g.norm}, потолок {g.ceiling}</span>
            </span>
            {/* Значения и недели — текстом над и под столбцами, а не внутри SVG:
                там шрифт масштабировался бы вместе с viewBox. */}
            <ol className="chart-axis caption" aria-hidden="true" data-testid="bar-values">
              {values.map((v, i) => (
                <li key={shown[i]!.week_start}>{formatSets(v)}</li>
              ))}
            </ol>
            <svg viewBox="0 0 100 40" className="chart" role="img"
              aria-label={`${g.name}: ${values.map((v) => v.toFixed(1)).join(', ')} эффективных подходов по неделям`}>
              {shown.map((w, i) => {
                const v = w.groups[g.group] ?? 0
                const h = (v / top) * 40
                return (
                  <rect key={w.week_start} x={i * width + width * 0.15} y={40 - h} width={width * 0.7} height={h}
                    className={w.partial ? 'chart-bar chart-bar--partial' : 'chart-bar'} data-week={w.week_start} />
                )
              })}
              <line x1="0" x2="100" y1={40 - (g.norm / top) * 40} y2={40 - (g.norm / top) * 40} className="chart-norm" />
              <line x1="0" x2="100" y1={40 - (g.ceiling / top) * 40} y2={40 - (g.ceiling / top) * 40} className="chart-ceiling" />
            </svg>
            <ol className="chart-axis caption" aria-hidden="true" data-testid="week-labels">
              {shown.map((w) => (
                <li key={w.week_start}>{weekLabel(w.week_start)}</li>
              ))}
            </ol>
          </li>
        )
      })}
      <li className="caption">Текущая неделя — неполная. Линии: норма и потолок недели.</li>
    </ul>
  )
}

/** Эффективные подходы: целое — без дробной части, иначе одна цифра после запятой. */
function formatSets(value: number): string {
  const rounded = Math.round(value * 10) / 10
  return Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(1).replace('.', ',')
}

/** Подпись недели — день и месяц её понедельника: «12.10». */
function weekLabel(weekStart: string): string {
  return `${weekStart.slice(8, 10)}.${weekStart.slice(5, 7)}`
}

function BaselineChart({ data, names }: { data: Progress; names: Map<string, { name: string }> | undefined }) {
  const [slug, setSlug] = useState(data.baselines[0]?.slug)
  const series = data.baselines.find((b) => b.slug === slug)
  if (data.baselines.length === 0 || !series) {
    return <p className="caption" data-testid="baseline-empty">Упражнений с весом за это время нет.</p>
  }
  const days = data.days.map((d) => d.date)
  const index = (date: string) => Math.max(0, days.indexOf(date))
  const span = Math.max(1, days.length - 1)
  const kgs = series.points.map((p) => p.kg)
  const lo = Math.min(...kgs)
  const hi = Math.max(...kgs)
  const y = (kg: number) => (hi === lo ? 20 : 36 - ((kg - lo) / (hi - lo)) * 32)
  const phases = phaseRuns(data.days)
  return (
    <>
      <label className="field">
        Упражнение{' '}
        <select value={slug} onChange={(e) => setSlug(e.target.value)} data-testid="baseline-select">
          {data.baselines.map((b) => (
            <option key={b.slug} value={b.slug}>
              {names?.get(b.slug)?.name ?? b.slug}
            </option>
          ))}
        </select>
      </label>
      <svg viewBox="0 0 100 40" className="chart" role="img" data-testid="baseline-chart"
        aria-label={series.points.map((p) => `${p.date}: ${p.kg} кг`).join('; ')}>
        <polyline className="chart-line" fill="none"
          points={series.points.map((p) => `${(index(p.date) / span) * 100},${y(p.kg)}`).join(' ')} />
        {series.points.map((p) => (
          <circle key={p.date} cx={(index(p.date) / span) * 100} cy={y(p.kg)} r="1.2" className="chart-point" />
        ))}
      </svg>
      <p className="caption">
        {lo} – {hi} кг
      </p>
      {phases.length > 0 && (
        <ul className="caption phase-strip" data-testid="phase-strip" aria-label="Фазы цикла">
          {phases.map((run) => (
            <li key={run.from}>
              {run.from === run.to ? run.from : `${run.from} – ${run.to}`}: {run.name}
            </li>
          ))}
        </ul>
      )}
    </>
  )
}

/** Подряд идущие дни одной фазы — подписи под графиком. */
function phaseRuns(days: Progress['days']): { from: string; to: string; name: string }[] {
  const runs: { from: string; to: string; name: string; phase: string }[] = []
  for (const d of days) {
    if (!d.phase || !d.phase_name) continue
    const last = runs.at(-1)
    if (last && last.phase === d.phase) last.to = d.date
    else runs.push({ from: d.date, to: d.date, name: d.phase_name, phase: d.phase })
  }
  return runs
}

function Calendar({ data, today }: { data: Progress; today: string }) {
  const byDate = new Map(data.days.map((d) => [d.date, d]))
  return (
    <>
      <table className="calendar" data-testid="activity-calendar">
        <thead>
          <tr>
            {['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'].map((d) => (
              <th key={d} scope="col" className="caption">{d}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {monthGrid(today).map((row, i) => (
            <tr key={i}>
              {row.map((date, j) => {
                const day = date ? byDate.get(date) : undefined
                const marks = [day?.strength ? 'С' : '', day?.stretch ? 'Р' : '', day?.skipped ? '×' : ''].join('')
                return (
                  <td key={j} data-date={date ?? undefined}
                    data-strength={day?.strength || undefined} data-stretch={day?.stretch || undefined}
                    data-skipped={day?.skipped || undefined}
                    title={day?.phase_name}
                    className={date === today ? 'calendar-day calendar-day--today' : 'calendar-day'}>
                    {date ? Number(date.slice(8)) : ''}
                    {marks && <span className="caption calendar-mark">{marks}</span>}
                  </td>
                )
              })}
            </tr>
          ))}
        </tbody>
      </table>
      <p className="caption">С — силовая, Р — растяжка или кардио, × — пропуск.</p>
    </>
  )
}
