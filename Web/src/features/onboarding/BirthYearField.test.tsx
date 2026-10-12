import '@testing-library/jest-dom/vitest'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { BirthYearField } from './BirthYearField'

afterEach(cleanup)

describe('поле года рождения (§5, шаг 3)', () => {
  it('подсказка внутри поля и подпись «четыре цифры», связанная с полем', () => {
    render(<BirthYearField value="" onChange={() => undefined} />)
    const input = screen.getByLabelText('Год рождения')
    expect(input).toHaveAttribute('placeholder', 'ГГГГ, например 2005')
    expect(input).toHaveAccessibleDescription('четыре цифры')
    expect(input).toHaveAttribute('maxLength', '4')
    expect(input).toHaveAttribute('inputMode', 'numeric')
  })

  it('ввод уходит наверх', () => {
    const onChange = vi.fn()
    render(<BirthYearField value="" onChange={onChange} />)
    fireEvent.change(screen.getByLabelText('Год рождения'), { target: { value: '1994' } })
    expect(onChange).toHaveBeenCalledWith('1994')
  })
})
