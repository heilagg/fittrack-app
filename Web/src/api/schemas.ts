// Схемы тел `/v1`, написанные руками (SPEC §20.2; web-domain §5).
//
// Источник правды — `Packages/FitAPI`. Эта копия не выводится из него, а
// проверяется: Swift-тесты выгружают эталоны в `Contract/fixtures/`, а
// `contract.test.ts` прогоняет их через эти схемы. Новое поле появляется
// сначала в DTO и эталоне, потом здесь.
//
// Схемы строгие там, где словарь закрыт (`kind`, `code`): неизвестное значение
// роняет разбор целиком и показывается как ошибка контракта, а не превращается
// в молчаливый `undefined`. Тело разбирается на границе `api/`, а не кастом.

import { z } from 'zod'

// MARK: - Причины `{code, params, message}` (§20.3)

const cycleConfidence = z.number().nullish()

const rebuildCauseSchema = z.discriminatedUnion('code', [
  z.object({
    code: z.literal('phase_changed'),
    params: z.object({ phase: z.string().nullish(), cycle_confidence: cycleConfidence }),
    message: z.string(),
  }),
  z.object({
    code: z.literal('cycle_confidence_changed'),
    params: z.object({ cycle_confidence: cycleConfidence }),
    message: z.string(),
  }),
  ...(['workout_skipped', 'workout_completed', 'override', 'day_edited', 'equipment_changed'] as const).map(
    (code) => z.object({ code: z.literal(code), params: z.object({}), message: z.string() }),
  ),
])

const noParams = z.object({})

/** Размеченное объединение по `code`; конверт у всех причин один (§20.3). */
export const reasonSchema = z.discriminatedUnion('code', [
  z.object({
    code: z.literal('phase_periodization'),
    params: z.object({ phase: z.string(), cycle_confidence: z.number() }),
    message: z.string(),
  }),
  z.object({
    code: z.literal('ovulatory_impact_caution'),
    params: z.object({ cycle_confidence: z.number() }),
    message: z.string(),
  }),
  z.object({
    code: z.literal('pattern_minimum_relaxed_unavailable'),
    params: z.object({ available: z.number() }),
    message: z.string(),
  }),
  z.object({
    code: z.literal('pattern_minimum_relaxed_by_time'),
    params: z.object({ fitted: z.number() }),
    message: z.string(),
  }),
  z.object({
    code: z.literal('pattern_minimum_relaxed_by_limit'),
    params: z.object({ fitted: z.number(), limit: z.enum(['exercise_count', 'family']) }),
    message: z.string(),
  }),
  z.object({
    code: z.literal('plan_rebuilt'),
    params: z.object({ cause: rebuildCauseSchema }),
    message: z.string(),
  }),
  z.object({ code: z.literal('plan_changed'), params: noParams, message: z.string() }),
  z.object({
    code: z.literal('planned_volume_loss'),
    params: z.object({ muscle: z.string(), sets: z.number(), cause: z.string() }),
    message: z.string(),
  }),
  z.object({
    code: z.literal('week_shortfall_by_time'),
    params: z.object({ muscle: z.string(), sets: z.number() }),
    message: z.string(),
  }),
  z.object({ code: z.literal('workout_generation_disabled'), params: noParams, message: z.string() }),
  z.object({ code: z.literal('no_feasible_exercises'), params: noParams, message: z.string() }),
  z.object({
    code: z.literal('day_vector_missing'),
    params: z.object({ kind: z.string(), accent: z.string().optional() }),
    message: z.string(),
  }),
  z.object({
    code: z.literal('substitution_keeps_leading_muscle'),
    params: z.object({ muscle: z.string() }),
    message: z.string(),
  }),
  z.object({
    code: z.literal('substitution_relieves_joint'),
    params: z.object({ joint: z.string(), from: z.string(), to: z.string() }),
    message: z.string(),
  }),
])
export type Reason = z.infer<typeof reasonSchema>

/** Причина итога дня: десять значений, `params` у всех пуст (§20.3). */
export const dayCauseCodes = [
  'rest_override',
  'skipped',
  'replaced',
  'started',
  'done',
  'past',
  'grid_stretch',
  'markup_missing',
  'pregnancy',
  'not_a_training_day',
] as const
export const dayCauseSchema = z.object({
  code: z.enum(dayCauseCodes),
  params: noParams,
  message: z.string(),
})
export type DayCause = z.infer<typeof dayCauseSchema>

// MARK: - День и карточка (§20.3)

export const prescribedExerciseSchema = z.object({
  slug: z.string(),
  order_index: z.number().int(),
  target_sets: z.number().int(),
  target_rep_min: z.number().int(),
  target_rep_max: z.number().int(),
  target_rir: z.number().int(),
  prescribed_kg: z.number().optional(),
  weight_readiness: z.number(),
})
export type PrescribedExercise = z.infer<typeof prescribedExerciseSchema>

export const builtSessionSchema = z.object({
  day_id: z.string(),
  exercises: z.array(prescribedExerciseSchema),
  estimated_seconds: z.number(),
  leading_muscle: z.string().optional(),
  reasons: z.array(reasonSchema),
})
export type BuiltSession = z.infer<typeof builtSessionSchema>

