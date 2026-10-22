import '@testing-library/jest-dom/vitest'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import type { Profile } from '../../api/schemas'
import { PRESETS } from '../../onboarding/presets'
import { EquipmentScreen, PersonalScreen, RestrictionsScreen, SplitScreen } from './EditScreens'

vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))
const equipment = vi.hoisted(() => ({ readDefaultEquipment: vi.fn(), updateEquipmentProfile: vi.fn(async () => undefined) }))
vi.mock('../../direct/equipment', () => equipment)
const profileDirect = vi.hoisted(() => ({
  readActiveRestrictions: vi.fn(),
  resolveRestrictions: vi.fn(async () => undefined),
  addRestrictions: vi.fn(async () => undefined),
  latestBodyWeight: vi.fn(async () => 64.5),
}))
vi.mock('../../direct/profile', () => profileDirect)
const onboarding = vi.hoisted(() => ({ upsertBodyWeight: vi.fn(async () => undefined) }))
vi.mock('../../direct/onboarding', () => onboarding)

afterEach(cleanup)
beforeEach(() => vi.clearAllMocks())

const profile: Profile = {
  sex_at_birth: 'female', birth_year: 1994, height_cm: 168, experience_level: 'intermediate', goal: 'hypertrophy',
  days_per_week: 3, training_weekdays: [1, 3, 5], session_minutes: 60, training_split: 'auto', cycle_tracking: 'off', is_complete: true,
}

