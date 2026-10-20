import '@testing-library/jest-dom/vitest'
import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { BottomNav } from './BottomNav'

afterEach(cleanup)

describe('нижняя навигация (§13.1, §20.12)', () => {
  it('четыре вкладки по порядку; «Тренировки» на вебе нет', () => {
    render(<MemoryRouter><BottomNav /></MemoryRouter>)
    const links = screen.getByRole('navigation', { name: 'Разделы' }).querySelectorAll('a')
    expect([...links].map((a) => [a.textContent, a.getAttribute('href')])).toEqual([
      ['Сегодня', '/'], ['Растяжка', '/stretch'], ['Прогресс', '/progress'], ['Профиль', '/profile'],
    ])
    expect(screen.queryByText('Тренировки')).toBeNull()
  })
})
