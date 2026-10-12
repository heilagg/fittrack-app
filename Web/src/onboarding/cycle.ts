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
