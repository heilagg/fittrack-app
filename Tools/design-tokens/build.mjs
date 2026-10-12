#!/usr/bin/env node
// Генерация платформенных файлов из tokens.json.
//
//   node Tools/design-tokens/build.mjs           — перезаписать выводы
//   node Tools/design-tokens/build.mjs --check   — только сверить, код 1 при расхождении
//
// Цели перечислены в TARGETS. Вывод для Swift добавляется сюда же отдельной
// записью (targets/swift.mjs) и разбирает токены той же lib/tokens.mjs.

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { renderCss } from './targets/css.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '../..')

const TARGETS = [{ out: join(root, 'Web/src/styles/tokens.css'), render: renderCss }]

const source = JSON.parse(readFileSync(join(here, 'tokens.json'), 'utf-8'))
const check = process.argv.includes('--check')
let stale = 0

for (const { out, render } of TARGETS) {
  const next = render(source)
  let current = null
  try {
    current = readFileSync(out, 'utf-8')
  } catch {
    // Файла ещё нет.
  }
  if (current === next) continue
  if (check) {
    console.error(`устарел: ${relative(root, out)}`)
    stale++
  } else {
    writeFileSync(out, next)
    console.log(`записан: ${relative(root, out)}`)
  }
}

process.exit(stale > 0 ? 1 : 0)
