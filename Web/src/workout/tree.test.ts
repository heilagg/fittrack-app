import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { decisionTreeSchema, logSetResponseSchema } from '../api/schemas'
import { applyBranch, branchFor, currentStep, type Branch, type Feedback } from './tree'

const fixture = (name: string): unknown =>
  JSON.parse(readFileSync(join(__dirname, '../../../Contract/fixtures', name), 'utf-8'))

const tree = logSetResponseSchema.parse(fixture('response_log_set.json')).decision_tree

describe('выбор ветки дерева §20.9', () => {
  const cases: [Feedback, number, Branch][] = [
    ['failed', 1, 'failed'],
    ['failed', 12, 'failed'],
    ['ok', 6, 'ok'],
    ['ok', 10, 'ok'],
    ['hard', 5, 'hard_below_min'], // меньше rep_min
    ['hard', 6, 'hard_at_or_above_min'], // ровно rep_min
    ['hard', 9, 'hard_at_or_above_min'],
    ['easy', 9, 'easy_below_max'], // меньше rep_max
    ['easy', 10, 'easy_at_or_above_max'], // ровно rep_max
    ['easy', 12, 'easy_at_or_above_max'],
  ]
  for (const [feedback, reps, expected] of cases) {
    it(`${feedback}, ${reps} повт. при диапазоне 6–10 → ${expected}`, () => {
      expect(branchFor(feedback, reps, 6, 10)).toBe(expected)
    })
  }

  it('каждая ветка, которую выбирает клиент, есть в карте сервера (эталон)', () => {
    const keys = Object.keys(tree.nodes.n0!.transitions).sort()
    const produced = new Set<string>()
    for (const feedback of ['easy', 'ok', 'hard', 'failed'] as const) {
      for (const reps of [1, 6, 9, 10, 15]) produced.add(branchFor(feedback, reps, 6, 10))
    }
    expect([...produced].sort()).toEqual(keys)
  })
})

describe('применение ветки', () => {
  it('«легко» на верхней границе ведёт в узел с весом выше', () => {
    const step = applyBranch(tree, 'n0', 'easy_at_or_above_max')
    expect(step).toEqual({ kind: 'node', nodeId: 'n2', weightKg: 42.5, terminates: false })
  })

  it('«не смог» ведёт вниз, «нормально» оставляет вес', () => {
    expect(applyBranch(tree, 'n0', 'failed')).toMatchObject({ weightKg: 36 })
    expect(applyBranch(tree, 'n0', 'ok')).toMatchObject({ nodeId: 'n0', weightKg: 40 })
  })

  it('перехода нет — спрашиваем сервер, а не угадываем', () => {
    // У n1 нет исходящих переходов (последний подход упражнения).
    expect(applyBranch(tree, 'n1', 'ok')).toEqual({ kind: 'ask-server' })
  })

  it('обрезанный узел — спрашиваем сервер, даже если переход описан', () => {
    const truncated = decisionTreeSchema.parse({
      start: 'a',
      nodes: {
        a: { weight_kg: 10, truncated: true, terminates: false, transitions: { ok: 'b' } },
        b: { weight_kg: 10, truncated: false, terminates: false, transitions: {} },
      },
    })
    expect(applyBranch(truncated, 'a', 'ok')).toEqual({ kind: 'ask-server' })
  })

  it('неизвестный узел — спрашиваем сервер', () => {
    expect(applyBranch(tree, 'zzz', 'ok')).toEqual({ kind: 'ask-server' })
    expect(currentStep(tree, 'zzz')).toEqual({ kind: 'ask-server' })
  })

  it('досрочное завершение приезжает узлом с terminates и без веса', () => {
    const terminated = logSetResponseSchema.parse(fixture('response_log_set_terminated.json')).decision_tree
    expect(currentStep(terminated)).toEqual({
      kind: 'node',
      nodeId: 'n0',
      weightKg: undefined,
      terminates: true,
    })
  })

  it('упражнение без веса: узел без weight_kg', () => {
    const bodyweight = decisionTreeSchema.parse({
      start: 'n0',
      nodes: { n0: { truncated: false, terminates: false, transitions: { failed: 'n1' } }, n1: { truncated: false, terminates: false, transitions: {} } },
    })
    expect(currentStep(bodyweight)).toMatchObject({ weightKg: undefined, terminates: false })
  })
})
