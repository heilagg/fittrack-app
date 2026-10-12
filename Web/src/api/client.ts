// Клиент `/v1` (SPEC §20.3; web-domain §3).
//
// Успех — голое тело без конверта, ветка успех/ошибка берётся из HTTP-статуса.
// Ошибка — `{error: {code, message, details}}`. Любое тело разбирается схемой на
// границе: неверная форма — `ContractError`, а не `as SomeType`.

import { z } from 'zod'
import {
  alternativesSchema,
  cycleCalendarSchema,
  errorEnvelopeSchema,
  finishWorkoutRequestSchema,
  finishWorkoutResponseSchema,
  exerciseContentListSchema,
  generateWeekPlanRequestSchema,
  logSetRequestSchema,
  logSetResponseSchema,
  patchProfileRequestSchema,
  profileSchema,
  rebuildWeekPlanRequestSchema,
  startWorkoutRequestSchema,
  substituteRequestSchema,
  todayCardSchema,
  weekPlanResponseSchema,
  workoutExerciseSchema,
  workoutSchema,
  type AlternativesPurpose,
  type CycleCalendar,
  type ExerciseAlternative,
  type ErrorCode,
  type FinishWorkoutResponse,
  type ExerciseContent,
  type GenerateWeekPlanRequest,
  type LogSetRequest,
  type LogSetResponse,
  type PatchProfileRequest,
  type Profile,
  type RebuildWeekPlanRequest,
  type StartWorkoutRequest,
  type SubstituteRequest,
  type TodayCard,
  type WeekPlanResponse,
  type Workout,
  type WorkoutExercise,
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

  /**
   * Профиль или `null`, если строки нет вовсе: сервер отвечает `not_found`, и
   * для онбординга это «не начат», а не ошибка (SPEC §5).
   */
  async getProfileIfStarted(): Promise<Profile | null> {
    try {
      return await this.getProfile()
    } catch (e) {
      if (e instanceof ApiError && e.code === 'not_found') return null
      throw e
    }
  }

  /** У `PATCH /v1/profile` нет `date`/`tz`: в профиле нет величин по дню. */
  patchProfile(body: PatchProfileRequest): Promise<Profile> {
    return this.request('PATCH', '/v1/profile', profileSchema, {
      authorized: true,
      body: patchProfileRequestSchema.parse(body),
    })
  }

  /**
   * Неделя с датами дней (§20.3) или `null`, если её ещё не генерировали
   * (`not_found`). Путь пишущий: он сверяет план со снимком, и `notice` в
   * ответе обязан быть показан — молчаливой пересборки нет (§7.1).
   */
  async getWeekPlan(weekStart: string): Promise<WeekPlanResponse | null> {
    const { date, tz } = this.today()
    const query = new URLSearchParams({ date, tz })
    try {
      return await this.request('GET', `/v1/week-plans/${encodeURIComponent(weekStart)}?${query}`,
        weekPlanResponseSchema, { authorized: true })
    } catch (e) {
      if (e instanceof ApiError && e.code === 'not_found') return null
      throw e
    }
  }

  /**
   * Пересборка текущей недели после прямой записи (§20.3, §20.6). `notice` в
   * ответе — «План обновлён» (§7.1), его обязаны показать. Недели ещё нет
   * (`not_found`) — пересобирать нечего, `null`.
   */
  async rebuildWeek(cause: RebuildWeekPlanRequest['cause']): Promise<WeekPlanResponse | null> {
    const { date, tz } = this.today()
    const path = `/v1/week-plans/${encodeURIComponent(mondayOf(date))}/rebuild`
    try {
      return await this.request('POST', path, weekPlanResponseSchema, {
        authorized: true,
        body: rebuildWeekPlanRequestSchema.parse({ cause, date, tz }),
      })
    } catch (e) {
      if (e instanceof ApiError && e.code === 'not_found') return null
      throw e
    }
  }

  /** Календарь цикла за `from…to` включительно, не больше 93 дней (§11.6, §20.3). */
  getCycleCalendar(from: string, to: string): Promise<CycleCalendar> {
    const { date, tz } = this.today()
    const query = new URLSearchParams({ date, tz, from, to })
    return this.request('GET', `/v1/cycle/calendar?${query}`, cycleCalendarSchema, { authorized: true })
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

  /**
   * Старт тренировки по дню плана. Идемпотентен по `planned_day_id`: первый
   * старт — 201, повтор — 200 и та же тренировка. Требует привязанного
   * аккаунта: иначе `unlinked_account` (403) — это экран линковки (§20.5).
   */
  startWorkout(plannedDayId: string, equipmentProfileId?: string): Promise<Workout> {
    const { date, tz } = this.today()
    const body: StartWorkoutRequest = {
      planned_day_id: plannedDayId,
      ...(equipmentProfileId ? { equipment_profile_id: equipmentProfileId } : {}),
      date,
      tz,
    }
    return this.request('POST', '/v1/workouts', workoutSchema, {
      authorized: true,
      body: startWorkoutRequestSchema.parse(body),
    })
  }

  /**
   * Логирует подход. Идемпотентен по `body.id` (upsert, §20.6, тест 20e):
   * повтор после обрыва уходит с ТЕМ ЖЕ `id` и не создаёт второй строки.
   * `date` и `tz` добавляются здесь, из того же единственного источника дня.
   */
  logSet(
    workoutId: string,
    exerciseId: string,
    body: Omit<LogSetRequest, 'date' | 'tz'>,
  ): Promise<LogSetResponse> {
    const { date, tz } = this.today()
    const path = `/v1/workouts/${encodeURIComponent(workoutId)}/exercises/${encodeURIComponent(exerciseId)}/sets`
    return this.request('POST', path, logSetResponseSchema, {
      authorized: true,
      body: logSetRequestSchema.parse({ ...body, date, tz }),
    })
  }

  /**
   * Закрывает тренировку. Повтор после обрыва — то же 200 и то же тело, но
   * `week.notice` в нём `null`: строку «План обновлён» показывает первый ответ.
   */
  finishWorkout(workoutId: string): Promise<FinishWorkoutResponse> {
    const { date, tz } = this.today()
    const path = `/v1/workouts/${encodeURIComponent(workoutId)}/finish`
    return this.request('POST', path, finishWorkoutResponseSchema, {
      authorized: true,
      body: finishWorkoutRequestSchema.parse({ date, tz }),
    })
  }

  /**
   * Альтернативы замены (§13.4). `purpose = pain` — ветка флага боли (§8.4
   * п.2): суставы сервер берёт из последнего подхода с флагом, клиент их не
   * присылает.
   */
  getAlternatives(workoutId: string, exerciseId: string, purpose: AlternativesPurpose): Promise<ExerciseAlternative[]> {
    const { date, tz } = this.today()
    const query = new URLSearchParams({ date, tz, purpose })
    const path = `/v1/workouts/${encodeURIComponent(workoutId)}/exercises/${encodeURIComponent(exerciseId)}/alternatives`
    return this.request('GET', `${path}?${query}`, alternativesSchema, { authorized: true })
  }

  /** Замена упражнения той же строки; повтор с тем же `to_slug` — 200 и то же тело (§20.3). */
  substitute(
    workoutId: string,
    exerciseId: string,
    toSlug: string,
    reason: SubstituteRequest['reason'],
  ): Promise<WorkoutExercise> {
    const { date, tz } = this.today()
    const path = `/v1/workouts/${encodeURIComponent(workoutId)}/exercises/${encodeURIComponent(exerciseId)}/substitute`
    return this.request('POST', path, workoutExerciseSchema, {
      authorized: true,
      body: substituteRequestSchema.parse({ to_slug: toSlug, reason, date, tz }),
    })
  }

  /**
   * План недели, срезанный по дате `day` (§20.3): проекция, путь ничего не
   * пишет. `date`/`tz` — «сегодня» клиента, `day` — день внутри недели.
   */
  getPreview(weekStart: string, day: string): Promise<WeekPlanResponse> {
    const { date, tz } = this.today()
    const query = new URLSearchParams({ date, tz, day })
    return this.request('GET', `/v1/week-plans/${encodeURIComponent(weekStart)}/preview?${query}`,
      weekPlanResponseSchema, { authorized: true })
  }

  getWorkout(id: string): Promise<Workout> {
    return this.request('GET', `/v1/workouts/${encodeURIComponent(id)}`, workoutSchema, {
      authorized: true,
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
