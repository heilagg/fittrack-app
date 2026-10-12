import '@testing-library/jest-dom/vitest'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { CheckinCard } from './CheckinCard'

vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))
const direct = vi.hoisted(() => ({ readCheckin: vi.fn(), saveCheckin: vi.fn(async () => undefined) }))
vi.mock('../../direct/checkin', () => direct)

afterEach(cleanup)
beforeEach(() => {
  vi.clearAllMocks()
  direct.readCheckin.mockResolvedValue(null)
})

function mount() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const invalidate = vi.spyOn(client, 'invalidateQueries')
  render(
    <QueryClientProvider client={client}>
      <CheckinCard date="2026-10-12" />
    </QueryClientProvider>,
  )
  return { invalidate }
}

const button = (value: string) => document.querySelector(`[data-override="${value}"]`) as HTMLButtonElement

describe('оверрайд дня (§11.4)', () => {
  it('тап пишет оверрайд и перечитывает карточку и неделю', async () => {
    const { invalidate } = mount()
    await waitFor(() => expect(button('push')).toBeEnabled())
    fireEvent.click(button('push'))
    await waitFor(() => expect(direct.saveCheckin).toHaveBeenCalledWith('user-1', '2026-10-12', { override: 'push' }))
    await waitFor(() => {
      const keys = invalidate.mock.calls.map((c) => (c[0] as { queryKey: string[] }).queryKey[0])
      expect(keys).toEqual(expect.arrayContaining(['today', 'week', 'checkin']))
    })
  })

  it('выбранный оверрайд отмечен; повторный тап снимает его', async () => {
    direct.readCheckin.mockResolvedValue({ id: 'c1', override: 'ease' })
    mount()
    await waitFor(() => expect(button('ease')).toHaveAttribute('aria-pressed', 'true'))
    expect(button('push')).toHaveAttribute('aria-pressed', 'false')
    fireEvent.click(button('ease'))
    await waitFor(() => expect(direct.saveCheckin).toHaveBeenCalledWith('user-1', '2026-10-12', { override: null }))
  })

  it('все три кнопки — с названиями §11.4', async () => {
    mount()
    expect(await screen.findByRole('button', { name: 'Чувствую себя отлично' })).toHaveAttribute('data-override', 'push')
    expect(screen.getByRole('button', { name: 'Тяжёлый день' })).toHaveAttribute('data-override', 'ease')
    expect(screen.getByRole('button', { name: 'Не сегодня' })).toHaveAttribute('data-override', 'rest')
  })
})

describe('чек-ин (§10)', () => {
  it('сохраняет только выбранные шкалы', async () => {
    mount()
    fireEvent.click(await screen.findByText('Чек-ин'))
    const energy = screen.getByRole('group', { name: 'Энергия' })
    fireEvent.click(energy.querySelector('input[value="4"]')!)
    const stress = screen.getByRole('group', { name: 'Стресс' })
    fireEvent.click(stress.querySelector('input[value="2"]')!)
    fireEvent.click(screen.getByRole('button', { name: 'Сохранить чек-ин' }))
    await waitFor(() =>
      expect(direct.saveCheckin).toHaveBeenCalledWith('user-1', '2026-10-12', { energy: 4, stress: 2 }),
    )
    expect(await screen.findByTestId('checkin-saved')).toBeInTheDocument()
  })

  it('пустой чек-ин не отправляется', async () => {
    mount()
    fireEvent.click(await screen.findByText('Чек-ин'))
    expect(screen.getByRole('button', { name: 'Сохранить чек-ин' })).toBeDisabled()
  })

  it('сохранённые значения показаны', async () => {
    direct.readCheckin.mockResolvedValue({ id: 'c1', energy: 5, soreness: 1 })
    mount()
    fireEvent.click(await screen.findByText('Чек-ин'))
    await waitFor(() =>
      expect(screen.getByRole('group', { name: 'Энергия' }).querySelector('input[value="5"]')).toBeChecked(),
    )
    expect(screen.getByRole('group', { name: 'Болезненность мышц' }).querySelector('input[value="1"]')).toBeChecked()
  })

  it('ошибка записи видна', async () => {
    direct.saveCheckin.mockRejectedValueOnce(new Error('Не удалось записать чек-ин: RLS'))
    mount()
    await waitFor(() => expect(button('rest')).toBeEnabled())
    fireEvent.click(button('rest'))
    expect(await screen.findByRole('alert')).toHaveTextContent('RLS')
  })
})
