// Ключ `illustration` → что рисовать (SPEC §6.5). Ничего не считает: читает
// ключ, который поставил загрузчик FitContent.
//
//   catalog/<exact|close>/<слаг> — два кадра в /illustrations/<слаг>/;
//   всё остальное (`placeholder/…` и неизвестное) — заглушка «Картинки пока
//   нет». Неизвестный ключ не падает: экран тренировки важнее картинки.

export type Illustration =
  | { kind: 'catalog'; match: 'exact' | 'close'; start: string; finish: string }
  | { kind: 'placeholder' }

export function illustrationOf(key: string | undefined): Illustration {
  const parts = key?.split('/') ?? []
  if (parts.length === 3 && parts[0] === 'catalog' && (parts[1] === 'exact' || parts[1] === 'close') && parts[2]) {
    const base = `/illustrations/${encodeURIComponent(parts[2])}`
    return { kind: 'catalog', match: parts[1], start: `${base}/start.jpg`, finish: `${base}/finish.jpg` }
  }
  return { kind: 'placeholder' }
}

/** Подпись близкого совпадения (§6.5). */
export const CLOSE_MATCH_CAPTION = 'Похожее движение, снаряд на картинке другой'
