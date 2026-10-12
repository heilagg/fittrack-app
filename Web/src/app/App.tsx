import { useEffect, useMemo, useState } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter, Outlet, Route, Routes } from 'react-router-dom'
import { ApiClient } from '../api/client'
import { accessToken, ensureSession } from '../auth/supabase'
import { CycleCalendarScreen } from '../features/cycle/CycleCalendarScreen'
import { CycleEnableScreen } from '../features/cycle/CycleEnableScreen'
import { LinkScreen } from '../features/link/LinkScreen'
import { HomeGate } from '../features/onboarding/HomeGate'
import { OnboardingScreen } from '../features/onboarding/OnboardingScreen'
import { ProfileScreen } from '../features/profile/ProfileScreen'
import { ErrorBlock } from '../features/today/TodayScreen'
import { WorkoutScreen } from '../features/workout/WorkoutScreen'
import { BottomNav } from './BottomNav'

export function App() {
  const queryClient = useMemo(() => new QueryClient({ defaultOptions: { queries: { retry: false } } }), [])
  const api = useMemo(() => new ApiClient({ getToken: accessToken }), [])
  const [ready, setReady] = useState(false)
  const [error, setError] = useState<unknown>(null)

  useEffect(() => {
    ensureSession().then(
      () => setReady(true),
      (e: unknown) => setError(e),
    )
  }, [])

  if (error !== null) return <ErrorBlock error={error} />
  if (!ready) return <p role="status">Вход…</p>

  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <Routes>
          {/* Разделы с нижней навигацией; онбординг, линковка и тренировка — без неё. */}
          <Route element={<WithNav />}>
            <Route path="/" element={<HomeGate api={api} />} />
            <Route path="/profile" element={<ProfileScreen api={api} />} />
            <Route path="/cycle" element={<CycleCalendarScreen api={api} />} />
            <Route path="/cycle/enable" element={<CycleEnableScreen api={api} />} />
          </Route>
          <Route path="/onboarding" element={<OnboardingScreen api={api} />} />
          <Route path="/link" element={<LinkScreen />} />
          <Route path="/workout/:id" element={<WorkoutScreen api={api} />} />
        </Routes>
      </BrowserRouter>
    </QueryClientProvider>
  )
}

function WithNav() {
  return (
    <>
      <Outlet />
      <BottomNav />
    </>
  )
}