/** Ветка показа — закрытый словарь §20.3. */
export const dayKinds = ['session', 'stretching', 'not_built', 'vector_missing', 'generator_disabled'] as const
export type DayKind = (typeof dayKinds)[number]

export const dayOutcomeSchema = z.object({
  // Ключ опускается, а не едет `null`, когда строки `planned_days` нет.
  day_id: z.string().optional(),
  kind: z.enum(dayKinds),
  cause: dayCauseSchema.optional(),
  loses_planned_volume: z.boolean(),
  session: builtSessionSchema.optional(),
})
export type DayOutcome = z.infer<typeof dayOutcomeSchema>

export const cycleStateSchema = z.object({
  phase_mode: z.enum(['phases', 'no_phases']),
  no_phase_reason: z.string().optional(),
  has_anchor: z.boolean(),
  phase: z.string().optional(),
  cycle_confidence: z.number().optional(),
})
export type CycleState = z.infer<typeof cycleStateSchema>

export const todayCardSchema = z.object({
  date: z.string(),
  readiness: z.number(),
  cycle: cycleStateSchema,
  day: dayOutcomeSchema,
  reasons: z.array(reasonSchema),
})
export type TodayCard = z.infer<typeof todayCardSchema>

export const weekPlanResponseSchema = z.object({
  plan: z.object({ days: z.array(dayOutcomeSchema), status_lines: z.array(reasonSchema) }),
  notice: reasonSchema.optional(),
})
export type WeekPlanResponse = z.infer<typeof weekPlanResponseSchema>

// MARK: - Тренировка (§20.3, §20.9)

export const setSchema = z.object({
  id: z.string(),
  exercise_slug: z.string(),
  set_index: z.number().int(),
  prescribed_kg: z.number().optional(),
  prescribed_reps: z.number().int(),
  actual_kg: z.number().optional(),
  actual_reps: z.number().int().optional(),
  feedback: z.enum(['easy', 'ok', 'hard', 'failed']).optional(),
  pain_flag: z.boolean(),
  pain_joints: z.array(z.string()),
  rest_seconds: z.number().int().optional(),
  completed_at: z.string().optional(),
  skipped: z.boolean(),
})
export type SetRow = z.infer<typeof setSchema>

/**
 * Карта состояний дерева §20.9: переход ведёт к идентификатору узла, а не к
 * вложенному потомку. Применяется она в срезе 3; здесь только разбор.
 */
export const decisionNodeSchema = z.object({
  weight_kg: z.number().optional(),
  truncated: z.boolean(),
  terminates: z.boolean(),
  transitions: z.record(z.string(), z.string()),
})
export const decisionTreeSchema = z.object({
  start: z.string(),
  nodes: z.record(z.string(), decisionNodeSchema),
})
export type DecisionTree = z.infer<typeof decisionTreeSchema>

export const workoutExerciseSchema = z.object({
  id: z.string(),
  slug: z.string(),
  order_index: z.number().int(),
  target_sets: z.number().int(),
  target_rep_min: z.number().int(),
  target_rep_max: z.number().int(),
  target_rir: z.number().int(),
  prescribed_kg: z.number().optional(),
  weight_readiness: z.number(),
  is_calibration: z.boolean(),
  substituted_from: z.string().optional(),
  substitution_reason: z.string().optional(),
  // Пусто ровно тогда, когда подходов не осталось (§20.3).
  decision_tree: decisionTreeSchema.optional(),
  sets: z.array(setSchema),
})
export type WorkoutExercise = z.infer<typeof workoutExerciseSchema>

export const workoutSchema = z.object({
  id: z.string(),
  planned_day_id: z.string().optional(),
  session_kind: z.enum(['full_body', 'upper', 'lower', 'push', 'pull', 'rest', 'stretch']),
  accent_muscle: z.string().optional(),
  started_at: z.string(),
  finished_at: z.string().optional(),
  readiness: z.number(),
  cycle_phase: z.string().optional(),
  cycle_confidence: z.number().optional(),
  is_calibration: z.boolean(),
  exercises: z.array(workoutExerciseSchema),
})
export type Workout = z.infer<typeof workoutSchema>

/**
 * Тело `POST …/sets` (§20.3). `prescribed_kg` приходит от клиента — вес назначило
 * дерево; `prescribed_reps` в запросе нет, его пишет сервер.
 */
export const logSetRequestSchema = z.object({
  id: z.string(),
  set_index: z.number().int(),
  prescribed_kg: z.number().optional(),
  actual_kg: z.number().optional(),
  actual_reps: z.number().int().optional(),
  feedback: z.enum(['easy', 'ok', 'hard', 'failed']).optional(),
  pain_flag: z.boolean(),
  rest_seconds: z.number().int().optional(),
  completed_at: z.string(),
  skipped: z.boolean(),
  date: z.string(),
  tz: z.string(),
})
export type LogSetRequest = z.infer<typeof logSetRequestSchema>

