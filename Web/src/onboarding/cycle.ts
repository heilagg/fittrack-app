// Шаг 9 онбординга: что пишет каждый ответ (SPEC §5, «Решения по онбордингу»).
//
// Результат — тело `PATCH /v1/profile` и, отдельно, дата начала последней
// менструации (прямая запись в `cycle_events`, §20.6).

import type { PatchProfileRequest } from '../api/schemas'

export type TrackingAnswer = 'yes' | 'no' | 'not_now'
export type ContraceptionAnswer = 'yes' | 'no' | 'declined'
export type Regularity = 'regular' | 'variable' | 'irregular'

export interface CycleAnswers {
  tracking: TrackingAnswer
  /** Спрашивается только при `tracking = yes`. */
  contraception?: ContraceptionAnswer
  periodStart?: string
  cycleLength?: number
  periodLength?: number
  regularity?: Regularity
}

export interface CycleWrite {
  patch: PatchProfileRequest
  /** Дата для `cycle_events` как `period_start`; `undefined` — не писать. */
  periodStart: string | undefined
}

export function cycleWrite(a: CycleAnswers): CycleWrite {
  switch (a.tracking) {
    case 'no':
      return {
        patch: { cycle_tracking: 'off', cycle: { phase_mode: 'no_phases', no_phase_reason: 'user_choice' } },
        periodStart: undefined,
      }
    case 'not_now':
      // Отказ отвечать, а не решение: можно переспросить позже (§11.5).
      return {
        patch: { cycle_tracking: 'off', cycle: { phase_mode: 'no_phases', no_phase_reason: 'declined' } },
        periodStart: undefined,
      }
    case 'yes': {
      if (a.contraception === 'yes') {
        return {
          patch: { cycle_tracking: 'manual', cycle: { phase_mode: 'no_phases', no_phase_reason: 'contraception' } },
          periodStart: undefined,
        }
      }
      if (a.contraception === 'declined') {
        return {
          patch: { cycle_tracking: 'manual', cycle: { phase_mode: 'no_phases', no_phase_reason: 'declined' } },
          periodStart: undefined,
        }
      }
      return {
        patch: {
          cycle_tracking: 'manual',
          cycle: {
            phase_mode: 'phases',
            ...(a.cycleLength !== undefined ? { typical_cycle_length_days: a.cycleLength } : {}),
            ...(a.periodLength !== undefined ? { typical_period_length_days: a.periodLength } : {}),
            ...(a.regularity !== undefined ? { declared_regularity: a.regularity } : {}),
          },
        },
        periodStart: a.periodStart,
      }
    }
  }
}

/**
 * Обратное отображение: какие ответы шага 9 дают сохранённый профиль — чтобы
 * правка цикла из Профиля начиналась с текущих ответов (срез 6). Дата начала
 * не восстанавливается: события правятся в календаре (§11.6).
 */
export function cycleAnswersOf(profile: {
  cycle_tracking: string
  cycle?: {
    phase_mode: string
    no_phase_reason?: string | undefined
    typical_cycle_length_days?: number | undefined
    typical_period_length_days?: number | undefined
    declared_regularity?: string | undefined
  } | undefined
}): Partial<CycleAnswers> {
  const cycle = profile.cycle
  const reason = cycle?.no_phase_reason
  if (profile.cycle_tracking === 'off') {
    if (reason === 'declined') return { tracking: 'not_now' }
    if (reason === 'user_choice') return { tracking: 'no' }
    return {}
  }
  if (reason === 'contraception') return { tracking: 'yes', contraception: 'yes' }
  if (reason === 'declined') return { tracking: 'yes', contraception: 'declined' }
  if (cycle?.phase_mode === 'phases' || reason === 'low_confidence') {
    return {
      tracking: 'yes',
      contraception: 'no',
      ...(cycle?.typical_cycle_length_days !== undefined ? { cycleLength: cycle.typical_cycle_length_days } : {}),
      ...(cycle?.typical_period_length_days !== undefined ? { periodLength: cycle.typical_period_length_days } : {}),
      ...(cycle?.declared_regularity === 'regular' || cycle?.declared_regularity === 'variable' || cycle?.declared_regularity === 'irregular'
        ? { regularity: cycle.declared_regularity }
        : {}),
    }
  }
  return {}
}
