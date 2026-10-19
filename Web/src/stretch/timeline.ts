// Шаги сессии растяжки (SPEC §12.2, §12.3): что показывает проигрыватель.
//
// Не расчёт, а развёртка готовых данных: секунды приходят в шаблоне с сервера,
// здесь они только раскладываются по экранам. Односторонняя поза — два шага,
// по стороне на шаг, с подсказкой о смене стороны текстом (§12.2, голоса нет).
// Кардио — круги: каждая поза по очереди, работа и отдых, `rounds` раз; отдыха
// после последнего интервала нет. Сумма шагов совпадает с `duration_seconds`
// сервера — это проверяет тест на эталоне, а не повтор формулы.

import type { CooldownPose, Pose, TemplateItem } from '../api/schemas'

export type StepPhase = 'hold' | 'side1' | 'side2' | 'work' | 'rest'

export interface Step {
  pose: string
  seconds: number
  phase: StepPhase
  /** Номер круга кардио и их число; у растяжки нет. */
  round?: number
  rounds?: number
}

export function timelineOf(items: readonly TemplateItem[], poses: ReadonlyMap<string, Pose>): Step[] {
  const steps: Step[] = []
  const intervals = items.filter((i) => i.work_seconds !== undefined)
  for (const item of items) {
    if (item.work_seconds !== undefined) continue
    steps.push(...holdSteps(item.pose, item.seconds ?? 0, poses))
  }
  const rounds = intervals[0]?.rounds ?? 0
  for (let round = 1; round <= rounds; round++) {
    for (const item of intervals) {
      steps.push({ pose: item.pose, seconds: item.work_seconds ?? 0, phase: 'work', round, rounds })
      steps.push({ pose: item.pose, seconds: item.rest_seconds ?? 0, phase: 'rest', round, rounds })
    }
  }
  if (steps.at(-1)?.phase === 'rest') steps.pop()
  return steps
}

/** Заминка (§12.2): позы с секундами на сторону. */
export function cooldownTimeline(cooldown: readonly CooldownPose[], poses: ReadonlyMap<string, Pose>): Step[] {
  return cooldown.flatMap((c) => holdSteps(c.pose, c.seconds, poses))
}

function holdSteps(slug: string, seconds: number, poses: ReadonlyMap<string, Pose>): Step[] {
  return poses.get(slug)?.unilateral
    ? [{ pose: slug, seconds, phase: 'side1' }, { pose: slug, seconds, phase: 'side2' }]
    : [{ pose: slug, seconds, phase: 'hold' }]
}

export function totalSeconds(steps: readonly Step[]): number {
  return steps.reduce((sum, s) => sum + s.seconds, 0)
}

/** Подпись шага: сторона, работа или отдых — текстом (§12.2). */
export function stepCaption(step: Step): string | null {
  switch (step.phase) {
    case 'side1': return 'Первая сторона'
    case 'side2': return 'Смените сторону'
    case 'work': return `Работа · круг ${step.round} из ${step.rounds}`
    case 'rest': return `Отдых · круг ${step.round} из ${step.rounds}`
    case 'hold': return null
  }
}

/** Секунды до конца шага от абсолютной метки (как таймер отдыха §13.3). */
export function secondsLeft(endAt: number, now: number): number {
  return Math.max(0, Math.ceil((endAt - now) / 1000))
}

export const EXTEND_STEP_SECONDS = 15
