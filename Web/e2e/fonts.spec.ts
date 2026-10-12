import { expect, test } from '@playwright/test'
import { completeOnboarding } from './helpers'

// Шрифты (web-domain §8): у Space Grotesk нет кириллицы, русский текст рисует
// Manrope. Google отдаёт все наборы Manrope с unicode-range и параметра subset
// не учитывает, поэтому «только кириллица» обеспечивает порядок в стеке: Space
// Grotesk первым закрывает латиницу и цифры, и латинский набор Manrope браузеру
// не нужен. Тест проверяет, что скачано на самом деле.
//
// Единственный e2e, который ходит наружу — на fonts.googleapis.com.

// В записи браузера: ведущие нули диапазонов срезаны.
const CYRILLIC = 'U+400-45F'
const LATIN = 'U+0-FF'

test('загружены Space Grotesk для латиницы и цифр и только кириллица Manrope', async ({ page }) => {
  await completeOnboarding(page)
  await expect(page.getByTestId('exercise-name').first()).toBeVisible()

  const faces = await page.evaluate(async () => {
    await document.fonts.ready
    return [...document.fonts].map((f) => ({
      family: f.family.replace(/["']/g, ''),
      range: f.unicodeRange,
      status: f.status,
    }))
  })
  const loaded = (family: string) => faces.filter((f) => f.family === family && f.status === 'loaded')

  const manrope = loaded('Manrope')
  expect(manrope.length).toBeGreaterThan(0)
  for (const face of manrope) expect(face.range).toContain(CYRILLIC)

  expect(loaded('Space Grotesk').some((f) => f.range.includes(LATIN))).toBe(true)

  const family = await page.evaluate(() => getComputedStyle(document.body).fontFamily)
  expect(family.replace(/["']/g, '')).toBe('Space Grotesk, Manrope, sans-serif')
})
