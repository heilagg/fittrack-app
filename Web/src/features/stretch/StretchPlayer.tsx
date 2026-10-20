// Проигрыватель сессии растяжки (SPEC §12.2): одна поза на экран, крупный
// таймер от абсолютной метки (как таймер отдыха §13.3), автопереход, «+15 сек»
// и «Пропустить», смена стороны текстом, экран не гаснет. Ввода данных нет.
//
// Сессия пишется на сервер дважды: старт при открытии и завершение в конце.
// `id` создаётся до первой отправки и повторяется при повторе (§20.3). Очереди
// нет (§20.10): обрыв — явное состояние с кнопкой «Повторить». Профиль не
// настроен — повтор не поможет, вместо него ссылка на онбординг.
//
// Завершение уходит ровно один раз: пока ответа нет, отсчёт стоит, кнопки
// заблокированы, а на экране сказано, что идёт запись.

import { useEffect, useRef, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Link, useLocation, useParams } from 'react-router-dom'
import { ApiError, NetworkError, type ApiClient } from '../../api/client'
import type { CooldownPose } from '../../api/schemas'
import { cooldownTimeline, EXTEND_STEP_SECONDS, secondsLeft, stepCaption, timelineOf, type Step } from '../../stretch/timeline'
import { useWakeLock } from '../../workout/wakeLock'
import { formatClock } from '../../workout/rest'
import { ExerciseFrames } from '../workout/Illustration'
import { ErrorBlock } from '../today/TodayScreen'
import { useStretchContent } from './useStretchContent'

function failureText(error: unknown): string {
  if (error instanceof NetworkError) return 'Нет связи с сервером — повторите.'
  if (error instanceof ApiError) return error.message
  return error instanceof Error ? error.message : 'Не удалось записать сессию'
}

export function StretchPlayer({ api, now = () => Date.now() }: { api: ApiClient; now?: () => number }) {
  const { slug } = useParams()
  const location = useLocation()
  const cooldown = (location.state as { cooldown?: CooldownPose[] } | null)?.cooldown
  const content = useStretchContent(api)

  if (content.isPending) return <p role="status">Загрузка…</p>
  if (content.isError) return <ErrorBlock error={content.error} />

  const template = slug ? content.data.templates.find((t) => t.slug === slug) : undefined
  const steps = template
    ? timelineOf(template.items, content.data.poseBySlug)
    : cooldownTimeline(cooldown ?? [], content.data.poseBySlug)
  if (steps.length === 0) {
    return (
      <main>
        <p className="card" data-testid="stretch-nothing">Растяжки для этой сессии нет.</p>
        <Link to="/stretch">К растяжке</Link>
      </main>
    )
  }
  return (
    <Player
      api={api}
      steps={steps}
      title={template?.name ?? 'Заминка'}
      kind={template ? 'standalone' : 'static_cooldown'}
      templateSlug={template?.slug}
      poses={content.data.poseBySlug}
      now={now}
    />
  )
}

