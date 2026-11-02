#!/usr/bin/env python3
"""Проверяет, проходят ли IP через белый список мобильного оператора.

Запускать на ноутбуке, подключённом к ограниченной мобильной сети (раздача
с телефона), с выключенным VPN. Тест имеет смысл только когда белый список
реально активен — иначе всё пройдёт и результат ничего не значит.

    ./whitelist-check.py --operator MTS --region Москва candidates.txt

Формат candidates.txt (по строке на кандидата):

    # имя  ip
    monitor        217.28.222.170
    yandex-cloud   1.2.3.4

Выход: таблица в консоль + markdown в файл, чтобы накапливать результаты.
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
from datetime import datetime, timezone

# Контрольные точки: если разрешённый сервис не открывается, тест бессмысленен.
CONTROL_ALLOWED = ("gosuslugi.ru", 443)
# Заведомо «неразрешённый» адрес: если он открывается, белого списка сейчас нет.
CONTROL_BLOCKED = ("1.1.1.1", 443)

PORTS = (443, 80, 22)


def tcp_ok(host: str, port: int, timeout: float) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def load_candidates(path: str) -> list[tuple[str, str]]:
    items: list[tuple[str, str]] = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                print(f"пропускаю строку: {line!r}", file=sys.stderr)
                continue
            items.append((parts[0], parts[1]))
    return items


def verdict(results: dict[int, bool], whitelist_active: bool) -> str:
    """Вывод имеет смысл только когда ограничения реально действуют."""
    if not whitelist_active:
        return "тест недействителен (ограничений нет)"
    if results.get(443):
        return "ПРОХОДИТ (443)"
    if results.get(80) or results.get(22):
        return "частично (не 443)"
    return "не проходит"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidates", help="файл со списком: имя и IP")
    parser.add_argument("--operator", default="?", help="оператор, например MTS")
    parser.add_argument("--region", default="?", help="регион")
    parser.add_argument("--timeout", type=float, default=4.0)
    parser.add_argument("--out", default="whitelist-results.md")
    args = parser.parse_args()

    candidates = load_candidates(args.candidates)
    if not candidates:
        print("список кандидатов пуст", file=sys.stderr)
        return 1

    print("== контроль ==")
    allowed_ok = tcp_ok(CONTROL_ALLOWED[0], CONTROL_ALLOWED[1], args.timeout)
    blocked_ok = tcp_ok(CONTROL_BLOCKED[0], CONTROL_BLOCKED[1], args.timeout)
    print(f"  {CONTROL_ALLOWED[0]}:{CONTROL_ALLOWED[1]}  {'ok' if allowed_ok else 'НЕТ'}")
    print(f"  {CONTROL_BLOCKED[0]}:{CONTROL_BLOCKED[1]}  {'ok' if blocked_ok else 'НЕТ'}")

    if not allowed_ok:
        print("\n⚠ разрешённый сервис не открывается — либо нет интернета,")
        print("  либо список другой. Тест всё равно прогоню, но выводы под вопросом.\n")

    if blocked_ok:
        print("\n⚠ контрольный «запрещённый» адрес открыт — похоже, белого списка сейчас нет.")
        print("  Результаты ниже ничего не доказывают, повтори тест во время ограничений.\n")

    whitelist_active = allowed_ok and not blocked_ok

    rows = []
    for name, ip in candidates:
        res = {port: tcp_ok(ip, port, args.timeout) for port in PORTS}
        mark = lambda ok: "✅" if ok else "—"  # noqa: E731
        rows.append(
            {
                "name": name,
                "ip": ip,
                "443": res[443],
                "80": res[80],
                "22": res[22],
                "verdict": verdict(res, whitelist_active),
            }
        )
        print(f"{name:16} {ip:16} {mark(res[443])} {mark(res[80])} {mark(res[22])}  {rows[-1]['verdict']}")

    now = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M %Z")
    lines = [
        f"## {args.operator} / {args.region} — {now}",
        "",
        f"Контроль: gosuslugi.ru {'ok' if allowed_ok else 'НЕТ'}, "
        f"1.1.1.1 {'ok' if blocked_ok else 'НЕТ'}. "
        f"Ограничения активны: {'да' if whitelist_active else 'НЕТ — тест недействителен'}",
        "",
        "| Кандидат | IP | 443 | 80 | 22 | Вывод |",
        "|---|---|---|---|---|---|",
    ]
    for row in rows:
        lines.append(
            f"| {row['name']} | {row['ip']} | "
            f"{'✅' if row['443'] else '—'} | {'✅' if row['80'] else '—'} | "
            f"{'✅' if row['22'] else '—'} | {row['verdict']} |"
        )
    lines.append("")

    with open(args.out, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")

    print(f"\nдописано в {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
