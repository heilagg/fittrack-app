// Цель CSS: CSS-переменные на :root для Web/src/styles/tokens.css.
//
// Имя переменной — путь токена через дефис (`color.text-muted` →
// `--color-text-muted`). Типографика раскладывается на пять переменных:
// `--type-<имя>-family|size|weight|tracking|leading`.

import { flattenTokens } from '../lib/tokens.mjs'

const GENERIC_FAMILIES = new Set(['serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui'])

function dimension(v) {
  if (v === null || typeof v !== 'object' || typeof v.value !== 'number' || typeof v.unit !== 'string') {
    throw new Error(`ожидался размер {value, unit}, а пришло ${JSON.stringify(v)}`)
  }
  return `${v.value}${v.unit}`
}

function family(v) {
  const list = Array.isArray(v) ? v : [v]
  return list.map((name) => (GENERIC_FAMILIES.has(name) ? name : `'${name}'`)).join(', ')
}

function declarations(token) {
  const name = token.path.join('-')
  switch (token.type) {
    case 'color':
    case 'fontWeight':
    case 'number':
      return [[`--${name}`, String(token.value)]]
    case 'dimension':
    case 'duration':
      return [[`--${name}`, dimension(token.value)]]
    case 'fontFamily':
      return [[`--${name}`, family(token.value)]]
    case 'typography': {
      const base = `--type-${token.path.slice(1).join('-')}`
      const t = token.value
      return [
        [`${base}-family`, family(t.fontFamily)],
        [`${base}-size`, dimension(t.fontSize)],
        [`${base}-weight`, String(t.fontWeight)],
        [`${base}-tracking`, dimension(t.letterSpacing)],
        [`${base}-leading`, String(t.lineHeight)],
      ]
    }
    default:
      throw new Error(`tokens.json: тип ${token.type} у ${token.path.join('.')} цель CSS не знает`)
  }
}

/** @param {unknown} source содержимое tokens.json */
export function renderCss(source) {
  const lines = [
    '/* Сгенерировано из Tools/design-tokens/tokens.json (npm run tokens в Web/).',
    '   Руками не править: тест tokens.test.ts падает, если файл устарел. */',
    '',
    ':root {',
  ]
  let group = null
  for (const token of flattenTokens(source)) {
    if (group !== null && token.path[0] !== group) lines.push('')
    group = token.path[0]
    for (const [name, value] of declarations(token)) lines.push(`  ${name}: ${value};`)
  }
  lines.push('}', '')
  return lines.join('\n')
}
