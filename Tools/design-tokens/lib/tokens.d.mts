export interface FlatToken {
  path: string[]
  type: string
  value: unknown
  description?: string
  /** Выведено из решённых значений, а не задано решением по дизайну. */
  derived: boolean
}

export function flattenTokens(source: unknown): FlatToken[]
