// Форматирование для показа. Ничего не считает по домену: только переводит
// готовые значения сервера в строку экрана.

/** «понедельник, 12 октября» для локальной даты `YYYY-MM-DD` карточки дня. */
export function formatDayHeading(isoDate: string): string {
  const [y, m, d] = isoDate.split('-').map(Number) as [number, number, number]
  // Дата календарная, без времени: читается и печатается в UTC, иначе зона
  // браузера сдвинула бы её на сутки.
  return new Intl.DateTimeFormat('ru-RU', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' }).format(
    new Date(Date.UTC(y, m - 1, d)),
  )
}

/** «40 мин» для оценки длительности в секундах; меньше минуты — «1 мин». */
export function formatMinutes(seconds: number): string {
  return `${Math.max(1, Math.round(seconds / 60))} мин`
}
