// Контрактные тесты: эталонные JSON из `Contract/fixtures/` против схем `api/`.
//
// Файлы выгружает Swift-тест `ContractFixturesTests` из DTO пакета `FitAPI`.
// Здесь они читаются теми же руками написанными схемами, которыми клиент
// разбирает живые ответы (SPEC §20.2; web-domain §5).

import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { ZodType } from 'zod'
import {
  errorEnvelopeSchema,
  exerciseContentListSchema,
  generateWeekPlanRequestSchema,
  patchProfileRequestSchema,
  profileSchema,
  startWorkoutRequestSchema,
  todayCardSchema,
  weekPlanResponseSchema,
  workoutSchema,
} from './schemas'
import { ApiClient } from './client'

const dir = join(__dirname, '../../../Contract/fixtures')
const load = (name: string): unknown => JSON.parse(readFileSync(join(dir, name), 'utf-8'))

/** Какая схема читает какой эталон. Файл без записи здесь — провал теста. */
const schemaFor: Record<string, ZodType> = {
  'today_not_built.json': todayCardSchema,
  'today_session.json': todayCardSchema,
  'today_not_a_training_day.json': todayCardSchema,
  'profile_incomplete.json': profileSchema,
  'profile_complete.json': profileSchema,
  'week_plan_response.json': weekPlanResponseSchema,
  'content_exercises.json': exerciseContentListSchema,
  'workout_started.json': workoutSchema,
  'workout_in_progress.json': workoutSchema,
  'error_unlinked_account.json': errorEnvelopeSchema,
  'error_day_not_planned.json': errorEnvelopeSchema,
  'request_start_workout.json': startWorkoutRequestSchema,
  'error_profile_incomplete.json': errorEnvelopeSchema,
  'error_unauthorized.json': errorEnvelopeSchema,
  'error_date_skew.json': errorEnvelopeSchema,
  'request_patch_profile.json': patchProfileRequestSchema,
  'request_generate_week_plan.json': generateWeekPlanRequestSchema,
}

describe('эталонные JSON границы /v1', () => {
  it('каждый файл в Contract/fixtures/ имеет схему, и наоборот', () => {
    const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
    expect(files).toEqual(Object.keys(schemaFor).sort())
  })

  for (const [name, schema] of Object.entries(schemaFor)) {
    it(`${name} проходит схему и ничего не теряет`, () => {
      const json = load(name)
      const parsed = schema.parse(json)
      // Схема по умолчанию молча отбрасывает неизвестные ключи; равенство
      // исходному значению означает, что в эталоне нет поля, которого нет в типе.
      expect(parsed).toEqual(json)
    })
  }

  it('карточка без недели: ключа day_id нет, и cause отсутствует', () => {
    const card = todayCardSchema.parse(load('today_not_built.json'))
    expect(card.day.kind).toBe('not_built')
    expect(card.day.day_id).toBeUndefined()
    expect(card.day.cause).toBeUndefined()
    expect(card.day.session).toBeUndefined()
  })

  it('день отдыха отличается от несгенерированной недели причиной', () => {
    const rest = todayCardSchema.parse(load('today_not_a_training_day.json'))
    expect(rest.day.cause?.code).toBe('not_a_training_day')
  })

  it('упражнение без веса приезжает без prescribed_kg', () => {
    const card = todayCardSchema.parse(load('today_session.json'))
    const [barbell, bodyweight] = card.day.session!.exercises
    expect(barbell!.prescribed_kg).toBe(40)
    expect(bodyweight!.prescribed_kg).toBeUndefined()
  })

  it('конверт ошибки несёт код из закрытого словаря и details', () => {
    const envelope = errorEnvelopeSchema.parse(load('error_profile_incomplete.json'))
    expect(envelope.error.code).toBe('profile_incomplete')
    expect(envelope.error.details?.missing).toBe('experience_level,equipment_profile')
  })

  it('неизвестный код ошибки не проходит схему', () => {
    const json = load('error_unauthorized.json') as { error: { code: string } }
    json.error.code = 'teapot'
    expect(() => errorEnvelopeSchema.parse(json)).toThrow()
  })
})

