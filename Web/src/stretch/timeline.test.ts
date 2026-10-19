import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { stretchContentSchema, type Pose } from '../api/schemas'
import { cooldownTimeline, secondsLeft, stepCaption, timelineOf, totalSeconds } from './timeline'

const pose = (slug: string, unilateral = false, kind: Pose['kind'] = 'static'): Pose => ({
  slug, name: slug, kind, unilateral, default_seconds: 30, cues: [], illustration: 'x',
})
const poses = new Map([pose('a', true), pose('b'), pose('c', false, 'cardio'), pose('d', false, 'cardio')].map((p) => [p.slug, p]))

describe('шаги сессии растяжки (§12.2)', () => {
  it('односторонняя поза — два шага, по стороне на шаг', () => {
    const steps = timelineOf([{ pose: 'a', seconds: 40 }, { pose: 'b', seconds: 50 }], poses)
    expect(steps.map((s) => s.phase)).toEqual(['side1', 'side2', 'hold'])
    expect(totalSeconds(steps)).toBe(130)
    expect(stepCaption(steps[1]!)).toBe('Смените сторону')
  })

  it('кардио — круги работы и отдыха, без отдыха после последнего интервала', () => {
    const steps = timelineOf([
      { pose: 'c', work_seconds: 30, rest_seconds: 15, rounds: 2 },
      { pose: 'd', work_seconds: 30, rest_seconds: 15, rounds: 2 },
    ], poses)
    expect(steps.map((s) => `${s.pose}:${s.phase}:${s.round}`)).toEqual([
      'c:work:1', 'c:rest:1', 'd:work:1', 'd:rest:1', 'c:work:2', 'c:rest:2', 'd:work:2',
    ])
    expect(totalSeconds(steps)).toBe(2 * 2 * 45 - 15)
    expect(stepCaption(steps[0]!)).toBe('Работа · круг 1 из 2')
  })

  it('заминка: секунды на сторону, односторонние — дважды', () => {
    const steps = cooldownTimeline([{ pose: 'a', seconds: 45 }, { pose: 'b', seconds: 30 }], poses)
    expect(totalSeconds(steps)).toBe(120)
  })

  it('остаток — от абсолютной метки, не ниже нуля', () => {
    expect(secondsLeft(10_000, 0)).toBe(10)
    expect(secondsLeft(10_000, 9_001)).toBe(1)
    expect(secondsLeft(10_000, 20_000)).toBe(0)
  })

  it('на эталоне: сумма шагов каждого шаблона равна duration_seconds сервера', () => {
    const body = stretchContentSchema.parse(JSON.parse(
      readFileSync(join(__dirname, '../../../Contract/fixtures/content_stretches.json'), 'utf-8')))
    const map = new Map(body.poses.map((p) => [p.slug, p]))
    for (const template of body.templates) {
      expect(totalSeconds(timelineOf(template.items, map)), template.slug).toBe(template.duration_seconds)
    }
  })
})
