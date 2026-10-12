// Экран привязки аккаунта (SPEC §20.5), срез 2.
//
// Показывается на `unlinked_account` от `POST /v1/workouts`: «Начать» требует
// привязанного аккаунта, потому что защищается история тренировок, а не план.
// Визуальные решения — токены web-domain §8.

import { useEffect, useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import { accountState, requestEmailLink, type AccountState } from '../../auth/link'
import { supabase } from '../../auth/supabase'

export function LinkScreen() {
  const [email, setEmail] = useState('')
  const [account, setAccount] = useState<AccountState | null>(null)
  const [sentTo, setSentTo] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      if (data.user) setAccount(accountState(data.user))
    })
  }, [])

  async function submit(event: FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await requestEmailLink(supabase.auth, email, window.location.origin)
      setSentTo(email.trim())
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось отправить письмо')
    } finally {
      setBusy(false)
    }
  }

  if (account && !account.anonymous) {
    return (
      <main>
        <h1>Аккаунт</h1>
        <p data-testid="account-linked" className="card">Аккаунт привязан{account.email ? `: ${account.email}` : ''}.</p>
        <p>
          <Link to="/" className="link-back">
            К тренировке
          </Link>
        </p>
      </main>
    )
  }

  return (
    <main>
      <h1>Сохранить прогресс</h1>
      <p className="caption">
        Чтобы начать тренировку, привяжите почту: так история не потеряется, если очистить данные сайта.
      </p>
      {sentTo ? (
        <p role="status" data-testid="link-sent" className="notice">
          Письмо отправлено на {sentTo}. Перейдите по ссылке из письма, затем вернитесь сюда и нажмите «Начать».
        </p>
      ) : (
        <form onSubmit={submit} className="card">
          <label className="field">
            Почта
            <input
              type="email"
              name="email"
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
            />
          </label>
          <button type="submit" className="button-primary" disabled={busy}>
            Отправить ссылку
          </button>
        </form>
      )}
      {error && <p role="alert">{error}</p>}
      <p>
        <Link to="/" className="link-back">
          Назад
        </Link>
      </p>
    </main>
  )
}