describe('тренировка (срез 2)', () => {
  it('карта дерева: упражнение без веса — без weight_kg, с завершающим узлом', () => {
    const workout = workoutSchema.parse(load('workout_started.json'))
    const [weighted, bodyweight] = workout.exercises
    expect(weighted!.decision_tree!.nodes.n0!.weight_kg).toBe(40)
    expect(weighted!.decision_tree!.nodes.n2!.truncated).toBe(true)
    const tree = bodyweight!.decision_tree!
    expect(Object.values(tree.nodes).every((n) => n.weight_kg === undefined)).toBe(true)
    expect(Object.values(tree.nodes).some((n) => n.terminates)).toBe(true)
  })

  it('подход несёт слаг упражнения и все обязательные ключи', () => {
    const workout = workoutSchema.parse(load('workout_in_progress.json'))
    const set = workout.exercises[0]!.sets[0]!
    expect(set.exercise_slug).toBe('pushup_bw')
    expect(set.pain_flag).toBe(false)
    expect(set.pain_joints).toEqual([])
    expect(set.skipped).toBe(false)
    expect(set.feedback).toBe('ok')
  })

  it('идущая тренировка не завершена, у начатой нет подходов', () => {
    const started = workoutSchema.parse(load('workout_started.json'))
    expect(started.finished_at).toBeUndefined()
    expect(started.exercises.every((e) => e.sets.length === 0)).toBe(true)
  })

  it('day_not_planned несёт id идущей тренировки в details', () => {
    const envelope = errorEnvelopeSchema.parse(load('error_day_not_planned.json'))
    expect(envelope.error.code).toBe('day_not_planned')
    expect(typeof envelope.error.details?.workout_id).toBe('string')
  })

  it('unlinked_account — код из словаря без details', () => {
    const envelope = errorEnvelopeSchema.parse(load('error_unlinked_account.json'))
    expect(envelope.error.code).toBe('unlinked_account')
    expect(envelope.error.details).toBeUndefined()
  })
})

describe('тела запросов клиента совпадают с эталонами', () => {
  it('startWorkout шлёт planned_day_id, date и tz — те же ключи, что эталон', async () => {
    const sent: unknown[] = []
    const api = new ApiClient({
      getToken: async () => 't',
      fetch: async (_url, init) => {
        sent.push(JSON.parse(String(init?.body)))
        return new Response(JSON.stringify(load('workout_started.json')), { status: 201 })
      },
    })
    const fixture = load('request_start_workout.json') as Record<string, string>
    await api.startWorkout(fixture.planned_day_id!)
    const body = sent[0] as Record<string, string>
    expect(Object.keys(body).sort()).toEqual(Object.keys(fixture).sort())
    expect(body.planned_day_id).toBe(fixture.planned_day_id)
  })

  it('generateWeek шлёт week_start, date и tz — как эталон', async () => {
    const sent: unknown[] = []
    const api = new ApiClient({
      getToken: async () => 't',
      now: () => new Date('2026-10-12T09:00:00Z'),
      fetch: async (_url, init) => {
        sent.push(JSON.parse(String(init?.body)))
        return new Response(JSON.stringify(load('week_plan_response.json')), { status: 201 })
      },
    })
    // Зона фиксируется заменой часов браузера недоступна, поэтому сверяем ключи
    // и вид значений, а не конкретную дату из эталона.
    await api.generateWeek('2026-10-12')
    const body = sent[0] as Record<string, string>
    const fixture = load('request_generate_week_plan.json') as Record<string, string>
    expect(Object.keys(body).sort()).toEqual(Object.keys(fixture).sort())
    expect(body.week_start).toBe(fixture.week_start)
    expect(body.date).toMatch(/^\d{4}-\d{2}-\d{2}$/)
  })
})
