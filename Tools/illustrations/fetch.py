#!/usr/bin/env python3
"""Выгрузка картинок упражнений из free-exercise-db (SPEC §6.5).

Читает Packages/FitContent/Sources/FitContent/Resources/illustrations.json
(упражнения и позы растяжки §12.3 — один каталог картинок) и кладёт по два
кадра на слаг в Web/public/illustrations/<слаг>/start.jpg и
finish.jpg. `reversed` меняет кадры местами здесь, при выгрузке: экран
всегда показывает старт → финиш. Каталоги слагов, которых в файле нет,
удаляются — картинка без сопоставления на экран не попадёт. Уже выгруженные
кадры не перекачиваются; `--force` выгружает всё заново.

Запуск из корня репозитория:  python3 Tools/illustrations/fetch.py [--force]
"""

import json
import shutil
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAP = ROOT / "Packages/FitContent/Sources/FitContent/Resources/illustrations.json"
OUT = ROOT / "Web/public/illustrations"
BASE = "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/"


def main() -> int:
    data = json.loads(MAP.read_text(encoding="utf-8"))
    entries = {**data["exercises"], **data.get("poses", {})}
    force = "--force" in sys.argv[1:]
    OUT.mkdir(parents=True, exist_ok=True)
    for stale in sorted(p for p in OUT.iterdir() if p.is_dir() and p.name not in entries):
        shutil.rmtree(stale)
        print(f"удалено: {stale.name}")
    for slug, entry in sorted(entries.items()):
        frames = ["1.jpg", "0.jpg"] if entry.get("reversed") else ["0.jpg", "1.jpg"]
        target = OUT / slug
        target.mkdir(exist_ok=True)
        if not force and all((target / name).exists() for name in ["start.jpg", "finish.jpg"]):
            continue
        for name, frame in zip(["start.jpg", "finish.jpg"], frames):
            with urllib.request.urlopen(BASE + entry["id"] + "/" + frame, timeout=30) as response:
                (target / name).write_bytes(response.read())
    print(f"готово: {len(entries)} слагов, {2 * len(entries)} кадров в {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
