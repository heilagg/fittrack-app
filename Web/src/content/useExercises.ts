// Кеш `/v1/content/exercises` (SPEC §20.11; web-domain §3.8).
//
// `ETag` и `Cache-Control` ставит сервер, ревалидацию по ним делает HTTP-кеш
// браузера: отдельной логики здесь нет намеренно. Тело меняется только с
// деплоем сервера, поэтому в пределах сессии оно не перезапрашивается.

import { useQuery } from '@tanstack/react-query'
import type { ApiClient } from '../api/client'
import type { ExerciseContent } from '../api/schemas'

export function useExerciseNames(api: ApiClient) {
  return useQuery({
    queryKey: ['content', 'exercises'],
    queryFn: () => api.getExercises(),
    staleTime: Infinity,
    select: (list: ExerciseContent[]) => new Map(list.map((e) => [e.slug, e])),
  })
}
