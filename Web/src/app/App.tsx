import { useEffect, useMemo, useState } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter, Route, Routes } from 'react-router-dom'
import { ApiClient } from '../api/client'
import { accessToken, ensureSession } from '../auth/supabase'
import { LinkScreen } from '../features/link/LinkScreen'
import { HomeGate } from '../features/onboarding/HomeGate'
import { OnboardingScreen } from '../features/onboarding/OnboardingScreen'
import { ErrorBlock } from '../features/today/TodayScreen'
import { WorkoutScreen } from '../features/workout/WorkoutScreen'

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
          <Route path="/" element={<HomeGate api={api} />} />
          <Route path="/onboarding" element={<OnboardingScreen api={api} />} />
          <Route path="/link" element={<LinkScreen />} />
          <Route path="/workout/:id" element={<WorkoutScreen api={api} />} />
        </Routes>
      </BrowserRouter>
    </QueryClientProvider>
  )
}
