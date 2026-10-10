// Проверка среды до запуска сквозных тестов: понятная ошибка вместо таймаута.

export default async function preflight(): Promise<void> {
  const url = 'http://127.0.0.1:54321/auth/v1/health'
  try {
    const response = await fetch(url, {
      headers: { apikey: process.env.VITE_SUPABASE_ANON_KEY ?? 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH' },
    })
    if (!response.ok) throw new Error(`status ${response.status}`)
  } catch (cause) {
    throw new Error(
      `Локальный Supabase недоступен (${url}). Запустите \`supabase start\` в корне репозитория ` +
        `и задайте роли fitserver пароль: alter role fitserver with password 'fitserver'.`,
      { cause },
    )
  }
}
