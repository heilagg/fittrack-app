import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { buildParqRow, hasRedFlag, PARQ_QUESTIONS } from './parq'
import { DISCLAIMER_PENDING_LEGAL, ONBOARDING_SUMMARY, RED_FLAG_PENDING_LEGAL } from './texts'

const spec = readFileSync(join(__dirname, '../../../SPEC.md'), 'utf-8').replace(/\s+/g, ' ')

describe('PAR-Q', () => {
  it('семь вопросов, и каждый дословно стоит в SPEC §14.1', () => {
    expect(PARQ_QUESTIONS).toHaveLength(7)
    for (const q of PARQ_QUESTIONS) expect(spec).toContain(q)
  })

  it('текст итога онбординга дословно из SPEC §5', () => {
    expect(spec).toContain(ONBOARDING_SUMMARY)
  })

  it('любое «да» — красный флаг; все «нет» — нет', () => {
    expect(hasRedFlag([false, false, false, false, false, false, false])).toBe(false)
    expect(hasRedFlag([false, false, false, false, false, false, true])).toBe(true)
  })

  it('строка: ключи q1…q7, флаг, подтверждение только при флаге', () => {
    const now = new Date('2026-10-12T10:00:00Z')
    const clean = buildParqRow('u', Array(7).fill(false), true, now)
    expect(Object.keys(clean.answers)).toEqual(['q1', 'q2', 'q3', 'q4', 'q5', 'q6', 'q7'])
    expect(clean).toMatchObject({ has_red_flag: false, acknowledged: false })
    const flagged = buildParqRow('u', [false, true, false, false, false, false, false], true, now)
    expect(flagged).toMatchObject({ has_red_flag: true, acknowledged: true, completed_at: '2026-10-12T10:00:00.000Z' })
    expect(flagged.answers.q2).toBe(true)
  })

  it('не семь ответов — ошибка, а не молчаливая запись', () => {
    expect(() => buildParqRow('u', [true], false, new Date())).toThrow()
  })
})

describe('тексты, ждущие юриста', () => {
  it('помечены в коде и непусты', () => {
    expect(DISCLAIMER_PENDING_LEGAL.length).toBeGreaterThan(0)
    expect(RED_FLAG_PENDING_LEGAL.length).toBeGreaterThan(0)
    const source = readFileSync(join(__dirname, 'texts.ts'), 'utf-8')
    expect(source).toContain('ЖДЁТ ЮРИСТА')
  })
})
