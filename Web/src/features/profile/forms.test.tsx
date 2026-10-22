import '@testing-library/jest-dom/vitest'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { EquipmentRow } from '../../direct/equipmentRow'
import { PRESETS } from '../../onboarding/presets'
import { EquipmentForm } from './forms'

vi.mock('../../auth/supabase', () => ({ currentUserId: async () => 'user-1' }))
afterEach(cleanup)

function mount(initial?: EquipmentRow) {
  const onSubmit = vi.fn<(row: EquipmentRow) => Promise<void>>(async () => {})
  render(<EquipmentForm initial={initial} submitLabel="Сохранить" onSubmit={onSubmit} />)
  return onSubmit
}

const field = (label: RegExp) => screen.getByLabelText(label) as HTMLInputElement
const save = () => fireEvent.click(screen.getByRole('button', { name: 'Сохранить' }))

describe('инвентарь: вес грифа и шаг стека (§20.3)', () => {
  it('текст в поле грифа — ошибка поля, а не молча пропавший гриф', async () => {
    const onSubmit = mount(PRESETS.gym)
    fireEvent.change(field(/Гриф, кг/), { target: { value: 'двадцать' } })
    save()
    expect(await screen.findByRole('alert')).toHaveTextContent('Гриф: вес — число больше 0 и не больше 500 кг')
    expect(onSubmit).not.toHaveBeenCalled()
  })

  it('число с запятой сохраняется числом; пустое поле — колонки нет', async () => {
    const onSubmit = mount(PRESETS.gym)
    fireEvent.change(field(/Гриф, кг/), { target: { value: '15,5' } })
    fireEvent.change(field(/Шаг стека/), { target: { value: '' } })
    save()
    await waitFor(() => expect(onSubmit).toHaveBeenCalledTimes(1))
    const row = onSubmit.mock.calls[0]![0]
    expect(row.barbell_kg).toBe(15.5)
    expect('machine_step_kg' in row).toBe(false)
  })

  it('ноль и больше 500 — отказ: шаг стека 0 не вес, а пустая ступень', async () => {
    for (const [label, value, text] of [
      [/Шаг стека/, '0', 'Шаг стека'], [/Гриф, кг/, '501', 'Гриф'],
    ] as const) {
      const onSubmit = mount(PRESETS.gym)
      fireEvent.change(field(label), { target: { value } })
      save()
      expect(await screen.findByRole('alert')).toHaveTextContent(text)
      expect(onSubmit).not.toHaveBeenCalled()
      cleanup()
    }
  })

  it('веса гантелей вне диапазона — отказ', async () => {
    const onSubmit = mount(PRESETS.gym)
    fireEvent.change(field(/Гантели/), { target: { value: '4 600' } })
    save()
    expect(await screen.findByRole('alert')).toHaveTextContent('не больше 500 кг')
    expect(onSubmit).not.toHaveBeenCalled()
  })
})
