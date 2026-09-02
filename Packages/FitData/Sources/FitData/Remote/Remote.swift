//  Supabase gateway и авторизация (SPEC §4, план раздел 3).
//
//  Три состояния идентичности: .localOnly (сети не было ни разу, всё работает)
//  → .anonymous(uid) → .linked(uid). Анонимный вход не блокирует онбординг.
//
//  Сессия хранится в Keychain: kSecAttrAccessibleAfterFirstUnlock +
//  kSecAttrSynchronizable = true, чтобы refresh-токен пережил восстановление
//  из бэкапа (SPEC §4.2). Готовой обёртки не берём — нужен точный контроль
//  над атрибутами.
//
//  РИСК, спайк до этапа 3: привязка нативного Apple ID-токена к существующему
//  анонимному пользователю. signInWithIdToken может создать НОВОГО
//  пользователя вместо привязки — это ровно та потеря данных, которую
//  SPEC §4.1 обещает исключить. Запасные варианты: linkIdentity через
//  ASWebAuthenticationSession, затем Edge Function с service-role.
