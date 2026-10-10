#!/usr/bin/env python3
"""Независимая реализация userSeed (SPEC §20.8) — эталон для теста 20h.

    userSeed = первые 8 байт SHA-256(канонический uuid пользователя,
               36 символов, нижний регистр, UTF-8), big-endian -> UInt64

Смысл файла — НЕ удобство, а независимость. §20.15 требует сверить значение с
реализацией на другом языке: своя реализация, сверенная сама с собой,
доказывает только то, что она не поменялась с прошлого запуска. Здесь не
используется ничего из Swift-кода — ни формулировки, ни порядка шагов,
только текст §20.8.

Запуск:  python3 user_seed.py [uuid ...]
Без аргументов печатает набор, зафиксированный в Test20hUserSeed.swift.
"""

import hashlib
import sys

# Вектора выбраны так, чтобы каждый ломал свой шаг формулы:
#   nil/max      — границы;
#   верхний регистр во входе — проверка приведения к нижнему;
#   остальные    — обычные значения Supabase.
VECTORS = [
    "00000000-0000-0000-0000-000000000000",
    "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "0f7a1c3e-2b4d-4a6f-8c9e-1d2f3a4b5c6d",
    "a1b2c3d4-e5f6-4789-abcd-ef0123456789",
    "7c9e6679-7425-40de-944b-e07fc1f90ae7",
]


def user_seed(canonical_uuid: str) -> int:
    if len(canonical_uuid) != 36:
        raise ValueError(f"не 36 символов: {canonical_uuid!r}")
    digest = hashlib.sha256(canonical_uuid.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], byteorder="big", signed=False)


def main(argv):
    for value in (argv or VECTORS):
        print(f"{value}  {user_seed(value)}")


if __name__ == "__main__":
    main(sys.argv[1:])