function mount(ui: React.ReactNode) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter>{ui}</MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('личные данные', () => {
  it('поля из профиля; сохранение шлёт только изменённое', async () => {
    const patchProfile = vi.fn(async () => profile)
    mount(<PersonalScreen api={{ getProfileIfStarted: async () => profile, patchProfile } as unknown as ApiClient} />)
    expect(await screen.findByLabelText('Год рождения')).toHaveValue('1994')
    expect(screen.getByLabelText('Год рождения')).toHaveAccessibleDescription('четыре цифры')
    expect(screen.getByLabelText('Как давно вы занимаетесь в зале?')).toHaveValue('intermediate')
    expect(screen.getByLabelText('Вес, кг')).toHaveValue('64.5')
    fireEvent.change(screen.getByLabelText('Цель'), { target: { value: 'strength' } })
    fireEvent.click(screen.getByLabelText('Суббота'))
    fireEvent.click(screen.getByRole('button', { name: 'Сохранить' }))
    await waitFor(() => expect(patchProfile).toHaveBeenCalledWith({ goal: 'strength', training_weekdays: [1, 3, 5, 6] }))
    expect(onboarding.upsertBodyWeight).not.toHaveBeenCalled()
    expect(await screen.findByTestId('personal-saved')).toBeInTheDocument()
  })

  it('новый вес пишется прямой записью, профиль без изменений не шлётся', async () => {
    const patchProfile = vi.fn(async () => profile)
    mount(<PersonalScreen api={{ getProfileIfStarted: async () => profile, patchProfile } as unknown as ApiClient} />)
    fireEvent.change(await screen.findByLabelText('Вес, кг'), { target: { value: '63,2' } })
    fireEvent.click(screen.getByRole('button', { name: 'Сохранить' }))
    await waitFor(() => expect(onboarding.upsertBodyWeight).toHaveBeenCalled())
    expect((onboarding.upsertBodyWeight.mock.calls[0] as unknown[])[1]).toBe(63.2)
    expect(patchProfile).not.toHaveBeenCalled()
  })

  it('неверные значения не уходят', async () => {
    const patchProfile = vi.fn(async () => profile)
    mount(<PersonalScreen api={{ getProfileIfStarted: async () => profile, patchProfile } as unknown as ApiClient} />)
    fireEvent.change(await screen.findByLabelText('Рост, см'), { target: { value: '90' } })
    fireEvent.click(screen.getByRole('button', { name: 'Сохранить' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Рост')
    for (const d of ['Понедельник', 'Среда', 'Пятница']) fireEvent.click(screen.getByLabelText(d))
    fireEvent.change(screen.getByLabelText('Рост, см'), { target: { value: '168' } })
    fireEvent.click(screen.getByRole('button', { name: 'Сохранить' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('день')
    expect(patchProfile).not.toHaveBeenCalled()
  })

  it('длительность вне 10–180 минут не уходит', async () => {
    const patchProfile = vi.fn(async () => profile)
    mount(<PersonalScreen api={{ getProfileIfStarted: async () => profile, patchProfile } as unknown as ApiClient} />)
    for (const value of ['9', '181']) {
      fireEvent.change(await screen.findByLabelText(/Длительность тренировки/), { target: { value } })
      fireEvent.click(screen.getByRole('button', { name: 'Сохранить' }))
      expect(await screen.findByRole('alert')).toHaveTextContent('Длительность — от 10 до 180 минут')
    }
    expect(patchProfile).not.toHaveBeenCalled()
  })
})

describe('инвентарь', () => {
  it('правка строки по умолчанию, затем /rebuild с equipment_changed и notice', async () => {
    equipment.readDefaultEquipment.mockResolvedValue({ id: 'eq-1', row: { ...PRESETS.gym, name: 'Мой зал', is_default: true } })
    const rebuildWeek = vi.fn(async () => ({
      plan: { days: [], status_lines: [] },
      notice: { code: 'plan_rebuilt', params: {}, message: 'План обновлён' },
    }))
    mount(<EquipmentScreen api={{ rebuildWeek } as unknown as ApiClient} />)
    const dumbbells = await screen.findByLabelText(/Гантели/)
    fireEvent.change(dumbbells, { target: { value: '4, 6, 8' } })
    fireEvent.click(screen.getByRole('button', { name: 'Сохранить инвентарь' }))
    await waitFor(() => expect(equipment.updateEquipmentProfile).toHaveBeenCalled())
    const [id, row] = equipment.updateEquipmentProfile.mock.calls[0] as unknown as [string, { name: string; is_default: boolean; dumbbells_kg: number[] }]
    expect(id).toBe('eq-1')
    expect(row).toMatchObject({ name: 'Мой зал', is_default: true, dumbbells_kg: [4, 6, 8] })
    await waitFor(() => expect(rebuildWeek).toHaveBeenCalledWith('equipment_changed'))
    expect(await screen.findByTestId('equipment-saved')).toHaveTextContent('План обновлён')
  })

  it('тренажёры — русскими названиями, в строку пишется слаг', async () => {
    equipment.readDefaultEquipment.mockResolvedValue({ id: 'eq-1', row: { ...PRESETS.gym, machines: [], name: 'Зал', is_default: true } })
    mount(<EquipmentScreen api={{ rebuildWeek: async () => null } as unknown as ApiClient} />)
    fireEvent.click(await screen.findByLabelText('Бабочка'))
    expect(screen.queryByText('pec_deck')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Сохранить инвентарь' }))
    await waitFor(() => expect(equipment.updateEquipmentProfile).toHaveBeenCalled())
    expect((equipment.updateEquipmentProfile.mock.calls[0] as unknown as [string, { machines: string[] }])[1].machines)
      .toEqual(['pec_deck'])
  })

  it('пресет не меняет имя и флаг строки', async () => {
    equipment.readDefaultEquipment.mockResolvedValue({ id: 'eq-1', row: { ...PRESETS.gym, name: 'Мой зал', is_default: true } })
    mount(<EquipmentScreen api={{ rebuildWeek: async () => null } as unknown as ApiClient} />)
    fireEvent.click(await screen.findByRole('button', { name: PRESETS.home_dumbbells.name }))
    fireEvent.click(screen.getByRole('button', { name: 'Сохранить инвентарь' }))
    await waitFor(() => expect(equipment.updateEquipmentProfile).toHaveBeenCalled())
    expect((equipment.updateEquipmentProfile.mock.calls[0] as unknown as [string, { name: string; is_default: boolean }])[1])
      .toMatchObject({ name: 'Мой зал', is_default: true })
  })
})

describe('ограничения', () => {
  it('снятие и смена степени: resolve старых, add новых', async () => {
    profileDirect.readActiveRestrictions.mockResolvedValue([
      { id: 'r-knee', joint: 'knee', severity: 'avoid' },
      { id: 'r-neck', joint: 'neck', severity: 'careful' },
    ])
    mount(<RestrictionsScreen />)
    const knee = await waitFor(() => {
      const el = document.querySelector('[data-joint="knee"]') as HTMLSelectElement | null
      if (!el) throw new Error('нет поля')
      return el
    })
    expect(knee.value).toBe('avoid')
    fireEvent.change(knee, { target: { value: 'careful' } })
    fireEvent.change(document.querySelector('[data-joint="neck"]')!, { target: { value: '' } })
    fireEvent.click(screen.getByRole('button', { name: 'Сохранить' }))
    await waitFor(() => expect(profileDirect.resolveRestrictions).toHaveBeenCalledWith(['r-knee', 'r-neck']))
    expect(profileDirect.addRestrictions).toHaveBeenCalledWith('user-1', [{ joint: 'knee', severity: 'careful' }])
    expect(await screen.findByTestId('restrictions-saved')).toBeInTheDocument()
  })
})

describe('схема тренировок (§7.2, §13.1)', () => {
  it('текущая схема отмечена; сохранение шлёт одно поле training_split', async () => {
    const patchProfile = vi.fn(async () => profile)
    mount(<SplitScreen api={{ getProfileIfStarted: async () => profile, patchProfile } as unknown as ApiClient} />)
    expect(await screen.findByLabelText('Авто')).toBeChecked()
    fireEvent.click(screen.getByLabelText('Пуш пулл ноги'))
    fireEvent.click(screen.getByRole('button', { name: 'Сохранить' }))
    await waitFor(() => expect(patchProfile).toHaveBeenCalledWith({ training_split: 'push_pull_legs' }))
    expect(await screen.findByTestId('split-saved')).toBeInTheDocument()
    expect(screen.getByText('Новая схема вступит в силу со следующей недели.')).toBeInTheDocument()
  })

  it('неизменённая схема не шлётся', async () => {
    const patchProfile = vi.fn(async () => profile)
    mount(<SplitScreen api={{ getProfileIfStarted: async () => profile, patchProfile } as unknown as ApiClient} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Сохранить' }))
    expect(await screen.findByTestId('split-saved')).toBeInTheDocument()
    expect(patchProfile).not.toHaveBeenCalled()
  })

  it('при двух днях «Пуш пулл ноги» говорит, что собирается на деле', async () => {
    const twoDays: Profile = { ...profile, days_per_week: 2, training_weekdays: [2, 5] }
    mount(<SplitScreen api={{ getProfileIfStarted: async () => twoDays, patchProfile: vi.fn() } as unknown as ApiClient} />)
    fireEvent.click(await screen.findByLabelText('Пуш пулл ноги'))
    expect(screen.getByTestId('split-note')).toHaveTextContent('Верх тела / Низ тела')
    fireEvent.click(screen.getByLabelText('Всё тело'))
    expect(screen.queryByTestId('split-note')).toBeNull()
  })
})
