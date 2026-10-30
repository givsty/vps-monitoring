#!/usr/bin/env python3
"""Проверяет provisioning Grafana до деплоя.

Ловит то, что иначе выстрелит только при старте контейнера:
  * битый YAML;
  * правило без uid/condition/data;
  * condition, ссылающийся на несуществующий refId;
  * дубли uid;
  * контакт-поинт без получателей.
"""

from __future__ import annotations

import pathlib
import sys

try:
    import yaml
except ImportError:
    # В CI PyYAML может отсутствовать; без него проверка бессмысленна.
    print("PyYAML не установлен, пропускаю проверку", file=sys.stderr)
    sys.exit(2)

ROOT = pathlib.Path(__file__).resolve().parent.parent / "grafana" / "provisioning"
errors: list[str] = []


def load(path: pathlib.Path):
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        errors.append(f"{path.name}: {exc}")
        return None


rules_path = ROOT / "alerting" / "rules.yml"
data = load(rules_path)
count = 0
if data:
    groups = data.get("groups") or []
    if not groups:
        errors.append("rules.yml: нет ни одной группы")

    seen: set[str] = set()
    for group in groups:
        if not group.get("name"):
            errors.append("rules.yml: у группы нет name")
        if not group.get("folder"):
            errors.append("rules.yml: у группы нет folder")

        for rule in group.get("rules") or []:
            uid = rule.get("uid")
            if not uid:
                errors.append("rules.yml: правило без uid")
                continue
            if uid in seen:
                errors.append(f"{uid}: дубль uid")
            seen.add(uid)
            count += 1

            for field in ("title", "condition", "data", "noDataState", "labels"):
                if field not in rule:
                    errors.append(f"{uid}: нет поля {field}")

            refs = {item.get("refId") for item in rule.get("data") or []}
            if rule.get("condition") not in refs:
                errors.append(f"{uid}: condition={rule.get('condition')} не найден среди refId {sorted(refs)}")

            first = (rule.get("data") or [{}])[0]
            if first.get("datasourceUid") != "prometheus":
                errors.append(f"{uid}: первый запрос должен смотреть в datasource uid=prometheus")

cp_path = ROOT / "alerting" / "contact-points.yml"
cp = load(cp_path)
if cp:
    points = cp.get("contactPoints") or []
    if not points:
        errors.append("contact-points.yml: нет контакт-поинтов")
    for point in points:
        receivers = point.get("receivers") or []
        if not receivers:
            errors.append(f"contact-points.yml: у {point.get('name')} нет receivers")
        for receiver in receivers:
            if not receiver.get("type"):
                errors.append(f"contact-points.yml: у {receiver.get('uid')} нет type")

pol = load(ROOT / "alerting" / "policies.yml")
if pol:
    if not pol.get("policies"):
        errors.append("policies.yml: нет policies")

ds = load(ROOT / "datasources" / "prometheus.yml")
if ds:
    uids = {d.get("uid") for d in ds.get("datasources") or []}
    if "prometheus" not in uids:
        errors.append("datasources: нет datasource с uid=prometheus (нужен правилам)")

if errors:
    print("✗ Provisioning Grafana:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

print(f"✓ provisioning ок: правил {count}, контакт-поинтов {len(cp.get('contactPoints') or []) if cp else 0}")
