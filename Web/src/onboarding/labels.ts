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

/** Русские названия тренажёров (§6.6); в базу пишется слаг. */
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
}
