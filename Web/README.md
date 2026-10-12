# Web

SPA FitTrack: Vite + React + TypeScript (SPEC §20). Правила работы — в
[.claude/skills/web-domain](../.claude/skills/web-domain/SKILL.md).

Клиент тонкий: вся логика за Swift-сервером. Он ходит в `/v1`, пишет шесть
таблиц напрямую в Supabase и применяет готовое дерево решений (§20.9).
Офлайна нет (§20.10).

## Структура

```
src/
  api/        # клиент /v1: пара date+tz (day.ts), схемы тел (schemas.ts), fetch (client.ts)
  auth/       # supabase-js, анонимный вход
  direct/     # прямые записи в таблицы под RLS
  content/    # кеш /v1/content/*
  onboarding/ # чистая логика онбординга: продолжение с экрана, PAR-Q, пресеты, цикл, тексты
  features/   # today (срез 1), link (срез 2), workout (срезы 3–4),
              # onboarding (срез 5: десять шагов §5)
  app/        # корень приложения, роутинг
e2e/          # Playwright против локальных Supabase и Server
```

## Запуск локально

Нужны Node и npm. Из корня репозитория:

```bash
supabase start
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
  -c "alter role fitserver with password 'fitserver'"

# сервер (слушает 127.0.0.1:8080)
cd Server
FITTRACK_ISSUER=http://127.0.0.1:54321/auth/v1 FITTRACK_DB_PASSWORD=fitserver \
FITTRACK_DB_PORT=54322 FITTRACK_DB_TLS=disable swift run fitserver

# веб (127.0.0.1:5173, /v1 проксируется на :8080)
cd Web
npm install
npm run dev
```

Значения Supabase для разработки лежат в `.env.development` (локальный
публичный ключ демо-проекта). Если порт 5173 занят другим процессом, задайте
`WEB_PORT=5174`: порт жёсткий (`strictPort`), на соседний Vite молча не уйдёт.
`site_url` в `Supabase/config.toml` пока указывает на 3000 — это правится
первым коммитом среза 2 (magic link).

Данные для разработки заводит настоящий онбординг (`/onboarding`): профиль,
PAR-Q, инвентарь и неделя проходятся теми же экранами, что у пользователя.
Тексты дисклеймера и экрана красного флага (`src/onboarding/texts.ts`) ждут
юриста (SPEC §14.2, §19.2 п. 5).

## Проверки

```bash
npm run typecheck && npm run lint
npm test            # Vitest: клиент /v1 и эталонные JSON
npm run e2e         # Playwright; поднимает Vite и сервер, Supabase — снаружи
```

Playwright использует системный Chrome (`channel: 'chrome'`) либо путь из
`PLAYWRIGHT_CHROME_PATH`; браузер скачивать не нужно.

## Эталонные JSON

`../Contract/fixtures/*.json` выгружает Swift-тест `ContractFixturesTests` из
DTO `Packages/FitAPI`; он падает, если файлы устарели. Перевыгрузка:

```bash
cd Packages/FitAPI
FITAPI_REGENERATE_FIXTURES=1 swift test --filter ContractFixturesTests
```

`src/api/contract.test.ts` читает те же файлы руками написанными схемами.
