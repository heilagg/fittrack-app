// Ввод веса числом (SPEC §13.2, §19.2 п.23 (в), §20.3).
//
// Лестницы достижимых весов у клиента нет и быть не должно (§20.1): клиент
// принимает любое число в диапазоне, а к ступени его округляет сервер и
// возвращает записанное. Здесь — только разбор того, что набрано, и граница
// диапазона §20.3, чтобы не слать заведомый отказ.

export const WEIGHT_MIN_KG = 0
export const WEIGHT_MAX_KG = 500

/** Набранное поле в килограммы: запятая или точка; вне 0–500 или не число — `null`. */
export function parseWeight(text: string): number | null {
  const normalized = text.trim().replace(',', '.')
  if (!/^\d+(\.\d+)?$/.test(normalized)) return null
  const kg = Number(normalized)
  return kg >= WEIGHT_MIN_KG && kg <= WEIGHT_MAX_KG ? kg : null
}

/** Килограммы в поле ввода — с запятой, как их набирают по-русски. */
export function formatWeight(kg: number): string {
  return String(kg).replace('.', ',')
}
