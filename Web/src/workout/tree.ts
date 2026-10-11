// Применение дерева решений §20.9 на клиенте (web-domain §3.4).
//
// Дерево — готовая карта состояний, пришедшая с сервера: клиент выбирает
// ПЕРЕХОД по фидбэку и повторам и читает вес узла. Формул §9.3 (×0.90, ×0.95,
// ×1.05, ×1.15) здесь нет и быть не должно — они уже посчитаны в узлах.
//
// Единственное, что клиент вычисляет, — какой из шести переходов взять. Это
// предикат, а не вес: фактические повторы входят в решение сравнением с
// границами диапазона упражнения (`target_rep_min`/`target_rep_max`), как
// описывает §20.9. Названия переходов — строковые константы контракта.

import type { DecisionTree } from '../api/schemas'

export type Feedback = 'easy' | 'ok' | 'hard' | 'failed'

export type Branch =
  | 'failed'
  | 'hard_below_min'
  | 'hard_at_or_above_min'
  | 'ok'
  | 'easy_below_max'
  | 'easy_at_or_above_max'

/** Какой из шести переходов дерева соответствует подходу (§20.9). */
export function branchFor(feedback: Feedback, actualReps: number, repMin: number, repMax: number): Branch {
  switch (feedback) {
    case 'failed':
      return 'failed'
    case 'ok':
      return 'ok'
    case 'hard':
      return actualReps < repMin ? 'hard_below_min' : 'hard_at_or_above_min'
    case 'easy':
      return actualReps >= repMax ? 'easy_at_or_above_max' : 'easy_below_max'
  }
}

export type Step =
  | { kind: 'node'; nodeId: string; weightKg: number | undefined; terminates: boolean }
  /**
   * Перехода нет: узел обрезан по глубине (`truncated`) либо подходов больше
   * не остаётся. Показывать нечего, ответ даёт сервер (§20.9).
   */
  | { kind: 'ask-server' }

/** Узел, на который указывает дерево сейчас. */
export function currentStep(tree: DecisionTree, nodeId: string = tree.start): Step {
  const node = tree.nodes[nodeId]
  if (!node) return { kind: 'ask-server' }
  return { kind: 'node', nodeId, weightKg: node.weight_kg, terminates: node.terminates }
}

/** Применяет ветку мгновенно, без запроса. */
export function applyBranch(tree: DecisionTree, nodeId: string, branch: Branch): Step {
  const node = tree.nodes[nodeId]
  if (!node || node.truncated) return { kind: 'ask-server' }
  const next = node.transitions[branch]
  if (next === undefined) return { kind: 'ask-server' }
  return currentStep(tree, next)
}
