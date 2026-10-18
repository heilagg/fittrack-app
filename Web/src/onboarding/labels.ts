// Подписи вариантов, которые видит пользовательница, и их значения в базе
// (SPEC §5, шаг 4; §6.6). Одно место на онбординг и Профиль: две копии
// разошлись бы на первой же правке формулировки.

/** Шаг 4 (§5): вопрос про срок, а не про самооценку. */
export const EXPERIENCE_QUESTION = 'Как давно вы занимаетесь в зале?'

export const EXPERIENCE_OPTIONS = [
  { value: 'novice', label: 'Меньше 6 месяцев' },
  { value: 'intermediate', label: 'От 6 месяцев до 2 лет' },
  { value: 'advanced', label: 'Больше 2 лет' },
] as const

/** Русские названия тренажёров (§6.6); в базу пишется слаг. Эталон —
 * `Contract/fixtures/equipment_machine_names.json` из FitAPI: таблица остаётся
 * здесь ради Профиля и онбординга и сверяется с ним тестом (`labels.test.ts`). */
export const MACHINE_LABELS: Record<string, string> = {
  leg_press: 'Жим ногами',
  leg_extension: 'Разгибание ног',
  leg_curl: 'Сгибание ног',
  hip_abduction: 'Разведение ног',
  calf_raise: 'Подъём на носки',
  lat_pulldown: 'Верхний блок',
  seated_row: 'Горизонтальная тяга',
  back_extension: 'Гиперэкстензия',
  chest_press: 'Жим от груди',
  pec_deck: 'Бабочка',
  shoulder_press: 'Жим над головой',
  ab_crunch: 'Тренажёр для пресса',
  hip_adduction: 'Сведение ног',
  chest_supported_row: 'Тяга в тренажёре с упором грудью',
  assisted_pullup: 'Гравитрон',
  smith: 'Тренажёр Смита',
}

/** Схема тренировок в Профиле (§7.2, §13.1). */
export const TRAINING_SPLIT_OPTIONS = [
  { value: 'auto', label: 'Авто' },
  { value: 'full_body', label: 'Всё тело' },
  { value: 'upper_lower', label: 'Верх и низ' },
  { value: 'push_pull_legs', label: 'Пуш пулл ноги' },
] as const

/**
 * Где схема подменяется (§7.2): при таком числе дней собирается другое, и
 * интерфейс говорит об этом при выборе. Сетку клиент не строит — это две
 * строки текста SPEC, а не расстановка.
 */
export function trainingSplitNote(split: string, days: number): string | null {
  if (days === 1 && (split === 'upper_lower' || split === 'push_pull_legs')) {
    return 'При одном дне в неделю собирается «Всё тело».'
  }
  if (days === 2 && split === 'push_pull_legs') {
    return 'При двух днях в неделю собирается «Верх тела / Низ тела».'
  }
  return null
}

/** Строка подписей снаряда под названием упражнения (§6.6). */
export function equipmentLine(labels: readonly string[] | undefined): string | null {
  return labels && labels.length > 0 ? labels.join(', ') : null
}
