// Supabase Auth (SPEC §20.5; web-domain §3.7).
//
// Анонимный вход с первого экрана: онбординг и PAR-Q проходятся анонимно,
// `auth.uid()` настоящий, RLS работает. Привязка аккаунта (email magic link) —
// срез 2. Сессию хранит supabase-js (refresh-токен лежит в `localStorage`, и
// его сносит очистка данных сайта — ровно поэтому линковка обязательна до
// первой тренировки, §4.2).

import { createClient, type Session } from '@supabase/supabase-js'

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY,
  { auth: { persistSession: true, autoRefreshToken: true } },
)

/** Токен текущей сессии для `Authorization: Bearer` или `null`. */
export async function accessToken(): Promise<string | null> {
  const { data } = await supabase.auth.getSession()
  return data.session?.access_token ?? null
}

let pending: Promise<Session> | null = null

/**
 * Возвращает живую сессию, заводя анонимную, если её нет.
 *
 * Вызов один на процесс: StrictMode и повторные монтирования иначе завели бы
 * двух анонимных пользователей подряд, и первый остался бы сиротой.
 */
export function ensureSession(): Promise<Session> {
  pending ??= (async () => {
    const { data: existing } = await supabase.auth.getSession()
    if (existing.session) return existing.session
    const { data, error } = await supabase.auth.signInAnonymously()
    if (error || !data.session) {
      throw new Error(`Анонимный вход не удался: ${error?.message ?? 'нет сессии'}`)
    }
    return data.session
  })().catch((e: unknown) => {
    pending = null
    throw e
  })
  return pending
}

/** `auth.uid()` текущей сессии: ключ строк, которые клиент пишет напрямую. */
export async function currentUserId(): Promise<string> {
  const { data } = await supabase.auth.getUser()
  if (!data.user) throw new Error('Нет сессии')
  return data.user.id
}