/** Ответ — только новое дерево, без готового следующего подхода (§20.3). */
export const logSetResponseSchema = z.object({ decision_tree: decisionTreeSchema })
export type LogSetResponse = z.infer<typeof logSetResponseSchema>

/** Тело `POST …/finish`: только пара дня (§20.3). */
export const finishWorkoutRequestSchema = z.object({ date: z.string(), tz: z.string() })
export type FinishWorkoutRequest = z.infer<typeof finishWorkoutRequestSchema>

/**
 * Ответ `POST …/finish` (§20.3): итог тренировки и неделя. Ключа `week` может
 * не быть (недели нет, `/finish` её не генерирует); `week.notice` — строка
 * «План обновлён», в повторе `/finish` её нет.
 */
export const finishWorkoutResponseSchema = z.object({
  workout: workoutSchema,
  week: weekPlanResponseSchema.optional(),
})
export type FinishWorkoutResponse = z.infer<typeof finishWorkoutResponseSchema>

export const startWorkoutRequestSchema = z.object({
  planned_day_id: z.string(),
  equipment_profile_id: z.string().optional(),
  date: z.string(),
  tz: z.string(),
})
export type StartWorkoutRequest = z.infer<typeof startWorkoutRequestSchema>

// MARK: - Профиль (§20.3)

export const cycleProfileSchema = z.object({
  typical_cycle_length_days: z.number().int().optional(),
  typical_period_length_days: z.number().int().optional(),
  declared_regularity: z.string().optional(),
  phase_mode: z.enum(['phases', 'no_phases']),
  no_phase_reason: z.string().optional(),
})

export const profileSchema = z.object({
  sex_at_birth: z.string().optional(),
  birth_year: z.number().int().optional(),
  height_cm: z.number().optional(),
  experience_level: z.enum(['novice', 'intermediate', 'advanced']).optional(),
  goal: z.enum(['strength', 'hypertrophy', 'toning', 'endurance', 'general']).optional(),
  days_per_week: z.number().int().optional(),
  training_weekdays: z.array(z.number().int()).optional(),
  session_minutes: z.number().int(),
  cycle_tracking: z.enum(['off', 'manual', 'healthkit']),
  // Ответ сервера, а не правило клиента: четыре поля и инвентарь по умолчанию.
  is_complete: z.boolean(),
  cycle: cycleProfileSchema.optional(),
})
export type Profile = z.infer<typeof profileSchema>

// MARK: - Контент (§20.11)

export const exerciseContentSchema = z.object({
  slug: z.string(),
  name: z.string(),
  cues: z.array(z.string()),
  common_errors: z.array(z.string()),
  illustration: z.string(),
  default_rest_seconds: z.number().int(),
})
export type ExerciseContent = z.infer<typeof exerciseContentSchema>
export const exerciseContentListSchema = z.array(exerciseContentSchema)

// MARK: - Ошибка (§20.3)

export const errorCodes = [
  'unauthorized',
  'jwks_unavailable',
  'forbidden',
  'unlinked_account',
  'not_found',
  'date_skew',
  'validation_failed',
  'week_exists',
  'set_id_required',
  'set_immutable',
  'workout_not_started',
  'workout_finished',
  'day_not_planned',
  'profile_incomplete',
  'generator_disabled',
  'internal',
] as const
export type ErrorCode = (typeof errorCodes)[number]

export const errorEnvelopeSchema = z.object({
  error: z.object({
    code: z.enum(errorCodes),
    message: z.string(),
    details: z.record(z.string(), z.union([z.string(), z.number(), z.boolean()])).optional(),
  }),
})

// MARK: - Тела запросов

export const patchProfileRequestSchema = z.object({
  sex_at_birth: z.string().nullable().optional(),
  birth_year: z.number().int().nullable().optional(),
  height_cm: z.number().nullable().optional(),
  experience_level: z.enum(['novice', 'intermediate', 'advanced']).nullable().optional(),
  goal: z.enum(['strength', 'hypertrophy', 'toning', 'endurance', 'general']).nullable().optional(),
  training_weekdays: z.array(z.number().int()).nullable().optional(),
  session_minutes: z.number().int().optional(),
  cycle_tracking: z.enum(['off', 'manual', 'healthkit']).optional(),
  // Шаг 9 онбординга: обе таблицы одним телом (§20.3). `null` вместо объекта
  // сервер запрещает, поэтому здесь только объект.
  cycle: z
    .object({
      typical_cycle_length_days: z.number().int().optional(),
      typical_period_length_days: z.number().int().optional(),
      declared_regularity: z.enum(['regular', 'variable', 'irregular']).optional(),
      phase_mode: z.enum(['phases', 'no_phases']),
      no_phase_reason: z
        .enum(['contraception', 'amenorrhea', 'menopause', 'pregnancy', 'user_choice', 'declined', 'low_confidence'])
        .optional(),
    })
    .optional(),
})
export type PatchProfileRequest = z.infer<typeof patchProfileRequestSchema>

export const generateWeekPlanRequestSchema = z.object({
  week_start: z.string(),
  date: z.string(),
  tz: z.string(),
})
export type GenerateWeekPlanRequest = z.infer<typeof generateWeekPlanRequestSchema>
