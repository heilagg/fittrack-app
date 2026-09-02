# delete-account

Edge Function удаления аккаунта. Обязательна для App Store с 2022 года
(SPEC §14.5): реальное удаление данных, не деактивация.

`auth.admin.deleteUser(uid)` под service-role → каскад по `on delete cascade` →
клиент стирает локальную базу и возвращается в состояние первого запуска.
