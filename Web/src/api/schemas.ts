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

/** Тип дня — закрытый словарь §3.1; название к нему отдаёт сервер (§7.2). */
export const sessionKinds = ['full_body', 'upper', 'lower', 'push', 'pull', 'rest', 'stretch'] as const
export const sessionKindSchema = z.enum(sessionKinds)

export const builtSessionSchema = z.object({
  day_id: z.string(),
  exercises: z.array(prescribedExerciseSchema),
  estimated_seconds: z.number(),
  leading_muscle: z.string().optional(),
  session_kind: sessionKindSchema,
  session_kind_name: z.string(),
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

// Календарь цикла, `GET /v1/cycle/calendar` (SPEC §11.6, §20.3). Фаза уже
// свёрнута сервером в четыре; ниже порога 0.3 ключей `phase` и
// `cycle_confidence` нет.
export const cyclePeriodDays = ['marked', 'estimated', 'forecast'] as const
export const calendarPhases = ['menstrual', 'follicular', 'ovulatory', 'luteal'] as const

export const cycleMarkSchema = z.object({
  id: z.string(),
  kind: z.string(),
  source: z.string(),
})

export const cycleCalendarDaySchema = z.object({
  date: z.string(),
  marks: z.array(cycleMarkSchema),
  period: z.enum(cyclePeriodDays).optional(),
  phase: z.enum(calendarPhases).optional(),
  cycle_confidence: z.number().optional(),
  ovulation_estimate: z.boolean(),
})
export type CycleCalendarDay = z.infer<typeof cycleCalendarDaySchema>

export const cycleCalendarSchema = z.object({
  from: z.string(),
  to: z.string(),
  cycle: cycleStateSchema,
  next_period: z
    .object({
      expected: z.string(),
      range_start: z.string(),
      range_end: z.string(),
      cycle_confidence: z.number(),
    })
    .optional(),
  overdue: z.boolean(),
  days: z.array(cycleCalendarDaySchema),
  phases: z.array(
    z.object({
      phase: z.enum(calendarPhases),
      name: z.string(),
      feeling: z.string(),
      why: z.string(),
      note: z.string(),
    }),
  ),
})
export type CycleCalendar = z.infer<typeof cycleCalendarSchema>

/**
 * День недели (§20.3, `WeekDay`): поля дня плюс дата и тип. `day_id`
 * обязателен — день недели всегда строка `planned_days`. Дни приходят по дате.
 */
export const weekDaySchema = dayOutcomeSchema.extend({
  date: z.string(),
  session_kind: sessionKindSchema,
  session_kind_name: z.string(),
  day_id: z.string(),
})
export type WeekDay = z.infer<typeof weekDaySchema>

export const weekPlanResponseSchema = z.object({
  plan: z.object({ days: z.array(weekDaySchema), status_lines: z.array(reasonSchema) }),
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
  session_kind: sessionKindSchema,
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
// Поза автозаминки (§12.2): слаг и секунды на сторону.
export const cooldownPoseSchema = z.object({ pose: z.string(), seconds: z.number().int() })
export type CooldownPose = z.infer<typeof cooldownPoseSchema>

export const finishWorkoutResponseSchema = z.object({
  workout: workoutSchema,
  week: weekPlanResponseSchema.optional(),
  // Пустой массив — заминки нет; ключ есть всегда.
  cooldown: z.array(cooldownPoseSchema),
})
export type FinishWorkoutResponse = z.infer<typeof finishWorkoutResponseSchema>

export const startWorkoutRequestSchema = z.object({
  planned_day_id: z.string(),
  equipment_profile_id: z.string().optional(),
  date: z.string(),
  tz: z.string(),
})
export type StartWorkoutRequest = z.infer<typeof startWorkoutRequestSchema>

/** Ответ `GET …/alternatives` (§13.4, §20.3): кандидаты с причинами пригодности. */
export const alternativesSchema = z.array(z.object({ slug: z.string(), reasons: z.array(reasonSchema) }))
export type ExerciseAlternative = z.infer<typeof alternativesSchema>[number]

/** `purpose` у `/alternatives`: замена в один тап или ветка флага боли (§8.4 п.2). */
export type AlternativesPurpose = 'user_choice' | 'pain'

/** Тело `POST …/substitute` (§20.3); ответ — `WorkoutExercise` той же строки. */
export const substituteRequestSchema = z.object({
  to_slug: z.string(),
  reason: z.enum(['equipment', 'pain', 'user_choice', 'occupied']),
  date: z.string(),
  tz: z.string(),
})
export type SubstituteRequest = z.infer<typeof substituteRequestSchema>

// MARK: - Профиль (§20.3)

export const cycleProfileSchema = z.object({
  typical_cycle_length_days: z.number().int().optional(),
  typical_period_length_days: z.number().int().optional(),
  declared_regularity: z.string().optional(),
  phase_mode: z.enum(['phases', 'no_phases']),
  no_phase_reason: z.string().optional(),
})

// Схема тренировок (§7.2): закрытый словарь `profiles.training_split`.
export const trainingSplits = ['auto', 'full_body', 'upper_lower', 'push_pull_legs'] as const
export type TrainingSplit = (typeof trainingSplits)[number]

export const profileSchema = z.object({
  sex_at_birth: z.string().optional(),
  birth_year: z.number().int().optional(),
  height_cm: z.number().optional(),
  experience_level: z.enum(['novice', 'intermediate', 'advanced']).optional(),
  goal: z.enum(['strength', 'hypertrophy', 'toning', 'endurance', 'general']).optional(),
  days_per_week: z.number().int().optional(),
  training_weekdays: z.array(z.number().int()).optional(),
  session_minutes: z.number().int(),
  training_split: z.enum(trainingSplits),
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
  // Подписи снаряда (§6.6): готовые строки, разделитель ставит клиент; пусто —
  // строки под названием нет.
  equipment_labels: z.array(z.string()),
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
  training_split: z.enum(trainingSplits).optional(),
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

/**
 * Тело `POST /v1/week-plans/{week_start}/rebuild` (§20.3). Причин две: клиент
 * называет только то, что сервер не наблюдает сам, — прямые записи
 * инвентаря и событий цикла (§20.6).
 */
export const rebuildWeekPlanRequestSchema = z.object({
  cause: z.enum(['equipment_changed', 'cycle_event_added']),
  date: z.string(),
  tz: z.string(),
})
export type RebuildWeekPlanRequest = z.infer<typeof rebuildWeekPlanRequestSchema>

// MARK: - Растяжка (§12.2, §12.3)

export const poseKinds = ['dynamic', 'static', 'cardio'] as const
export const poseSchema = z.object({
  slug: z.string(),
  name: z.string(),
  kind: z.enum(poseKinds),
  unilateral: z.boolean(),
  default_seconds: z.number().int(),
  cues: z.array(z.string()),
  illustration: z.string(),
})
export type Pose = z.infer<typeof poseSchema>

export const templateItemSchema = z.object({
  pose: z.string(),
  seconds: z.number().int().optional(),
  work_seconds: z.number().int().optional(),
  rest_seconds: z.number().int().optional(),
  rounds: z.number().int().optional(),
})
export type TemplateItem = z.infer<typeof templateItemSchema>

export const stretchTemplateSchema = z.object({
  slug: z.string(),
  name: z.string(),
  purpose: z.string(),
  // Длительность считает сервер из поз (§12.2): клиент формулу не повторяет.
  duration_seconds: z.number().int(),
  minutes: z.number().int(),
  items: z.array(templateItemSchema),
})
export type StretchTemplate = z.infer<typeof stretchTemplateSchema>

export const stretchContentSchema = z.object({
  poses: z.array(poseSchema),
  templates: z.array(stretchTemplateSchema),
})
export type StretchContent = z.infer<typeof stretchContentSchema>

export const stretchSessionKinds = ['standalone', 'static_cooldown'] as const
export const startStretchSessionRequestSchema = z.object({
  id: z.string(),
  kind: z.enum(stretchSessionKinds),
  template_slug: z.string().optional(),
  date: z.string(),
  tz: z.string(),
})
export type StartStretchSessionRequest = z.infer<typeof startStretchSessionRequestSchema>
export const finishStretchSessionRequestSchema = z.object({ date: z.string(), tz: z.string() })

export const stretchSessionSchema = z.object({
  id: z.string(),
  kind: z.enum(['mobility_warmup', 'static_cooldown', 'standalone']),
  template_slug: z.string().optional(),
  performed_on: z.string(),
  started_at: z.string(),
  finished_at: z.string().optional(),
  duration_seconds: z.number().int().optional(),
})
export type StretchSession = z.infer<typeof stretchSessionSchema>

export const stretchHistorySchema = z.object({
  sessions: z.array(stretchSessionSchema),
  suggested_template: z.string(),
})
export type StretchHistory = z.infer<typeof stretchHistorySchema>

// MARK: - Прогресс (§13.7)

export const muscleGroups = ['legs_glutes', 'back', 'chest', 'shoulders', 'arms', 'core'] as const
export type MuscleGroup = (typeof muscleGroups)[number]

export const progressSchema = z.object({
  from: z.string(),
  to: z.string(),
  weeks: z.array(z.object({
    week_start: z.string(),
    partial: z.boolean(),
    groups: z.record(z.enum(muscleGroups), z.number()),
  })),
  group_norms: z.array(z.object({
    group: z.enum(muscleGroups),
    name: z.string(),
    norm: z.number(),
    ceiling: z.number(),
  })),
  baselines: z.array(z.object({
    slug: z.string(),
    points: z.array(z.object({ date: z.string(), kg: z.number() })),
  })),
  days: z.array(z.object({
    date: z.string(),
    strength: z.boolean(),
    stretch: z.boolean(),
    skipped: z.boolean(),
    // Фаза, как её знали в тот день (§13.7), — четыре экранные (§11.6) и её
    // название из каталога сервера.
    phase: z.enum(['menstrual', 'follicular', 'ovulatory', 'luteal']).optional(),
    phase_name: z.string().optional(),
  })),
  streak_weeks: z.number().int(),
})
export type Progress = z.infer<typeof progressSchema>
