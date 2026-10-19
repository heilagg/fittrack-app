import '@testing-library/jest-dom/vitest'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { StretchContent, StretchHistory, StretchSession } from '../../api/schemas'
import { StretchPlayer } from './StretchPlayer'
import { StretchScreen } from './StretchScreen'

vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))
afterEach(cleanup)

const content: StretchContent = {
  poses: [
    { slug: 'pigeon_pose', name: 'Поза голубя', kind: 'static', unilateral: true, default_seconds: 45, cues: ['Таз ровно'], illustration: 'placeholder/stretch/pigeon_pose' },
    { slug: 'childs_pose', name: 'Поза ребёнка', kind: 'static', unilateral: false, default_seconds: 60, cues: [], illustration: 'catalog/exact/childs_pose' },
    { slug: 'jumping_jack', name: 'Джампинг-джек', kind: 'cardio', unilateral: false, default_seconds: 30, cues: [], illustration: 'placeholder/stretch/jumping_jack' },
  ],
  templates: [
    { slug: 'hip_opening', name: 'Раскрытие бёдер', purpose: 'Приводящие', duration_seconds: 80, minutes: 1,
      items: [{ pose: 'pigeon_pose', seconds: 30 }, { pose: 'childs_pose', seconds: 20 }] },
    { slug: 'cardio_intervals', name: 'Кардио', purpose: 'Интервалы', duration_seconds: 75, minutes: 1,
      items: [{ pose: 'jumping_jack', work_seconds: 30, rest_seconds: 15, rounds: 2 }] },
  ],
}

const session = (id: string, extra: Partial<StretchSession> = {}): StretchSession => ({
  id, kind: 'standalone', template_slug: 'hip_opening', performed_on: '2026-10-19', started_at: '2026-10-19T10:00:00Z', ...extra,
})

