import '@testing-library/jest-dom/vitest'
import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import type { ExerciseContent } from '../../api/schemas'
import { ExerciseFrames, ExerciseThumbnail } from './Illustration'

afterEach(cleanup)

const content = (illustration: string): ExerciseContent => ({
  slug: 'plank_bw', name: 'Планка на предплечьях', cues: [], common_errors: [], illustration, default_rest_seconds: 60,
})

describe('кадры на экране тренировки', () => {
  it('два кадра, старт и финиш, с подписями для чтения с экрана', () => {
    render(<ExerciseFrames content={content('catalog/exact/plank_bw')} />)
    const images = screen.getAllByRole('img')
    expect(images.map((i) => i.getAttribute('src'))).toEqual([
      '/illustrations/plank_bw/start.jpg', '/illustrations/plank_bw/finish.jpg',
    ])
    expect(images.map((i) => i.getAttribute('alt'))).toEqual(['Планка на предплечьях, старт', 'Планка на предплечьях, финиш'])
    expect(screen.queryByTestId('illustration-close')).toBeNull()
  })

  it('тап увеличивает кадр, повторный — возвращает оба', () => {
    render(<ExerciseFrames content={content('catalog/exact/plank_bw')} />)
    fireEvent.click(screen.getByRole('button', { name: 'Финиш: увеличить' }))
    expect(screen.getAllByRole('img')).toHaveLength(1)
    expect(screen.getByRole('img')).toHaveAttribute('src', '/illustrations/plank_bw/finish.jpg')
    fireEvent.click(screen.getByRole('button', { name: 'Финиш: уменьшить' }))
    expect(screen.getAllByRole('img')).toHaveLength(2)
  })

  it('близкое совпадение подписано', () => {
    render(<ExerciseFrames content={content('catalog/close/plank_bw')} />)
    expect(screen.getByTestId('illustration-close')).toHaveTextContent('Похожее движение, снаряд на картинке другой')
  })

  it('без картинки — заглушка, а не пустое место', () => {
    render(<ExerciseFrames content={content('placeholder/full_body/bird_dog_bw')} />)
    expect(screen.getByTestId('illustration-placeholder')).toHaveTextContent('Картинки пока нет')
    expect(screen.queryAllByRole('img')).toHaveLength(0)
  })
})

describe('миниатюра в панели альтернатив', () => {
  it('первый кадр', () => {
    render(<ExerciseThumbnail content={content('catalog/close/plank_bw')} />)
    expect(screen.getByTestId('thumbnail')).toHaveAttribute('src', '/illustrations/plank_bw/start.jpg')
  })

  it('без картинки — пустая рамка', () => {
    render(<ExerciseThumbnail content={undefined} />)
    expect(screen.getByTestId('thumbnail-placeholder')).toBeInTheDocument()
  })
})
