import { describe, expect, it, vi } from 'vitest'
import { ApiClient, ApiError, ContractError, NetworkError } from './client'

const card = {
  date: '2026-10-12',
  readiness: 1,
  cycle: { phase_mode: 'no_phases', has_anchor: false },
  day: { kind: 'not_built', loses_planned_volume: false },
  reasons: [],
}

function client(fetchImpl: typeof fetch, token: string | null = 'jwt', now = new Date('2026-10-12T21:30:00Z')) {
  return new ApiClient({ getToken: async () => token, fetch: fetchImpl, now: () => now })
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status })

describe('ApiClient', () => {
  it('GET /v1/today шлёт date и tz в query и токен в Authorization', async () => {
    const fetchMock = vi.fn(async () => json(card))
    await client(fetchMock as unknown as typeof fetch).getToday()

    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    const query = new URL(url, 'http://x').searchParams
    expect(new URL(url, 'http://x').pathname).toBe('/v1/today')
    expect(query.get('date')).toMatch(/^\d{4}-\d{2}-\d{2}$/)
    expect(query.get('tz')).toBeTruthy()
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer jwt')
  })

  it('content-путь публичный: токен не шлётся', async () => {
    const fetchMock = vi.fn(async () => json([]))
    await client(fetchMock as unknown as typeof fetch).getExercises()
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect((init.headers as Record<string, string>).Authorization).toBeUndefined()
  })

  it('PATCH /v1/profile не несёт date и tz', async () => {
    const fetchMock = vi.fn(async () =>
      json({ session_minutes: 60, cycle_tracking: 'off', is_complete: false }),
    )
    await client(fetchMock as unknown as typeof fetch).patchProfile({ goal: 'strength' })
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect(JSON.parse(String(init.body))).toEqual({ goal: 'strength' })
  })

  it('POST /v1/week-plans: понедельник вычисляется из той же даты, что уходит в теле', async () => {
    const fetchMock = vi.fn(async () => json({ plan: { days: [], status_lines: [] } }, 201))
    // 2026-10-14 — среда: понедельник той недели 2026-10-12.
    const c = client(fetchMock as unknown as typeof fetch, 'jwt', new Date('2026-10-14T09:00:00Z'))
    await c.generateWeek()
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    const body = JSON.parse(String(init.body)) as { week_start: string; date: string }
    expect(body.week_start).toBe('2026-10-12')
    expect(body.date >= body.week_start).toBe(true)
  })

  it('ответ с кодом ошибки становится ApiError с code и details', async () => {
    const fetchMock = vi.fn(async () =>
      json({ error: { code: 'profile_incomplete', message: 'Профиль не заполнен', details: { missing: 'goal' } } }, 409),
    )
    const error = await client(fetchMock as unknown as typeof fetch).getToday().catch((e: unknown) => e)
    expect(error).toBeInstanceOf(ApiError)
    expect((error as ApiError).code).toBe('profile_incomplete')
    expect((error as ApiError).status).toBe(409)
    expect((error as ApiError).details.missing).toBe('goal')
  })

  it('тело не по схеме — ContractError, а не молчаливый undefined', async () => {
    const fetchMock = vi.fn(async () => json({ date: '2026-10-12' }))
    const error = await client(fetchMock as unknown as typeof fetch).getToday().catch((e: unknown) => e)
    expect(error).toBeInstanceOf(ContractError)
  })

  it('неизвестный kind дня — ContractError', async () => {
    const fetchMock = vi.fn(async () => json({ ...card, day: { kind: 'party', loses_planned_volume: false } }))
    const error = await client(fetchMock as unknown as typeof fetch).getToday().catch((e: unknown) => e)
    expect(error).toBeInstanceOf(ContractError)
  })

  it('обрыв сети — NetworkError, и автоматического повтора нет', async () => {
    const fetchMock = vi.fn(async () => {
      throw new TypeError('network')
    })
    const error = await client(fetchMock as unknown as typeof fetch).getToday().catch((e: unknown) => e)
    expect(error).toBeInstanceOf(NetworkError)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('POST /v1/workouts: planned_day_id, date, tz и токен; без инвентаря ключа нет', async () => {
    const workout = {
      id: 'w1',
      session_kind: 'lower',
      started_at: '2026-10-12T09:30:00Z',
      readiness: 1,
      is_calibration: false,
      exercises: [],
    }
    const fetchMock = vi.fn(async () => json(workout, 201))
    await client(fetchMock as unknown as typeof fetch).startWorkout('day-1')
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('/v1/workouts')
    expect(init.method).toBe('POST')
    const body = JSON.parse(String(init.body)) as Record<string, string>
    expect(body.planned_day_id).toBe('day-1')
    expect(body.date).toMatch(/^\d{4}-\d{2}-\d{2}$/)
    expect(body.tz).toBeTruthy()
    expect('equipment_profile_id' in body).toBe(false)
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer jwt')
  })

  it('unlinked_account приезжает как ApiError с кодом и статусом 403', async () => {
    const fetchMock = vi.fn(async () =>
      json({ error: { code: 'unlinked_account', message: 'Привяжите аккаунт' } }, 403),
    )
    const error = await client(fetchMock as unknown as typeof fetch).startWorkout('d').catch((e: unknown) => e)
    expect(error).toBeInstanceOf(ApiError)
    expect((error as ApiError).code).toBe('unlinked_account')
    expect((error as ApiError).status).toBe(403)
  })

  it('GET /v1/workouts/{id}: идентификатор экранируется в пути', async () => {
    const fetchMock = vi.fn(async () =>
      json({ id: 'a b', session_kind: 'upper', started_at: 'x', readiness: 1, is_calibration: false, exercises: [] }),
    )
    await client(fetchMock as unknown as typeof fetch).getWorkout('a b')
    expect((fetchMock.mock.calls[0] as unknown as [string])[0]).toBe('/v1/workouts/a%20b')
  })
})
