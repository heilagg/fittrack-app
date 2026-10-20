import '@testing-library/jest-dom/vitest'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
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

function mount(getProgress = vi.fn(async (): Promise<Progress> => progress)) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const api = {
    today: () => ({ date: '2026-10-19', tz: 'Europe/Moscow' }),
    getProgress,
    getExercises: async () => [{ slug: 'squat_barbell', name: 'Приседания со штангой', cues: [], common_errors: [],
      illustration: 'x', default_rest_seconds: 90, equipment_labels: [] }],
  } as unknown as ApiClient
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter><ProgressScreen api={api} /></MemoryRouter>
    </QueryClientProvider>,
  )
  return Object.assign(getProgress, { refetch: () => act(() => client.invalidateQueries({ queryKey: ['progress'] })) })
}

const cells = (group: Element, axis: string) =>
  [...group.querySelectorAll(`[data-testid="${axis}"] li`)].map((li) => li.textContent)

describe('экран «Прогресс» (§13.7)', () => {
  it('одно окно на 12 недель и месяц; по умолчанию 8 недель, переключатель 4/8/12', async () => {
    const getProgress = mount()
    await screen.findByTestId('volume-groups')
    expect(getProgress).toHaveBeenCalledWith('2026-08-03', '2026-10-19')
    const legs = screen.getByTestId('volume-groups').querySelector('[data-group="legs_glutes"]')!
    expect(legs.querySelectorAll('rect')).toHaveLength(8)
    expect(legs.querySelector('rect.chart-bar--partial')).toHaveAttribute('data-week', '2026-10-19')
    expect(legs).toHaveTextContent('норма 60, потолок 96')
    // Подпись группы — над своим графиком, затем значения, столбцы и недели.
    expect([...legs.children].map((c) => c.getAttribute('data-testid') ?? c.tagName.toLowerCase()))
      .toEqual(['group-label', 'bar-values', 'svg', 'week-labels'])
    expect(screen.getByTestId('volume-groups')).toHaveClass('rows--stacked')
    // Восемь недель: даты через одну от текущей, значения все.
    expect(cells(legs, 'week-labels')).toEqual(['', '07.09', '', '21.09', '', '05.10', '', '19.10'])
    expect(cells(legs, 'bar-values')).toEqual(['14', '15', '16', '17', '18', '19', '20', '21'])
    fireEvent.click(screen.getByRole('button', { name: '4 нед.' }))
    expect(legs.querySelectorAll('rect')).toHaveLength(4)
    expect(cells(legs, 'week-labels')).toEqual(['28.09', '05.10', '12.10', '19.10'])
    expect(cells(legs, 'bar-values')).toEqual(['18', '19', '20', '21'])
    expect(screen.getByRole('button', { name: '4 нед.' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: '8 нед.' })).toHaveAttribute('aria-pressed', 'false')
    // Двенадцать: клетка на неделю, подписи и значения через одну.
    fireEvent.click(screen.getByRole('button', { name: '12 нед.' }))
    expect(cells(legs, 'week-labels')).toHaveLength(12)
    expect(cells(legs, 'week-labels').filter(Boolean)).toEqual(['10.08', '24.08', '07.09', '21.09', '05.10', '19.10'])
    expect(cells(legs, 'bar-values').filter(Boolean)).toEqual(['11', '13', '15', '17', '19', '21'])
    // Три кнопки — в одном ряду с переносом, а не в двухколоночной сетке.
    expect(screen.getByRole('group', { name: 'Окно' })).toHaveClass('option-grid')
    expect(getProgress).toHaveBeenCalledTimes(1)
  })

  it('стрик, базовая линия с названием, фазы подписями с сервера', async () => {
    mount()
    expect(await screen.findByTestId('streak')).toHaveTextContent('3')
    expect(screen.getByTestId('baseline-select')).toHaveDisplayValue('Приседания со штангой')
    expect(screen.getByTestId('baseline-chart').querySelectorAll('circle')).toHaveLength(2)
    const strip = screen.getByTestId('phase-strip')
    expect(strip).toHaveTextContent('12 октября – 13 октября: После месячных')
    expect(strip).toHaveTextContent('15 октября: Середина цикла')
    expect(screen.getByTestId('baseline-chart').getAttribute('aria-label')).toBe('12 октября: 40 кг; 15 октября: 42.5 кг')
  })

  it('базовая линия: ряд из повторной загрузки показывается, выпавший выбор заменяется первым', async () => {
    const second = { ...progress, baselines: [{ slug: 'bench_press', points: [{ date: '2026-10-15', kg: 30 }] }, ...progress.baselines] }
    const getProgress = mount(vi.fn<() => Promise<Progress>>()
      .mockResolvedValueOnce({ ...progress, baselines: [] })
      .mockResolvedValueOnce(progress)
      .mockResolvedValueOnce(second)
      .mockResolvedValueOnce(second)
      .mockResolvedValue(progress))
    const options = () => [...screen.getByTestId('baseline-select').querySelectorAll('option')].map((o) => o.value)
    expect(await screen.findByTestId('baseline-empty')).toBeInTheDocument()
    await getProgress.refetch()
    expect(await screen.findByTestId('baseline-select')).toHaveValue('squat_barbell')
    await getProgress.refetch()
    await waitFor(() => expect(options()).toEqual(['bench_press', 'squat_barbell']))
    // Выбора не было — первый из пришедших.
    expect(screen.getByTestId('baseline-select')).toHaveValue('bench_press')
    fireEvent.change(screen.getByTestId('baseline-select'), { target: { value: 'squat_barbell' } })
    expect(screen.getByTestId('baseline-select')).toHaveValue('squat_barbell')
    expect(screen.getByTestId('baseline-chart').querySelectorAll('circle')).toHaveLength(2)
    // Выбранное пришло снова, но не первым — выбор держится.
    await getProgress.refetch()
    await waitFor(() => expect(getProgress).toHaveBeenCalledTimes(4))
    expect(screen.getByTestId('baseline-select')).toHaveValue('squat_barbell')
    fireEvent.change(screen.getByTestId('baseline-select'), { target: { value: 'bench_press' } })
    await getProgress.refetch()
    // Жима в окне больше нет — первый из пришедших, а не «упражнений нет».
    await waitFor(() => expect(options()).toEqual(['squat_barbell']))
    expect(screen.getByTestId('baseline-select')).toHaveValue('squat_barbell')
    expect(screen.queryByTestId('baseline-empty')).toBeNull()
  })

  it('у нового пользователя вместо шести нулевых графиков — пояснение', async () => {
    const zero = { legs_glutes: 0, back: 0, chest: 0, shoulders: 0, arms: 0, core: 0 }
    mount(vi.fn(async () => ({ ...progress, weeks: progress.weeks.map((w) => ({ ...w, groups: zero })) })))
    expect(await screen.findByTestId('volume-empty')).toHaveTextContent('калибровочные в него не входят')
    expect(screen.queryByTestId('volume-groups')).toBeNull()
  })

  it('один подход за окно — графики есть', async () => {
    const zero = { legs_glutes: 0, back: 0, chest: 0, shoulders: 0, arms: 0, core: 0 }
    mount(vi.fn(async () => ({ ...progress, weeks: progress.weeks.map((w, i) => ({ ...w, groups: i === 0 ? { ...zero, core: 1 } : zero })) })))
    expect(await screen.findByTestId('volume-groups')).toBeInTheDocument()
    expect(screen.queryByTestId('volume-empty')).toBeNull()
  })

  it('календарь месяца: силовая, растяжка, пропуск', async () => {
    mount()
    const calendar = await screen.findByTestId('activity-calendar')
    expect(calendar.querySelector('[data-date="2026-10-12"]')).toHaveAttribute('data-strength', 'true')
    expect(calendar.querySelector('[data-date="2026-10-13"]')).toHaveAttribute('data-stretch', 'true')
    expect(calendar.querySelector('[data-date="2026-10-14"]')).toHaveAttribute('data-skipped', 'true')
    const today = calendar.querySelector('[data-date="2026-10-19"]')!
    expect(today).toHaveClass('calendar-day--today')
    expect(today).toHaveAttribute('aria-current', 'date')
    expect(today).toHaveTextContent('19, сегодня')
    expect(calendar.querySelectorAll('[aria-current]')).toHaveLength(1)
    // Отметки и фаза — словами для диктора, буквы от него скрыты.
    const strength = calendar.querySelector('[data-date="2026-10-12"]')!
    expect(strength.textContent).toBe('12С, силовая, После месячных')
    expect(strength.querySelector('.calendar-mark')).toHaveAttribute('aria-hidden', 'true')
    expect(calendar.querySelector('[data-date="2026-10-13"]')!.textContent).toBe('13Р, растяжка или кардио, После месячных')
    expect(calendar.querySelector('[data-date="2026-10-14"]')!.textContent).toBe('14×, пропуск')
    expect(calendar.querySelector('[data-date="2026-10-16"]')!.textContent).toBe('16')
    // Фазы месяца — текстом под календарём.
    const phases = screen.getByTestId('calendar-phases')
    expect(within(phases).getAllByRole('listitem').map((li) => li.textContent))
      .toEqual(['12 октября – 13 октября: После месячных', '15 октября: Середина цикла'])
  })

  it('фазы под календарём — только этого месяца', async () => {
    mount(vi.fn(async () => ({ ...progress, days: [
      { date: '2026-09-30', strength: false, stretch: false, skipped: false, phase: 'luteal', phase_name: 'Перед месячными' },
      ...progress.days] })))
    const phases = await screen.findByTestId('calendar-phases')
    expect(phases).not.toHaveTextContent('Перед месячными')
    expect(screen.getByTestId('phase-strip')).toHaveTextContent('30 сентября: Перед месячными')
  })

  it('упражнений с весом нет — сказано прямо', async () => {
    mount(vi.fn(async () => ({ ...progress, baselines: [] })))
    expect(await screen.findByTestId('baseline-empty')).toBeInTheDocument()
  })
})
