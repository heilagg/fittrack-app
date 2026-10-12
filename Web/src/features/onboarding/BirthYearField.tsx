// Поле года рождения (SPEC §5, шаг 3): подсказка внутри поля и подпись под
// ним — без них было непонятно, что вводить. Одно на онбординг и Профиль.

import { useId } from 'react'

export const BIRTH_YEAR_PLACEHOLDER = 'ГГГГ, например 2005'
export const BIRTH_YEAR_HINT = 'четыре цифры'

export function BirthYearField({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  const hint = useId()
  return (
    <p>
      <label className="field">
        Год рождения{' '}
        <input
          inputMode="numeric"
          maxLength={4}
          placeholder={BIRTH_YEAR_PLACEHOLDER}
          aria-describedby={hint}
          value={value}
          onChange={(e) => onChange(e.target.value)}
        />
      </label>
      <span id={hint} className="caption">
        {BIRTH_YEAR_HINT}
      </span>
    </p>
  )
}
