import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { Profile } from '../../api/schemas'
import { HomeGate } from './HomeGate'

vi.mock('../today/TodayScreen', () => ({
  TodayScreen: () => <p data-testid="today">Сегодня</p>,
  ErrorBlock: ({ error }: { error: unknown }) => <p role="alert">{String(error)}</p>,
}))
afterEach(cleanup)

const profile = (isComplete: boolean): Profile => ({
  session_minutes: 45,
  cycle_tracking: 'off',
  is_complete: isComplete,
})

function mount(result: Profile | null) {
  const api = { getProfileIfStarted: async () => result } as unknown as ApiClient
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={['/']}>
        <Routes>
          <Route path="/" element={<HomeGate api={api} />} />
          <Route path="/onboarding" element={<p data-testid="onboarding">Онбординг</p>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('вход на главную', () => {
  it('профиля нет — в онбординг', async () => {
    mount(null)
    await waitFor(() => expect(screen.getByTestId('onboarding')).toBeTruthy())
  })

  it('профиль неполон по ответу сервера — в онбординг', async () => {
    mount(profile(false))
    await waitFor(() => expect(screen.getByTestId('onboarding')).toBeTruthy())
  })

  it('профиль полон — «Сегодня»', async () => {
    mount(profile(true))
    await waitFor(() => expect(screen.getByTestId('today')).toBeTruthy())
  })
})
