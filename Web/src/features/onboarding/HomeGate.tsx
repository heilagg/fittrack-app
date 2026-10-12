import { useQuery } from '@tanstack/react-query'
import { Navigate } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import { ErrorBlock, TodayScreen } from '../today/TodayScreen'

/**
 * Вход в приложение: профиль, которого нет или который неполон, ведёт в
 * онбординг (SPEC §5). Полноту решает сервер (`is_complete`), клиент её не
 * считает.
 */
export function HomeGate({ api }: { api: ApiClient }) {
  const profile = useQuery({ queryKey: ['profile'], queryFn: () => api.getProfileIfStarted() })
  if (profile.isPending) return <p role="status">Загрузка…</p>
  if (profile.isError) return <ErrorBlock error={profile.error} />
  if (profile.data === null || !profile.data.is_complete) return <Navigate to="/onboarding" replace />
  return <TodayScreen api={api} />
}