function Player({
  api, steps, title, kind, templateSlug, poses, now,
}: {
  api: ApiClient
  steps: Step[]
  title: string
  kind: 'standalone' | 'static_cooldown'
  templateSlug?: string
  poses: Map<string, { name: string; cues: string[]; illustration: string; kind: string }>
  now: () => number
}) {
  const queryClient = useQueryClient()
  const id = useRef(crypto.randomUUID())
  const [finishFailure, setFinishFailure] = useState<unknown>(null)
  const [index, setIndex] = useState(0)
  const [endAt, setEndAt] = useState(() => now() + steps[0]!.seconds * 1000)
  const [left, setLeft] = useState(steps[0]!.seconds)
  const [finished, setFinished] = useState(false)
  // Ref — защита от второго вызова в том же такте, state — для экрана.
  const finishing = useRef(false)
  const [saving, setSaving] = useState(false)

  // Старт — мутация: повтор после обрыва идёт с тем же `id` (§20.3), а отсчёт
  // первой позы начинается, когда сервер сессию принял.
  const startSession = useMutation({
    mutationFn: () => api.startStretchSession(id.current, kind, templateSlug),
    onSuccess: () => setEndAt(now() + steps[0]!.seconds * 1000),
  })
  const started = startSession.isSuccess
  const failure = startSession.error ?? finishFailure
  const needsSetup = failure instanceof ApiError && failure.code === 'profile_incomplete'
  const wakeLock = useWakeLock(started && !finished)

  async function finish() {
    if (finishing.current) return
    finishing.current = true
    setSaving(true)
    setFinishFailure(null)
    try {
      await api.finishStretchSession(id.current)
      setFinished(true)
      await queryClient.invalidateQueries({ queryKey: ['stretch-history'] })
      await queryClient.invalidateQueries({ queryKey: ['progress'] })
    } catch (e) {
      finishing.current = false
      setFinishFailure(e)
    } finally {
      setSaving(false)
    }
  }

  function goTo(next: number) {
    if (next >= steps.length) {
      void finish()
      return
    }
    setIndex(next)
    setEndAt(now() + steps[next]!.seconds * 1000)
  }

  useEffect(() => {
    startSession.mutate()
    // Старт ровно один раз на открытие: повтор — кнопкой при обрыве.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    if (!started || finished || saving || failure !== null) return
    const tick = () => {
      const remaining = secondsLeft(endAt, now())
      setLeft(remaining)
      if (remaining === 0) goTo(index + 1)
    }
    tick()
    const timer = setInterval(tick, 250)
    return () => clearInterval(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [started, finished, saving, failure, endAt, index])

  if (finished) {
    return (
      <main>
        <section className="exercise" data-testid="stretch-done">
          <h1 className="screen-title">Готово</h1>
          <p className="caption">{title} завершена.</p>
          <Link to="/stretch" className="button-primary">
            К растяжке
          </Link>
        </section>
      </main>
    )
  }

  const step = steps[index]!
  const pose = poses.get(step.pose)
  const caption = stepCaption(step)
  return (
    <main>
      <p>
        {/* Выход посреди сессии: незавершённая сессия на сервере остаётся без
            `finished_at` и в историю не попадает (§12.2). */}
        <Link to={kind === 'standalone' ? '/stretch' : '/'} className="link-back" data-testid="stretch-exit">
          Выйти
        </Link>
      </p>
      <section className="exercise" aria-label="Сессия растяжки" data-testid="stretch-player">
        {/* Смена позы объявляется здесь; часы — `timer`, вслух каждую секунду не читаются. */}
        <p className="caption" data-testid="stretch-progress" aria-live="polite">
          {title} · {index + 1} из {steps.length} · {pose?.name ?? step.pose}
        </p>
        <h1 className="exercise-title" data-testid="stretch-pose">
          {pose?.name ?? step.pose}
        </h1>
        {caption && (
          <p className="chip" data-testid="stretch-caption">
            {caption}
          </p>
        )}
        <ExerciseFrames content={pose} />
        <p className="stretch-clock" data-testid="stretch-clock" role="timer">
          {formatClock(left)}
        </p>
        {pose && pose.cues.length > 0 && step.phase !== 'rest' && (
          <ul className="cues caption">
            {pose.cues.map((cue, i) => (
              <li key={i}>{cue}</li>
            ))}
          </ul>
        )}
        <div className="button-row">
          <button type="button" className="button-text" disabled={!started || saving}
            onClick={() => setEndAt((e) => e + EXTEND_STEP_SECONDS * 1000)}>
            +15 сек
          </button>
          <button type="button" className="button-text" disabled={!started || saving} onClick={() => goTo(index + 1)}>
            Пропустить
          </button>
        </div>
        {saving && <p role="status" className="caption" data-testid="stretch-saving">Записываем сессию…</p>}
        {wakeLock === 'active' && <p className="caption" data-testid="wake-lock">Экран не погаснет</p>}
        {failure !== null && (
          <div role="alert" data-testid="stretch-failure">
            <p>{failureText(failure)}</p>
            {needsSetup ? (
              <Link to="/onboarding" className="button-primary" data-testid="stretch-onboarding">
                Перейти к настройке
              </Link>
            ) : (
              <button type="button" className="button-primary" onClick={() => (started ? void finish() : startSession.mutate())}>
                Повторить
              </button>
            )}
          </div>
        )}
      </section>
    </main>
  )
}
