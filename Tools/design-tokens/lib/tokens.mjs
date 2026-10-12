// Чтение tokens.json (формат DTCG) в плоский список, общий для всех целей.
//
// Цель (targets/css.mjs, позже targets/swift.mjs) получает уже разобранные
// токены: путь, тип и значение со снятыми ссылками. Разбор формата живёт здесь
// один раз, чтобы две платформы не прочитали одно и то же по-разному.

/** Ключи DTCG, которые не являются ни группой, ни токеном. */
const isMeta = (key) => key.startsWith('$')

/**
 * @param {unknown} source содержимое tokens.json
 * @returns {{ path: string[], type: string, value: unknown, description?: string, derived: boolean }[]}
 */
export function flattenTokens(source) {
  const raw = []
  walk(source, [], undefined, raw)
  const byPath = new Map(raw.map((t) => [t.path.join('.'), t]))
  return raw.map((t) => ({ ...t, value: resolve(t.value, byPath, [t.path.join('.')]) }))
}

function walk(node, path, inheritedType, out) {
  if (node === null || typeof node !== 'object' || Array.isArray(node)) {
    throw new Error(`tokens.json: ${path.join('.') || '<корень>'} — ожидалась группа или токен`)
  }
  const type = node.$type ?? inheritedType
  if ('$value' in node) {
    if (type === undefined) throw new Error(`tokens.json: у ${path.join('.')} нет $type`)
    out.push({
      path,
      type,
      value: node.$value,
      ...(node.$description ? { description: node.$description } : {}),
      derived: node.$extensions?.fittrack?.origin === 'derived',
    })
    return
  }
  for (const [key, child] of Object.entries(node)) {
    if (!isMeta(key)) walk(child, [...path, key], type, out)
  }
}

const ALIAS = /^\{([^}]+)\}$/

function resolve(value, byPath, seen) {
  if (typeof value === 'string') {
    const alias = ALIAS.exec(value)
    if (!alias) return value
    const target = byPath.get(alias[1])
    if (!target) throw new Error(`tokens.json: ссылка ${value} никуда не ведёт`)
    if (seen.includes(alias[1])) throw new Error(`tokens.json: цикл ссылок через ${value}`)
    return resolve(target.value, byPath, [...seen, alias[1]])
  }
  if (Array.isArray(value)) return value.map((v) => resolve(v, byPath, seen))
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, resolve(v, byPath, seen)]))
  }
  return value
}
