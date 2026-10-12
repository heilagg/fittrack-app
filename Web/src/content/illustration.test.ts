import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { illustrationOf } from './illustration'

describe('ключ картинки (§6.5)', () => {
  it('catalog/<match>/<слаг> — два кадра в /illustrations/<слаг>/', () => {
    expect(illustrationOf('catalog/exact/plank_bw')).toEqual({
      kind: 'catalog', match: 'exact',
      start: '/illustrations/plank_bw/start.jpg', finish: '/illustrations/plank_bw/finish.jpg',
    })
    expect(illustrationOf('catalog/close/farmer_carry_dumbbell')).toMatchObject({ kind: 'catalog', match: 'close' })
  })

  it('заглушка, неизвестное и пустое — заглушка', () => {
    for (const key of ['placeholder/lower/squat_bw', 'placeholder/exact/squat_bw', 'catalog/maybe/x', 'catalog/exact/', 'catalog/exact', 'x', '', undefined]) {
      expect(illustrationOf(key), String(key)).toEqual({ kind: 'placeholder' })
    }
  })
})

describe('файлы картинок и сопоставление FitContent', () => {
  const map = JSON.parse(
    readFileSync(join(__dirname, '../../../Packages/FitContent/Sources/FitContent/Resources/illustrations.json'), 'utf-8'),
  ) as { exercises: Record<string, { id: string; match: string }> }
  const dir = join(__dirname, '../../public/illustrations')

  it('у каждого сопоставленного слага есть оба кадра', () => {
    for (const slug of Object.keys(map.exercises)) {
      for (const frame of ['start.jpg', 'finish.jpg']) {
        const file = join(dir, slug, frame)
        expect(existsSync(file), file).toBe(true)
        expect(statSync(file).size, file).toBeGreaterThan(1000)
      }
    }
  })

  it('лишних каталогов нет: картинка без сопоставления на экран не попадёт', () => {
    expect(readdirSync(dir).sort()).toEqual(Object.keys(map.exercises).sort())
  })
})
