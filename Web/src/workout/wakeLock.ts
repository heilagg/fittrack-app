// Screen Wake Lock (SPEC §13.2, §20.12; web-domain §1).
//
// Запрашивается на входе в тренировку и отпускается на выходе. Браузер снимает
// блокировку сам, когда вкладка уходит в фон, поэтому при возврате она
// запрашивается заново.

import { useEffect, useState } from 'react'

export type WakeLockState = 'active' | 'unsupported' | 'denied' | 'idle'

interface WakeLockSentinelLike {
  release(): Promise<void>
  addEventListener?(type: 'release', listener: () => void): void
}
interface WakeLockApi {
  request(type: 'screen'): Promise<WakeLockSentinelLike>
}

export function useWakeLock(enabled: boolean): WakeLockState {
  const api = (navigator as unknown as { wakeLock?: WakeLockApi }).wakeLock
  const [state, setState] = useState<WakeLockState>(api ? 'idle' : 'unsupported')

  useEffect(() => {
    if (!enabled || !api) return
    let sentinel: WakeLockSentinelLike | null = null
    let cancelled = false

    async function acquire() {
      try {
        const lock = await api!.request('screen')
        if (cancelled) {
          await lock.release()
          return
        }
        sentinel = lock
        // Браузер снимает блокировку сам, когда вкладка уходит в фон: без
        // этого «возврат» не запросил бы её заново.
        lock.addEventListener?.('release', () => {
          sentinel = null
        })
        setState('active')
      } catch {
        // Отказ (заряд, политика) — не ошибка тренировки: показываем состояние.
        if (!cancelled) setState('denied')
      }
    }

    const onVisible = () => {
      if (document.visibilityState === 'visible' && sentinel === null) void acquire()
    }
    void acquire()
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      cancelled = true
      document.removeEventListener('visibilitychange', onVisible)
      void sentinel?.release()
      sentinel = null
    }
  }, [enabled, api])

  return state
}
