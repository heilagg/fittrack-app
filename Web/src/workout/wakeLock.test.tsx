import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, render, screen } from '@testing-library/react'
import { useWakeLock } from './wakeLock'

afterEach(() => {
  cleanup()
  delete (navigator as unknown as { wakeLock?: unknown }).wakeLock
})

function Probe({ enabled }: { enabled: boolean }) {
  return <p data-testid="state">{useWakeLock(enabled)}</p>
}

function installWakeLock() {
  const listeners: (() => void)[] = []
  const release = vi.fn(async () => {})
  const request = vi.fn(async () => ({
    release,
    addEventListener: (_: string, l: () => void) => listeners.push(l),
  }))
  Object.defineProperty(navigator, 'wakeLock', { value: { request }, configurable: true })
  return { request, release, fire: () => listeners.forEach((l) => l()) }
}

describe('Screen Wake Lock', () => {
  it('на входе запрашивается, на выходе отпускается', async () => {
    const lock = installWakeLock()
    const view = render(<Probe enabled />)
    await act(async () => {})
    expect(lock.request).toHaveBeenCalledWith('screen')
    expect(screen.getByTestId('state').textContent).toBe('active')
    view.unmount()
    expect(lock.release).toHaveBeenCalledTimes(1)
  })

  it('выключенный не запрашивается', async () => {
    const lock = installWakeLock()
    render(<Probe enabled={false} />)
    await act(async () => {})
    expect(lock.request).not.toHaveBeenCalled()
  })

  it('браузер снял блокировку — при возврате на вкладку она берётся заново', async () => {
    const lock = installWakeLock()
    render(<Probe enabled />)
    await act(async () => {})
    lock.fire() // браузер снял блокировку (вкладка ушла в фон)
    await act(async () => {
      document.dispatchEvent(new Event('visibilitychange'))
    })
    expect(lock.request).toHaveBeenCalledTimes(2)
  })

  it('без поддержки — состояние unsupported, а не падение', async () => {
    render(<Probe enabled />)
    await act(async () => {})
    expect(screen.getByTestId('state').textContent).toBe('unsupported')
  })

  it('отказ браузера — denied', async () => {
    Object.defineProperty(navigator, 'wakeLock', {
      value: { request: async () => Promise.reject(new Error('NotAllowedError')) },
      configurable: true,
    })
    render(<Probe enabled />)
    await act(async () => {})
    expect(screen.getByTestId('state').textContent).toBe('denied')
  })
})
