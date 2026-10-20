// Раздел «Растяжка» (SPEC §12.2, §13.1): восемь шаблонов с отмеченным
// предложенным и история завершённых сессий. Предложенный шаблон считает
// сервер (FitCore), клиент правило не повторяет.

import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import type { ApiClient } from '../../api/client'
import { formatShortDate } from '../../ui/format'
import { ErrorBlock } from '../today/TodayScreen'
import { useStretchContent } from './useStretchContent'

const KIND_LABEL: Record<string, string> = {
  standalone: 'Сессия',
  static_cooldown: 'Заминка',
  mobility_warmup: 'Разминка',
}

export function StretchScreen({ api }: { api: ApiClient }) {
  const content = useStretchContent(api)
  const history = useQuery({ queryKey: ['stretch-history'], queryFn: () => api.getStretchHistory() })

  if (content.isPending || history.isPending) return <p role="status">Загрузка…</p>
  if (content.isError) return <ErrorBlock error={content.error} />
  if (history.isError) return <ErrorBlock error={history.error} />

  const suggested = history.data.suggested_template
  const names = new Map(content.data.templates.map((t) => [t.slug, t.name]))
  return (
    <main>
      <header className="screen-header">
        <h1>Растяжка</h1>
      </header>
      <ul className="rows card" aria-label="Шаблоны" data-testid="stretch-templates">
        {content.data.templates.map((t) => (
          <li key={t.slug} data-slug={t.slug} data-suggested={t.slug === suggested || undefined}>
            {/* Ссылка — вся строка, вместе с отметкой предложенного. */}
            <Link to={`/stretch/play/${encodeURIComponent(t.slug)}`} className="template-link">
              <span className="template-text">
                <span>{t.name}</span>
                <span className="caption">
                  {t.minutes} мин · {t.purpose}
                </span>
              </span>
              {t.slug === suggested && (
                <span className="chip" data-testid="suggested">
                  Предложено
                </span>
              )}
            </Link>
          </li>
        ))}
      </ul>
      <section aria-label="История" className="card">
        <h2 className="section-title">История</h2>
        {history.data.sessions.length === 0 ? (
          <p className="caption" data-testid="stretch-history-empty">
            Завершённых сессий пока нет.
          </p>
        ) : (
          <ul className="rows" data-testid="stretch-history">
            {history.data.sessions.map((s) => (
              <li key={s.id}>
                <span>{s.template_slug ? (names.get(s.template_slug) ?? s.template_slug) : KIND_LABEL[s.kind]}</span>
                <span className="caption">
                  {formatShortDate(s.performed_on)}
                  {s.duration_seconds !== undefined ? ` · ${Math.max(1, Math.round(s.duration_seconds / 60))} мин` : ''}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  )
}
