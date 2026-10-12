import '@testing-library/jest-dom/vitest'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { Profile } from '../../api/schemas'
import type { FlagStore } from '../../cycle/once'
import { ProfileScreen } from './ProfileScreen'

// ErrorBlock живёт в «Сегодня», а та тянет supabase-js; без переменных среды он не создаётся.
vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))

afterEach(cleanup)

const female = (cycle: Profile['cycle'], tracking: Profile['cycle_tracking'] = 'manual'): Profile => ({
  sex_at_birth: 'female',
  session_minutes: 60,
  cycle_tracking: tracking,
  is_complete: true,
  ...(cycle ? { cycle } : {}),
})

function memory(): FlagStore & { data: Map<string, string> } {
  const data = new Map<string, string>()
  return { data, get: (k) => data.get(k) ?? null, set: (k, v) => void data.set(k, v) }
}

function Where() {
  return <p data-testid="location">{useLocation().pathname}</p>
}

function mount(profile: Profile | null, store: FlagStore = memory()) {
  const api = { getProfileIfStarted: async () => profile } as unknown as ApiClient
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={['/profile']}>
        <Where />
        <Routes>
          <Route path="/profile" element={<ProfileScreen api={api} store={store} />} />
          <Route path="*" element={null} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('Профиль: вход в календарь цикла', () => {
  it('режим фаз — ссылка на календарь', async () => {
    mount(female({ phase_mode: 'phases' }))
    expect(await screen.findByTestId('cycle-calendar-link')).toHaveAttribute('href', '/cycle')
    expect(screen.queryByTestId('cycle-off-link')).toBeNull()
  })

  it('low_confidence — тоже календарь', async () => {
    mount(female({ phase_mode: 'no_phases', no_phase_reason: 'low_confidence' }))
    expect(await screen.findByTestId('cycle-calendar-link')).toBeInTheDocument()
  })

  it('контрацепция — «Цикл выключен» с переходом к включению, без предложения', async () => {
    mount(female({ phase_mode: 'no_phases', no_phase_reason: 'contraception' }))
    expect(await screen.findByTestId('cycle-off-link')).toHaveAttribute('href', '/cycle/enable')
    expect(screen.queryByTestId('enable-offer')).toBeNull()
  })

  it('declined — предложение включить; «Включить» ведёт к вопросам и запоминается', async () => {
    const store = memory()
    mount(female({ phase_mode: 'no_phases', no_phase_reason: 'declined' }, 'off'), store)
    fireEvent.click(await screen.findByRole('button', { name: 'Включить' }))
    await waitFor(() => expect(screen.getByTestId('location')).toHaveTextContent('/cycle/enable'))
    expect(store.data.size).toBe(1)
  })

  it('declined — «Не сейчас» убирает предложение, строка «Цикл выключен» остаётся', async () => {
    const store = memory()
    mount(female({ phase_mode: 'no_phases', no_phase_reason: 'declined' }, 'off'), store)
    fireEvent.click(await screen.findByRole('button', { name: 'Не сейчас' }))
    await waitFor(() => expect(screen.queryByTestId('enable-offer')).toBeNull())
    expect(screen.getByTestId('cycle-off-link')).toBeInTheDocument()
    expect(store.data.size).toBe(1)
  })

  it('declined, на предложение уже отвечали — не предлагает', async () => {
    const store = memory()
    store.set('fittrack.cycle.declined-offer-answered', '1')
    mount(female({ phase_mode: 'no_phases', no_phase_reason: 'declined' }, 'off'), store)
    await screen.findByTestId('cycle-off-link')
    expect(screen.queryByTestId('enable-offer')).toBeNull()
  })

  it('мужской профиль — про цикл ничего', async () => {
    mount({ ...female({ phase_mode: 'phases' }), sex_at_birth: 'male' })
    await screen.findByRole('heading', { name: 'Профиль' })
    expect(screen.queryByRole('list', { name: 'Цикл' })).toBeNull()
  })
})
