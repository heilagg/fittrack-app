// Таймер отдыха (SPEC §13.3, §20.12; web-domain §3.9).
//
// Правило длительности — то же, что у бюджета времени планировщика §7.3, и
// границы строгие: ниже 0.9 — ×1.2, выше 1.05 — ×0.8, иначе ×1.0. Фидбэк
// «тяжело» добавляет 30 секунд (в бюджет они не входят: на сборке их знать
// нельзя).
//
// Конец отсчёта — АБСОЛЮТНАЯ метка времени, а не счётчик тиков: свёрнутая
// вкладка в iOS Safari замораживает таймеры, и счётчик по тикам после
// разворачивания отстал бы ровно на время в кармане.

import type { Feedback } from './tree'

export const HARD_EXTRA_SECONDS = 30
export const EXTEND_SECONDS = 30
export const WARN_AT_SECONDS = 10

export function readinessFactor(weightReadiness: number): number {
  if (weightReadiness < 0.9) return 1.2
  if (weightReadiness > 1.05) return 0.8
  return 1.0
}

/** Длительность отдыха после подхода, секунды. */
export function restDuration(defaultRestSeconds: number, weightReadiness: number, feedback: Feedback): number {
  const base = Math.round(defaultRestSeconds * readinessFactor(weightReadiness))
  return base + (feedback === 'hard' ? HARD_EXTRA_SECONDS : 0)
}

/** Сколько секунд осталось до абсолютной метки; не меньше нуля. */
export function remainingSeconds(endAtMs: number, nowMs: number): number {
  return Math.max(0, Math.ceil((endAtMs - nowMs) / 1000))
}

/** Какие сигналы пора подать при переходе от `prev` секунд к `next` оставшихся. */
export function signalsBetween(prev: number, next: number): { warn: boolean; done: boolean } {
  return {
    warn: prev > WARN_AT_SECONDS && next <= WARN_AT_SECONDS && next > 0,
    done: prev > 0 && next === 0,
  }
}

export function formatClock(seconds: number): string {
  const m = Math.floor(seconds / 60)
  const s = seconds % 60
  return `${m}:${String(s).padStart(2, '0')}`
}
