import { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter, Route, Routes } from 'react-router-dom'
import { ApiClient } from '../api/client'
import { accessToken, ensureSession } from '../auth/supabase'
import { TodayScreen, ErrorBlock } from '../features/today/TodayScreen'

// Dev-кнопка загружается только в dev-сборке: под `import.meta.env.DEV` ветка
// статически вырезается, и модуль в продакшен-бандл не попадает.
const DevSeed = import.meta.env.DEV ? lazy(() => import('../features/dev/DevSeed').then((m) => ({ default: m.DevSeed }))) : null

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
          <Route
            path="/"
            element={
              <>
                <TodayScreen api={api} />
                {DevSeed && (
                  <Suspense fallback={null}>
                    <DevSeed api={api} />
                  </Suspense>
                )}
              </>
            }
          />
        </Routes>
      </BrowserRouter>
    </QueryClientProvider>
  )
}
