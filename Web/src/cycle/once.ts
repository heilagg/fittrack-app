// «Спрашиваем один раз» (SPEC §11.6, §19.2 п.27): вопрос «Месячные уже
// начались?» — один раз на ожидаемую дату, предложение включить цикл при
// `declined` — один раз вообще. Признак живёт в `localStorage`: это удобство
// одного зрителя, и повтор на другом устройстве или после очистки данных
// вреда не несёт. Любое обращение — в `try/catch`: хранилище может быть
// недоступно (приватный режим), и тогда вопрос просто задаётся снова.
//
// Отмечается ответ, а не показ: вопрос, который открыли и не заметили, не
// считается заданным.

export interface FlagStore {
  get(key: string): string | null
  set(key: string, value: string): void
}

export const browserStore: FlagStore = {
  get(key) {
    try {
      return window.localStorage.getItem(key)
    } catch {
      return null
    }
  },
  set(key, value) {
    try {
      window.localStorage.setItem(key, value)
    } catch {
      // Недоступно — вопрос повторится, это безопасный исход.
    }
  },
}

const overdueKey = (expected: string) => `fittrack.cycle.overdue-asked.${expected}`
const declinedOfferKey = 'fittrack.cycle.declined-offer-answered'

/** Задавать ли «Месячные уже начались?»: сервер сказал `overdue`, а на эту дату ещё не отвечали. */
export function shouldAskOverdue(
  calendar: { overdue: boolean; next_period?: { expected: string } | undefined },
  store: FlagStore,
): boolean {
  if (!calendar.overdue || !calendar.next_period) return false
  return store.get(overdueKey(calendar.next_period.expected)) === null
}

export function markOverdueAnswered(expected: string, store: FlagStore): void {
  store.set(overdueKey(expected), '1')
}

export function shouldOfferEnable(store: FlagStore): boolean {
  return store.get(declinedOfferKey) === null
}

export function markEnableOfferAnswered(store: FlagStore): void {
  store.set(declinedOfferKey, '1')
}
