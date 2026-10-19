// Проигрыватель сессии растяжки (SPEC §12.2): одна поза на экран, крупный
// таймер от абсолютной метки (как таймер отдыха §13.3), автопереход, «+15 сек»
// и «Пропустить», смена стороны текстом, экран не гаснет. Ввода данных нет.
//
// Сессия пишется на сервер дважды: старт при открытии и завершение в конце.
// `id` создаётся до первой отправки и повторяется при повторе (§20.3). Очереди
// нет (§20.10): обрыв — явное состояние с кнопкой «Повторить».

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
  const wakeLock = useWakeLock(!finished)

  // Старт — мутация: повтор после обрыва идёт с тем же `id` (§20.3), а отсчёт
  // первой позы начинается, когда сервер сессию принял.
  const startSession = useMutation({
    mutationFn: () => api.startStretchSession(id.current, kind, templateSlug),
    onSuccess: () => setEndAt(now() + steps[0]!.seconds * 1000),
  })
  const started = startSession.isSuccess
  const failure = startSession.error ?? finishFailure

  async function finish() {
    try {
      await api.finishStretchSession(id.current)
      setFinished(true)
      await queryClient.invalidateQueries({ queryKey: ['stretch-history'] })
      await queryClient.invalidateQueries({ queryKey: ['progress'] })
    } catch (e) {
      setFinishFailure(e)
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
    if (!started || finished || failure !== null) return
    const tick = () => {
      const remaining = secondsLeft(endAt, now())
      setLeft(remaining)
      if (remaining === 0) goTo(index + 1)
    }
    tick()
    const timer = setInterval(tick, 250)
    return () => clearInterval(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [started, finished, failure, endAt, index])

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
      <section className="exercise" aria-label="Сессия растяжки" data-testid="stretch-player">
        <p className="caption" data-testid="stretch-progress">
          {title} · {index + 1} из {steps.length}
        </p>
        <h2 className="exercise-title" data-testid="stretch-pose">
          {pose?.name ?? step.pose}
        </h2>
        {caption && (
          <p className="chip" data-testid="stretch-caption">
            {caption}
          </p>
        )}
        <ExerciseFrames content={pose} />
        <p className="reps" data-testid="stretch-clock" aria-live="polite">
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
          <button type="button" className="button-text" disabled={!started}
            onClick={() => setEndAt((e) => e + EXTEND_STEP_SECONDS * 1000)}>
            +15 сек
          </button>
          <button type="button" className="button-text" disabled={!started} onClick={() => goTo(index + 1)}>
            Пропустить
          </button>
        </div>
        {wakeLock === 'active' && <p className="caption" data-testid="wake-lock">Экран не погаснет</p>}
        {failure !== null && (
          <div role="alert" data-testid="stretch-failure">
            <p>{failureText(failure)}</p>
            <button type="button" className="button-primary" onClick={() => {
              if (started) {
                setFinishFailure(null)
                void finish()
              } else {
                startSession.mutate()
              }
            }}>
              Повторить
            </button>
          </div>
        )}
      </section>
    </main>
  )
}
