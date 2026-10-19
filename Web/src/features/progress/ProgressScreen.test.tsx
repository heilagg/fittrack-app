import '@testing-library/jest-dom/vitest'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { Progress } from '../../api/schemas'
import { ProgressScreen } from './ProgressScreen'

vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))
afterEach(cleanup)

const groups = (legs: number) => ({ legs_glutes: legs, back: 2, chest: 0, shoulders: 0, arms: 0, core: 0 })
const progress: Progress = {
  from: '2026-08-31', to: '2026-10-19',
  // Двенадцать недель: окно запроса всегда 12, а по умолчанию показано 8.
  weeks: Array.from({ length: 12 }, (_, i) => ({
    week_start: new Date(Date.UTC(2026, 7, 3 + 7 * i)).toISOString().slice(0, 10), partial: i === 11, groups: groups(10 + i),
  })),
  group_norms: [
    { group: 'legs_glutes', name: 'Ноги и ягодицы', norm: 60, ceiling: 96 },
    { group: 'back', name: 'Спина', norm: 40, ceiling: 64 },
    { group: 'chest', name: 'Грудь', norm: 10, ceiling: 16 },
    { group: 'shoulders', name: 'Плечи', norm: 30, ceiling: 48 },
    { group: 'arms', name: 'Руки', norm: 30, ceiling: 48 },
    { group: 'core', name: 'Кор', norm: 20, ceiling: 32 },
  ],
  baselines: [{ slug: 'squat_barbell', points: [{ date: '2026-10-12', kg: 40 }, { date: '2026-10-15', kg: 42.5 }] }],
  days: [
    { date: '2026-10-12', strength: true, stretch: false, skipped: false, phase: 'follicular', phase_name: 'После месячных' },
    { date: '2026-10-13', strength: false, stretch: true, skipped: false, phase: 'follicular', phase_name: 'После месячных' },
    { date: '2026-10-14', strength: false, stretch: false, skipped: true },
    { date: '2026-10-15', strength: true, stretch: false, skipped: false, phase: 'ovulatory', phase_name: 'Середина цикла' },
  ],
  streak_weeks: 3,
}

function mount(getProgress = vi.fn(async () => progress)) {
  const api = {
    today: () => ({ date: '2026-10-19', tz: 'Europe/Moscow' }),
    getProgress,
    getExercises: async () => [{ slug: 'squat_barbell', name: 'Приседания со штангой', cues: [], common_errors: [],
      illustration: 'x', default_rest_seconds: 90, equipment_labels: [] }],
  } as unknown as ApiClient
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter><ProgressScreen api={api} /></MemoryRouter>
    </QueryClientProvider>,
  )
  return getProgress
}

describe('экран «Прогресс» (§13.7)', () => {
  it('одно окно на 12 недель и месяц; по умолчанию 8 недель, переключатель 4/8/12', async () => {
    const getProgress = mount()
    await screen.findByTestId('volume-groups')
    expect(getProgress).toHaveBeenCalledWith('2026-08-03', '2026-10-19')
    const legs = screen.getByTestId('volume-groups').querySelector('[data-group="legs_glutes"]')!
    expect(legs.querySelectorAll('rect')).toHaveLength(8)
    expect(legs.querySelector('rect.chart-bar--partial')).toHaveAttribute('data-week', '2026-10-19')
    expect(legs).toHaveTextContent('норма 60, потолок 96')
    fireEvent.click(screen.getByRole('button', { name: '4 нед.' }))
    expect(legs.querySelectorAll('rect')).toHaveLength(4)
    expect(screen.getByRole('button', { name: '4 нед.' })).toHaveAttribute('aria-pressed', 'true')
    expect(getProgress).toHaveBeenCalledTimes(1)
  })

  it('стрик, базовая линия с названием, фазы подписями с сервера', async () => {
    mount()
    expect(await screen.findByTestId('streak')).toHaveTextContent('3')
    expect(screen.getByTestId('baseline-select')).toHaveDisplayValue('Приседания со штангой')
    expect(screen.getByTestId('baseline-chart').querySelectorAll('circle')).toHaveLength(2)
    const strip = screen.getByTestId('phase-strip')
    expect(strip).toHaveTextContent('2026-10-12 – 2026-10-13: После месячных')
    expect(strip).toHaveTextContent('2026-10-15: Середина цикла')
  })

  it('календарь месяца: силовая, растяжка, пропуск', async () => {
    mount()
    const calendar = await screen.findByTestId('activity-calendar')
    expect(calendar.querySelector('[data-date="2026-10-12"]')).toHaveAttribute('data-strength', 'true')
    expect(calendar.querySelector('[data-date="2026-10-13"]')).toHaveAttribute('data-stretch', 'true')
    expect(calendar.querySelector('[data-date="2026-10-14"]')).toHaveAttribute('data-skipped', 'true')
    expect(calendar.querySelector('[data-date="2026-10-19"]')).toHaveClass('calendar-day--today')
  })

  it('упражнений с весом нет — сказано прямо', async () => {
    mount(vi.fn(async () => ({ ...progress, baselines: [] })))
    expect(await screen.findByTestId('baseline-empty')).toBeInTheDocument()
  })
})
