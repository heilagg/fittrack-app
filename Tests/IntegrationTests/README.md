# Интеграционные тесты

Требуют локального Supabase (`supabase start`), поэтому вынесены из пакетов
и не входят в `swift test` по умолчанию.

Обязательный тест этапа 0 — изоляция RLS (SPEC §3.2): два анонимных клиента,
проход по всем таблицам, проверка что второй не видит ни одной строки первого.
Без него схема считается непринятой.

`rls_isolation.sh` — этот тест на прямом SQL-уровне (через
`set local role authenticated; set local request.jwt.claims = ...`, тем же
механизмом, что описывает §20.4). Требует `supabase start` из
`Supabase/migrations/` и `enable_anonymous_sign_ins = true` в
`Supabase/config.toml`. Не заменяет будущий HTTP-тест 20a (§20.15) — тот
пойдёт через реальные эндпоинты `Server`, когда пакет появится.

```
Supabase/migrations$ supabase start
Tests/IntegrationTests$ ./rls_isolation.sh
```
