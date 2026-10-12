// Таймер отдыха (SPEC §13.3; web-domain §3.9): отсчёт от абсолютной метки.

import { useEffect, useRef, useState } from 'react'
import { EXTEND_SECONDS, formatClock, remainingSeconds, signalsBetween } from '../../workout/rest'

function vibrate(pattern: number | number[]) {
  try {
    navigator.vibrate?.(pattern)
  } catch {
    // Вибрации может не быть (десктоп, iOS Safari): сигнал звуком остаётся.
  }
}

function beep() {
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
    if (!Ctx) return
    const ctx = new Ctx()
    const osc = ctx.createOscillator()
    osc.frequency.value = 880
    osc.connect(ctx.destination)
    osc.start()
    osc.stop(ctx.currentTime + 0.25)
    osc.onended = () => void ctx.close()
  } catch {
    // Звук необязателен.
  }
}

export function RestTimer({
  endAt,
  nextWeightKg,
  onExtend,
  onSkip,
}: {
  /** Абсолютная метка конца отдыха, мс от эпохи. */
  endAt: number
  /** Вес следующего подхода из дерева; без веса или без следующего подхода — нет. */
  nextWeightKg?: number
  onExtend: (seconds: number) => void
  onSkip: () => void
}) {
  const [left, setLeft] = useState(() => remainingSeconds(endAt, Date.now()))
  const previous = useRef(left)

  useEffect(() => {
    // Значение считается из метки на каждом тике, а не вычитанием: после
    // заморозки вкладки первый же тик показывает верное время.
    const tick = () => {
      const next = remainingSeconds(endAt, Date.now())
      const signals = signalsBetween(previous.current, next)
      if (signals.warn) vibrate(100)
      if (signals.done) {
        vibrate([200, 100, 200])
        beep()
      }
      previous.current = next
      setLeft(next)
    }
    tick()
    const id = window.setInterval(tick, 250)
    document.addEventListener('visibilitychange', tick)
    return () => {
      window.clearInterval(id)
      document.removeEventListener('visibilitychange', tick)
    }
  }, [endAt])

  return (
    <section aria-label="Отдых" className="card rest">
      <p data-testid="rest-clock" role="timer" className="rest-clock">
        {left > 0 ? (
          <>
            <span className="caption">Отдых</span> {formatClock(left)}
          </>
        ) : (
          <span className="hero-text">Отдых закончился</span>
        )}
      </p>
      {/* Только во время отдыха (решение по дизайну): подход уже записан, и
          вес следующего известен из дерева, а не угадан до фидбэка. */}
      {left > 0 && nextWeightKg !== undefined && (
        <p data-testid="next-set">
          Следующий подход: <span className="row-weight">{nextWeightKg} кг</span>
        </p>
      )}
      <div className="button-row">
        <button type="button" onClick={() => onExtend(EXTEND_SECONDS)}>
          +30 сек
        </button>
        <button type="button" onClick={onSkip}>
          Пропустить
        </button>
      </div>
    </section>
  )
}
