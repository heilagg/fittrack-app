// Клиент `/v1` (SPEC §20.3; web-domain §3).
//
// Успех — голое тело без конверта, ветка успех/ошибка берётся из HTTP-статуса.
// Ошибка — `{error: {code, message, details}}`. Любое тело разбирается схемой на
// границе: неверная форма — `ContractError`, а не `as SomeType`.

import { z } from 'zod'
import {
  errorEnvelopeSchema,
  exerciseContentListSchema,
  generateWeekPlanRequestSchema,
  patchProfileRequestSchema,
  profileSchema,
  todayCardSchema,
  weekPlanResponseSchema,
  type ErrorCode,
  type ExerciseContent,
  type GenerateWeekPlanRequest,
  type PatchProfileRequest,
  type Profile,
  type TodayCard,
  type WeekPlanResponse,
} from './schemas'
import { currentDay, mondayOf, type DayContext } from './day'

/** Ответ сервера с кодом из закрытого словаря §20.3. */
export class ApiError extends Error {
  readonly status: number
  readonly code: ErrorCode
  /** Машинный и открытый; пользовательнице не показывается никогда. */
  readonly details: Record<string, string | number | boolean>

  constructor(status: number, code: ErrorCode, message: string, details: ApiError['details'] = {}) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = code
    this.details = details
  }
}

/** Тело не прошло схему: клиент и сервер разошлись в форме границы. */
export class ContractError extends Error {
  readonly path: string
  readonly status: number
  constructor(path: string, status: number, reason: string) {
    super(`Ответ ${path} (${status}) не соответствует контракту: ${reason}`)
    this.name = 'ContractError'
    this.path = path
    this.status = status
  }
}

/** Сеть недоступна. Очереди нет: повтор — это второе нажатие (§20.10). */
export class NetworkError extends Error {
  constructor(path: string, cause: unknown) {
    super(`Нет связи с сервером (${path})`, { cause })
    this.name = 'NetworkError'
  }
}

export interface ApiConfig {
  /** Токен текущей сессии; `null` — запрос уйдёт без заголовка. */
  getToken: () => Promise<string | null>
  fetch?: typeof fetch
  now?: () => Date
}

export class ApiClient {
  private readonly getToken: ApiConfig['getToken']
  private readonly doFetch: typeof fetch
  private readonly now: () => Date

  constructor(config: ApiConfig) {
    this.getToken = config.getToken
    this.doFetch = config.fetch ?? ((...args) => fetch(...args))
    this.now = config.now ?? (() => new Date())
  }

  /** «Сегодня» клиента — из `api/day.ts`, единственного источника пары. */
  today(): DayContext {
    return currentDay(this.now())
  }

  // MARK: - Пути

  getToday(): Promise<TodayCard> {
    const { date, tz } = this.today()
    const query = new URLSearchParams({ date, tz })
    return this.request('GET', `/v1/today?${query}`, todayCardSchema, { authorized: true })
  }

  getProfile(): Promise<Profile> {
    return this.request('GET', '/v1/profile', profileSchema, { authorized: true })
  }

  /** У `PATCH /v1/profile` нет `date`/`tz`: в профиле нет величин по дню. */
  patchProfile(body: PatchProfileRequest): Promise<Profile> {
    return this.request('PATCH', '/v1/profile', profileSchema, {
      authorized: true,
      body: patchProfileRequestSchema.parse(body),
    })
  }

  /** Идемпотентна по неделе: те же параметры — 200 и та же неделя. */
  generateWeek(weekStart?: string): Promise<WeekPlanResponse> {
    const { date, tz } = this.today()
    const body: GenerateWeekPlanRequest = { week_start: weekStart ?? mondayOf(date), date, tz }
    return this.request('POST', '/v1/week-plans', weekPlanResponseSchema, {
      authorized: true,
      body: generateWeekPlanRequestSchema.parse(body),
    })
  }

  /** Публичный путь: токен не шлётся, 401 на нём не бывает (§20.5). */
  getExercises(): Promise<ExerciseContent[]> {
    return this.request('GET', '/v1/content/exercises', exerciseContentListSchema, { authorized: false })
  }

  // MARK: - Ядро

  private async request<T extends z.ZodType>(
    method: string,
    path: string,
    schema: T,
    options: { authorized: boolean; body?: unknown },
  ): Promise<z.infer<T>> {
    const headers: Record<string, string> = { Accept: 'application/json' }
    if (options.body !== undefined) headers['Content-Type'] = 'application/json'
    if (options.authorized) {
      const token = await this.getToken()
      if (token) headers.Authorization = `Bearer ${token}`
    }

    let response: Response
    try {
      response = await this.doFetch(path, {
        method,
        headers,
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
      })
    } catch (cause) {
      throw new NetworkError(path, cause)
    }

    let payload: unknown
    try {
      payload = await response.json()
    } catch {
      throw new ContractError(path, response.status, 'тело не является JSON')
    }

    if (!response.ok) {
      const envelope = errorEnvelopeSchema.safeParse(payload)
      if (!envelope.success) {
        throw new ContractError(path, response.status, 'конверт ошибки не разобрался')
      }
      const { code, message, details } = envelope.data.error
      throw new ApiError(response.status, code, message, details)
    }

    const parsed = schema.safeParse(payload)
    if (!parsed.success) {
      throw new ContractError(path, response.status, parsed.error.issues[0]?.message ?? 'схема')
    }
    return parsed.data
  }
}
