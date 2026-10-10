// Единственное место, где клиент называет «сегодня» (SPEC §20.7; web-domain §3.1).
//
// Локальная дата и IANA-зона идут в каждом запросе, где день имеет значение.
// Пара собирается ЗДЕСЬ и нигде больше: две копии расходятся ровно на полуночи.
// Сервер сравнивает её со своими часами и отклоняет расхождение больше суток
// (`date_skew`); подменять дату на клиенте нельзя.

export interface DayContext {
  /** Локальная дата `YYYY-MM-DD` в зоне `tz`. */
  date: string
  /** IANA-зона, например `Europe/Moscow`. */
  tz: string
}

/** Зона браузера. Если она недоступна, запрос не отправляется: гадать нельзя. */
export function browserTimeZone(): string {
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
  if (!tz) throw new Error('Не удалось определить часовой пояс')
  return tz
}

/** Календарная дата момента `now` в зоне `tz`, `YYYY-MM-DD`. */
export function localDate(now: Date, tz: string): string {
  // `en-CA` даёт ISO-порядок полей; зона задаётся явно, а не берётся из системы.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(now)
}

export function currentDay(now: Date = new Date(), tz: string = browserTimeZone()): DayContext {
  return { date: localDate(now, tz), tz }
}

/** Понедельник недели, в которую входит `date` (ISO-неделя), `YYYY-MM-DD`. */
export function mondayOf(date: string): string {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number]
  const utc = new Date(Date.UTC(y, m - 1, d))
  const isoWeekday = ((utc.getUTCDay() + 6) % 7) + 1 // 1 = понедельник
  utc.setUTCDate(utc.getUTCDate() - (isoWeekday - 1))
  return utc.toISOString().slice(0, 10)
}

/** ISO-номер дня недели для `YYYY-MM-DD`: 1 = понедельник … 7 = воскресенье. */
export function isoWeekday(date: string): number {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number]
  return ((new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7) + 1
}
