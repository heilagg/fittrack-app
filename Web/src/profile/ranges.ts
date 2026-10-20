// Диапазоны полей профиля (SPEC §20.3, миграция 0016). Сервер отвечает на
// выход за них 422, схема держит те же check'и; клиент проверяет до отправки,
// чтобы показать ошибку поля словами, а не кодом. Одно место на онбординг и
// Профиль: два набора пределов уже разошлись однажды (вес 30–400 против 20–300).

export const BIRTH_YEAR_MIN = 1936
/** Моложе 14 лет приложение не рассчитано (§5): верхняя граница — текущий год минус 14. */
export const MIN_AGE_YEARS = 14
export const HEIGHT_CM = { min: 100, max: 250 } as const
export const BODY_WEIGHT_KG = { min: 20, max: 300 } as const
export const SESSION_MINUTES = { min: 10, max: 180 } as const

/** Текст ошибки поля или `null`, если значение в диапазоне. */
export function birthYearProblem(year: number, now: Date = new Date()): string | null {
  const max = now.getFullYear() - MIN_AGE_YEARS
  return Number.isInteger(year) && year >= BIRTH_YEAR_MIN && year <= max
    ? null
    : `Год рождения — от ${BIRTH_YEAR_MIN} до ${max}`
}

export function heightProblem(cm: number): string | null {
  return cm >= HEIGHT_CM.min && cm <= HEIGHT_CM.max ? null : `Рост — от ${HEIGHT_CM.min} до ${HEIGHT_CM.max} см`
}

export function bodyWeightProblem(kg: number): string | null {
  return kg >= BODY_WEIGHT_KG.min && kg <= BODY_WEIGHT_KG.max
    ? null
    : `Вес — от ${BODY_WEIGHT_KG.min} до ${BODY_WEIGHT_KG.max} кг`
}

export function sessionMinutesProblem(minutes: number): string | null {
  return Number.isInteger(minutes) && minutes >= SESSION_MINUTES.min && minutes <= SESSION_MINUTES.max
    ? null
    : `Длительность — от ${SESSION_MINUTES.min} до ${SESSION_MINUTES.max} минут`
}
