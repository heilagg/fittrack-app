// Картинки упражнения (SPEC §6.5): два кадра под названием на экране
// тренировки, миниатюра в панели альтернатив. Тап по кадру увеличивает его,
// повторный тап — обратно. Ненайденные — заглушка, а не пустое место
// (web-domain §3.8).

import { useState } from 'react'
import type { ExerciseContent } from '../../api/schemas'
import { CLOSE_MATCH_CAPTION, illustrationOf } from '../../content/illustration'

/** Кадры упражнения или позы растяжки (§6.5, §12.3): нужны только имя и ключ. */
export function ExerciseFrames({ content }: { content: Pick<ExerciseContent, 'name' | 'illustration'> | undefined }) {
  const [enlarged, setEnlarged] = useState<'start' | 'finish' | null>(null)
  const picture = illustrationOf(content?.illustration)
  if (picture.kind === 'placeholder') {
    return (
      <p className="illustration-placeholder caption" data-testid="illustration-placeholder">
        Картинки пока нет
      </p>
    )
  }
  const name = content?.name ?? ''
  const frames = [
    { id: 'start' as const, src: picture.start, label: 'Старт' },
    { id: 'finish' as const, src: picture.finish, label: 'Финиш' },
  ]
  return (
    <figure className="illustration" data-testid="illustration" data-match={picture.match}>
      <div className="illustration-frames" data-enlarged={enlarged ?? 'none'}>
        {frames
          .filter((f) => enlarged === null || enlarged === f.id)
          .map((f) => (
            <button
              key={f.id}
              type="button"
              className="illustration-frame"
              aria-label={enlarged === f.id ? `${f.label}: уменьшить` : `${f.label}: увеличить`}
              aria-pressed={enlarged === f.id}
              onClick={() => setEnlarged((cur) => (cur === f.id ? null : f.id))}
            >
              <img src={f.src} alt={`${name}, ${f.label.toLowerCase()}`} loading="lazy" />
            </button>
          ))}
      </div>
      {picture.match === 'close' && (
        <figcaption className="caption" data-testid="illustration-close">
          {CLOSE_MATCH_CAPTION}
        </figcaption>
      )}
    </figure>
  )
}

export function ExerciseThumbnail({ content }: { content: ExerciseContent | undefined }) {
  const picture = illustrationOf(content?.illustration)
  return picture.kind === 'catalog' ? (
    <img className="thumbnail" data-testid="thumbnail" src={picture.start} alt="" loading="lazy" />
  ) : (
    <span className="thumbnail thumbnail--empty" data-testid="thumbnail-placeholder" aria-hidden="true" />
  )
}
