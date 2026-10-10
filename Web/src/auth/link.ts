// Привязка анонимного аккаунта к email (SPEC §20.5; web-domain §3.7).
//
// Единственный способ завести аккаунт — email magic link, и `auth.uid()` при
// этом не меняется: `updateUser({email})` превращает ТЕКУЩЕГО анонимного
// пользователя в постоянного, а не создаёт нового (`signInWithOtp` создал бы
// второго пользователя и оставил историю на первом). Письмо уходит на новый
// адрес, ссылка из него возвращает на `redirectTo` с сессией в хеше, и
// supabase-js подхватывает её сам.
//
// Для этого проекту нужен `enable_confirmations = true` (Supabase/config.toml):
// иначе адрес привязывается мгновенно и без письма.

import type { SupabaseClient, User } from '@supabase/supabase-js'

export type AuthLike = Pick<SupabaseClient['auth'], 'updateUser' | 'getUser'>

/** Отправляет письмо со ссылкой. Ошибку Supabase пробрасывает как есть. */
export async function requestEmailLink(auth: AuthLike, email: string, redirectTo: string): Promise<void> {
  const trimmed = email.trim()
  if (!trimmed.includes('@')) throw new Error('Введите адрес электронной почты')
  const { error } = await auth.updateUser({ email: trimmed }, { emailRedirectTo: redirectTo })
  if (error) throw new Error(error.message)
}

export interface AccountState {
  /** Анонимный аккаунт: «Начать тренировку» его не пропустит. */
  anonymous: boolean
  email: string | null
}

export function accountState(user: Pick<User, 'is_anonymous' | 'email'>): AccountState {
  return { anonymous: user.is_anonymous ?? false, email: user.email || null }
}
