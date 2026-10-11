import { describe, expect, it } from 'vitest'
import { formatClock, readinessFactor, remainingSeconds, restDuration, signalsBetween } from './rest'

describe('множитель отдыха (§13.3): границы строгие', () => {
  it('ниже 0.9 — ×1.2', () => {
    expect(readinessFactor(0.89)).toBe(1.2)
    expect(readinessFactor(0.5)).toBe(1.2)
  })
  it('ровно 0.9 и ровно 1.05 — ×1.0', () => {
    expect(readinessFactor(0.9)).toBe(1.0)
    expect(readinessFactor(1.0)).toBe(1.0)
    expect(readinessFactor(1.05)).toBe(1.0)
  })
  it('выше 1.05 — ×0.8', () => {
    expect(readinessFactor(1.06)).toBe(0.8)
    expect(readinessFactor(1.2)).toBe(0.8)
  })
})

describe('длительность отдыха', () => {
  it('базовая — default_rest_seconds × множитель', () => {
    expect(restDuration(120, 1.0, 'ok')).toBe(120)
    expect(restDuration(120, 0.8, 'ok')).toBe(144)
    expect(restDuration(120, 1.1, 'easy')).toBe(96)
  })
  it('«тяжело» добавляет 30 секунд, остальные фидбэки — нет', () => {
    expect(restDuration(90, 1.0, 'hard')).toBe(120)
    expect(restDuration(90, 1.0, 'failed')).toBe(90)
    expect(restDuration(90, 1.0, 'easy')).toBe(90)
  })
  it('надбавка «тяжело» складывается с множителем готовности', () => {
    expect(restDuration(90, 0.8, 'hard')).toBe(108 + 30)
  })
})

describe('отсчёт от абсолютной метки', () => {
  it('остаток — разность метки и текущего времени, а не число тиков', () => {
    const end = 1_000_000 + 90_000
    expect(remainingSeconds(end, 1_000_000)).toBe(90)
    // Вкладку «заморозили» на минуту: первый же замер показывает верный остаток.
    expect(remainingSeconds(end, 1_000_000 + 60_000)).toBe(30)
  })
  it('после конца — ноль, не отрицательное', () => {
    expect(remainingSeconds(1000, 5000)).toBe(0)
  })
  it('дробные секунды округляются вверх: 0:00 показывается только в конце', () => {
    expect(remainingSeconds(10_500, 10_000)).toBe(1)
  })
})

describe('сигналы', () => {
  it('предупреждение — один раз при переходе через 10 секунд', () => {
    expect(signalsBetween(11, 10)).toEqual({ warn: true, done: false })
    expect(signalsBetween(10, 9)).toEqual({ warn: false, done: false })
  })
  it('окончание — при переходе в ноль', () => {
    expect(signalsBetween(1, 0)).toEqual({ warn: false, done: true })
    expect(signalsBetween(0, 0)).toEqual({ warn: false, done: false })
  })
  it('скачок через оба порога (вкладка в кармане) даёт только окончание', () => {
    expect(signalsBetween(30, 0)).toEqual({ warn: false, done: true })
  })
})

describe('вывод', () => {
  it('минуты и секунды', () => {
    expect(formatClock(0)).toBe('0:00')
    expect(formatClock(75)).toBe('1:15')
    expect(formatClock(600)).toBe('10:00')
  })
})
