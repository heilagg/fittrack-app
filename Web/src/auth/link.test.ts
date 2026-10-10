import { describe, expect, it, vi } from 'vitest'
import { accountState, requestEmailLink, type AuthLike } from './link'

function fakeAuth(error: { message: string } | null = null) {
  const updateUser = vi.fn(async () => ({ data: { user: null }, error }))
  return { auth: { updateUser, getUser: vi.fn() } as unknown as AuthLike, updateUser }
}

describe('привязка аккаунта', () => {
  it('письмо запрашивается через updateUser с адресом и redirectTo', async () => {
    const { auth, updateUser } = fakeAuth()
    await requestEmailLink(auth, '  anna@example.com ', 'http://127.0.0.1:5173')
    expect(updateUser).toHaveBeenCalledWith(
      { email: 'anna@example.com' },
      { emailRedirectTo: 'http://127.0.0.1:5173' },
    )
  })

  it('адрес без @ отклоняется до запроса', async () => {
    const { auth, updateUser } = fakeAuth()
    await expect(requestEmailLink(auth, 'anna', 'http://x')).rejects.toThrow()
    expect(updateUser).not.toHaveBeenCalled()
  })

  it('ошибка Supabase пробрасывается текстом', async () => {
    const { auth } = fakeAuth({ message: 'A user with this email address has already been registered' })
    await expect(requestEmailLink(auth, 'a@b.c', 'http://x')).rejects.toThrow(/already been registered/)
  })

  it('анонимность читается из пользователя, пустой email — null', () => {
    expect(accountState({ is_anonymous: true, email: '' })).toEqual({ anonymous: true, email: null })
    expect(accountState({ is_anonymous: false, email: 'a@b.c' })).toEqual({ anonymous: false, email: 'a@b.c' })
  })
})