function mount(path: string, api: Partial<ApiClient>, now?: () => number, state?: unknown) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[{ pathname: path, state }]}>
        <Routes>
          <Route path="/stretch" element={<StretchScreen api={api as ApiClient} />} />
          <Route path="/stretch/play/:slug" element={<StretchPlayer api={api as ApiClient} now={now} />} />
          <Route path="/stretch/cooldown" element={<StretchPlayer api={api as ApiClient} now={now} />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('раздел «Растяжка» (§12.2, §13.1)', () => {
  it('шаблоны с минутами, предложенный отмечен; история — завершённые', async () => {
    const history: StretchHistory = {
      sessions: [session('s1', { finished_at: '2026-10-19T10:12:00Z', duration_seconds: 720 }),
        session('s2', { kind: 'static_cooldown', template_slug: undefined, finished_at: '2026-10-18T19:00:00Z', duration_seconds: 120 })],
      suggested_template: 'cardio_intervals',
    }
    mount('/stretch', { getStretchContent: async () => content, getStretchHistory: async () => history })
    const list = await screen.findByTestId('stretch-templates')
    expect(list.querySelector('[data-slug="cardio_intervals"]')).toHaveAttribute('data-suggested', 'true')
    expect(list.querySelector('[data-slug="hip_opening"]')).not.toHaveAttribute('data-suggested')
    expect(screen.getAllByTestId('suggested')).toHaveLength(1)
    expect(list).toHaveTextContent('1 мин · Приводящие')
    const items = screen.getByTestId('stretch-history').querySelectorAll('li')
    expect(items[0]).toHaveTextContent('Раскрытие бёдер')
    expect(items[0]).toHaveTextContent('12 мин')
    expect(items[1]).toHaveTextContent('Заминка')
  })

  it('пустая история — сказано прямо', async () => {
    mount('/stretch', { getStretchContent: async () => content, getStretchHistory: async () => ({ sessions: [], suggested_template: 'hip_opening' }) })
    expect(await screen.findByTestId('stretch-history-empty')).toBeInTheDocument()
  })
})

describe('проигрыватель (§12.2)', () => {
  let clock = 0
  const now = () => clock
  beforeEach(() => {
    clock = 1_000_000
    vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] })
  })
  afterEach(() => vi.useRealTimers())

  async function advance(seconds: number) {
    clock += seconds * 1000
    await act(async () => { vi.advanceTimersByTime(300) })
  }

  it('старт с клиентским id, стороны текстом, автопереход, +15 и пропуск, завершение', async () => {
    const start = vi.fn<ApiClient['startStretchSession']>(async (id) => session(id))
    const finish = vi.fn<ApiClient['finishStretchSession']>(async (id) => session(id, { finished_at: 'x' }))
    mount('/stretch/play/hip_opening', { getStretchContent: async () => content, startStretchSession: start, finishStretchSession: finish }, now)
    expect(await screen.findByTestId('stretch-pose')).toHaveTextContent('Поза голубя')
    await waitFor(() => expect(start).toHaveBeenCalledTimes(1))
    const [id, kind, template] = start.mock.calls[0]!
    expect([kind, template]).toEqual(['standalone', 'hip_opening'])
    expect(id).toMatch(/^[0-9a-f-]{36}$/)
    expect(screen.getByTestId('stretch-caption')).toHaveTextContent('Первая сторона')
    expect(screen.getByTestId('stretch-clock')).toHaveTextContent('0:30')

    await advance(30)
    expect(screen.getByTestId('stretch-caption')).toHaveTextContent('Смените сторону')
    fireEvent.click(screen.getByRole('button', { name: '+15 сек' }))
    await advance(1)
    expect(screen.getByTestId('stretch-clock')).toHaveTextContent('0:44')

    fireEvent.click(screen.getByRole('button', { name: 'Пропустить' }))
    expect(screen.getByTestId('stretch-pose')).toHaveTextContent('Поза ребёнка')
    expect(screen.queryByTestId('stretch-caption')).toBeNull()
    await advance(20)
    await waitFor(() => expect(finish).toHaveBeenCalledWith(id))
    expect(await screen.findByTestId('stretch-done')).toBeInTheDocument()
  })

  it('кардио — круги работы и отдыха', async () => {
    mount('/stretch/play/cardio_intervals', {
      getStretchContent: async () => content,
      startStretchSession: async (id: string) => session(id),
      finishStretchSession: async (id: string) => session(id),
    }, now)
    expect(await screen.findByTestId('stretch-caption')).toHaveTextContent('Работа · круг 1 из 2')
    await advance(30)
    expect(screen.getByTestId('stretch-caption')).toHaveTextContent('Отдых · круг 1 из 2')
    await advance(15)
    expect(screen.getByTestId('stretch-caption')).toHaveTextContent('Работа · круг 2 из 2')
  })

  it('заминка из ответа /finish: без шаблона, kind=static_cooldown', async () => {
    const start = vi.fn<ApiClient['startStretchSession']>(async (id) => session(id))
    mount('/stretch/cooldown', { getStretchContent: async () => content, startStretchSession: start,
      finishStretchSession: async (id: string) => session(id) }, now, { cooldown: [{ pose: 'childs_pose', seconds: 60 }] })
    expect(await screen.findByTestId('stretch-pose')).toHaveTextContent('Поза ребёнка')
    await waitFor(() => expect(start).toHaveBeenCalled())
    expect(start.mock.calls[0]!.slice(1)).toEqual(['static_cooldown', undefined])
  })

  it('обрыв старта — явное состояние, повтор с тем же id', async () => {
    const start = vi.fn<ApiClient['startStretchSession']>().mockRejectedValueOnce(new Error('сеть')).mockImplementation(async (id) => session(id))
    mount('/stretch/play/hip_opening', { getStretchContent: async () => content, startStretchSession: start,
      finishStretchSession: async (id: string) => session(id) }, now)
    expect(await screen.findByTestId('stretch-failure')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Повторить' }))
    await waitFor(() => expect(start).toHaveBeenCalledTimes(2))
    expect(start.mock.calls[1]![0]).toBe(start.mock.calls[0]![0])
  })
})
