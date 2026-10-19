// Кеш `/v1/content/stretches` (§12.3, §20.11): как у упражнений, тело меняется
// только с деплоем, в пределах сессии не перезапрашивается.

import { useQuery } from '@tanstack/react-query'
import type { ApiClient } from '../../api/client'

export function useStretchContent(api: ApiClient) {
  return useQuery({
    queryKey: ['content', 'stretches'],
    queryFn: () => api.getStretchContent(),
    staleTime: Infinity,
    select: (body) => ({ ...body, poseBySlug: new Map(body.poses.map((p) => [p.slug, p])) }),
  })
}
