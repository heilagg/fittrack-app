// PAR-Q (SPEC §14.1): семь вопросов дословно, любое «да» — красный флаг.

import type { ParqRow } from '../direct/onboarding'

export const PARQ_QUESTIONS: readonly string[] = [
  'Говорил ли врач, что у вас есть заболевание сердца и физическая активность допустима только по рекомендации врача?',
  'Бывает ли у вас боль в груди при физической нагрузке?',
  'Была ли у вас боль в груди в состоянии покоя за последний месяц?',
  'Теряете ли вы равновесие из-за головокружения или теряли ли сознание?',
  'Есть ли у вас проблемы с костями или суставами, которые могут ухудшиться при физической нагрузке?',
  'Назначал ли врач лекарства от давления или заболеваний сердца?',
  'Знаете ли вы другую причину, по которой вам не следует заниматься?',
]

export function hasRedFlag(answers: readonly boolean[]): boolean {
  return answers.some(Boolean)
}

/**
 * Строка `parq_responses` (§3.1). `acknowledged` истинно только когда есть что
 * подтверждать: рекомендацию к врачу показывают лишь при красном флаге.
 */
export function buildParqRow(
  userId: string,
  answers: readonly boolean[],
  acknowledged: boolean,
  now: Date,
): ParqRow {
  if (answers.length !== PARQ_QUESTIONS.length) throw new Error('PAR-Q: ответов должно быть семь')
  const flag = hasRedFlag(answers)
  return {
    user_id: userId,
    answers: Object.fromEntries(answers.map((a, i) => [`q${i + 1}`, a])),
    has_red_flag: flag,
    acknowledged: flag && acknowledged,
    completed_at: now.toISOString(),
  }
}
