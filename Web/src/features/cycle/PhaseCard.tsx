// Фаза сегодня с текстом «как можно себя чувствовать и почему» (SPEC §11.6,
// §11.7). Фаза и тексты — из ответа календаря на сегодняшний день: сервер
// уже свернул её в четыре и спрятал ниже порога 0.3; клиент только находит
// текст по значению. Тексты не меняются здесь: они ЖДУТ ЮРИСТА (§14.2) и
// живут в FitAPI.

import type { CycleCalendar } from '../../api/schemas'

export function PhaseCard({ calendar, today }: { calendar: CycleCalendar; today: string }) {
  const day = calendar.days.find((d) => d.date === today)
  if (!day?.phase) return null
  const text = calendar.phases.find((p) => p.phase === day.phase)
  if (!text) return null
  return (
    <section aria-label="Фаза цикла" className="card" data-testid="phase-card" data-phase={day.phase}>
      <div className="card-header">
        <h2 className="chip">{text.name}</h2>
      </div>
      <p data-testid="phase-feeling">{text.feeling}</p>
      <p className="caption" data-testid="phase-why">
        {text.why}
      </p>
      <p className="caption">{text.note}</p>
    </section>
  )
}
