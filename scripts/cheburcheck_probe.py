#!/usr/bin/env python3
"""Проверка блокировок через cheburcheck.ru -> метрики для Prometheus.

Делает две вещи:
  1. GET /api/v1/check?target=...  — есть ли IP/домен в списках РКН и CDN;
  2. GET /api/v1/probe/<id>        — динамическое сканирование: живые вердикты
     российских сканеров (tspu_block, sni_block, dns_spoofing, ok, uncertain).

Результат пишется в формате node_exporter textfile, чтобы Prometheus подхватил
его без отдельного экспортёра.

Запуск (вручную):
    ./cheburcheck_probe.py --target vpn-xxx.duckdns.org \
        --out /var/lib/node_exporter/textfile/chebur.prom
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_API = "https://cheburcheck.ru/api/v1"
USER_AGENT = "vps-monitoring/1.0 (+https://github.com/givsty/vps-monitoring)"
# Вердикты, которые умеет отдавать cheburcheck (на случай новых — не падаем).
KNOWN_VERDICTS = (
    "ok",
    "tspu_block",
    "sni_block",
    "dns_spoofing",
    "cdn_block",
    "whitelist",
    "uncertain",
)


def log(msg: str) -> None:
    print(f"[cheburcheck] {msg}", file=sys.stderr, flush=True)


def escape_label(value: object) -> str:
    text = str(value)
    return text.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def resolve_ipv4(target: str) -> str:
    """Домены резолвим сами: для AmneziaWG важен вердикт по IP, а не по SNI."""
    try:
        return str(ipaddress.ip_address(target))
    except ValueError:
        pass
    infos = socket.getaddrinfo(target, None, socket.AF_INET, socket.SOCK_STREAM)
    if not infos:
        raise RuntimeError(f"не удалось разрешить {target!r} в IPv4")
    return infos[0][4][0]


def build_ssl_context(ca_bundle: str | None) -> ssl.SSLContext:
    """На дистрибутивах Python без системных CA (часто macOS) выручает certifi."""
    if ca_bundle:
        return ssl.create_default_context(cafile=ca_bundle)
    try:
        import certifi  # noqa: PLC0415 — необязательная зависимость

        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def http_get(url: str, accept: str, timeout: float, context: ssl.SSLContext):
    request = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "Accept": accept}
    )
    return urllib.request.urlopen(request, timeout=timeout, context=context)


def fetch_check(api: str, target: str, timeout: float, context: ssl.SSLContext) -> dict:
    url = f"{api}/check?target={urllib.parse.quote(target)}"
    with http_get(url, "application/json", timeout, context) as response:
        return json.loads(response.read().decode("utf-8"))


def stream_probe(
    api: str, job_id: str, budget: float, context: ssl.SSLContext
) -> tuple[list[dict], dict]:
    """Читает SSE до события done или до исчерпания бюджета времени."""
    url = f"{api}/probe/{urllib.parse.quote(job_id)}"
    results: list[dict] = []
    meta: dict = {}
    deadline = time.monotonic() + budget

    try:
        with http_get(url, "text/event-stream", budget, context) as response:
            for raw in response:
                if time.monotonic() > deadline:
                    log("бюджет времени на SSE исчерпан, беру что успело прийти")
                    break
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                try:
                    payload = json.loads(line[len("data:") :].strip())
                except ValueError:
                    continue
                if isinstance(payload, dict) and "verdicts" in payload:
                    results.append(payload)
                elif isinstance(payload, dict) and payload.get("status") == "done":
                    meta = payload
                    break
    except (urllib.error.URLError, socket.timeout, TimeoutError) as exc:
        log(f"SSE прервался: {exc}")
        meta["error"] = str(exc)

    return results, meta


def build_metrics(
    target: str,
    ip: str,
    check: dict,
    results: list[dict],
    meta: dict,
    run_ok: bool,
) -> str:
    now = int(time.time())
    lines: list[str] = []

    geo = check.get("geo") or {}
    asn_info = check.get("asn_info") or {}
    asn = geo.get("asn") or asn_info.get("asn") or ""
    country = geo.get("country_code") or ""
    org = geo.get("organisation") or ""

    lines.append(
        "chebur_target_info"
        f'{{target="{escape_label(target)}",ip="{escape_label(ip)}",'
        f'asn="{escape_label(asn)}",country="{escape_label(country)}",'
        f'org="{escape_label(org)}"}} 1'
    )
    lines.append(
        f'chebur_listed_in_rkn{{target="{escape_label(ip)}"}} '
        f"{1 if check.get('blocked') else 0}"
    )
    lines.append(f"chebur_run_ok {1 if run_ok else 0}")
    lines.append(f"chebur_last_run_timestamp {now}")
    if run_ok:
        lines.append(f"chebur_last_success_timestamp {now}")

    responses = len(results)
    lines.append(f"chebur_probe_responses {responses}")
    online = meta.get("online_probes")
    if isinstance(online, int):
        lines.append(f"chebur_probe_online {online}")

    counts: dict[str, int] = {}
    for result in results:
        for verdict in set(result.get("verdicts") or []):
            counts[verdict] = counts.get(verdict, 0) + 1

    for verdict in KNOWN_VERDICTS + tuple(sorted(set(counts) - set(KNOWN_VERDICTS))):
        count = counts.get(verdict, 0)
        ratio = (count / responses) if responses else 0.0
        lines.append(f'chebur_probe_verdict_count{{verdict="{verdict}"}} {count}')
        lines.append(f'chebur_probe_verdict_ratio{{verdict="{verdict}"}} {ratio:.6f}')

    blocked = counts.get("tspu_block", 0) + counts.get("sni_block", 0)
    lines.append(f"chebur_probe_blocked_probes {blocked}")

    return "\n".join(lines) + "\n"


def write_atomic(path: str, payload: str) -> None:
    directory = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(directory, exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(payload)
    os.replace(tmp, path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--target",
        required=True,
        help="IP или домен VPN-сервера (домен будет отрезолвлен в IPv4)",
    )
    parser.add_argument(
        "--out",
        default="/var/lib/node_exporter/textfile/chebur.prom",
        help="путь к textfile-метрике",
    )
    parser.add_argument("--api", default=DEFAULT_API)
    parser.add_argument(
        "--ca-bundle",
        default=None,
        help="путь к CA-бандлу (по умолчанию системный или certifi)",
    )
    parser.add_argument("--timeout", type=float, default=20.0, help="таймаут запроса")
    parser.add_argument(
        "--budget",
        type=float,
        default=120.0,
        help="сколько секунд максимум ждать ответы сканеров",
    )
    parser.add_argument(
        "--min-responses",
        type=int,
        default=3,
        help="меньше этого числа ответов — считаем прогон неуспешным",
    )
    args = parser.parse_args()

    run_ok = False
    check: dict = {}
    results: list[dict] = []
    meta: dict = {}
    ip = args.target

    try:
        ip = resolve_ipv4(args.target)
        log(f"{args.target} -> {ip}")

        context = build_ssl_context(args.ca_bundle)
        check = fetch_check(args.api, ip, args.timeout, context)
        log(
            "check: blocked={} asn={} org={}".format(
                check.get("blocked"),
                (check.get("geo") or {}).get("asn"),
                (check.get("geo") or {}).get("organisation"),
            )
        )

        job_id = check.get("id")
        if not job_id:
            raise RuntimeError("cheburcheck не вернул id задачи для сканирования")

        results, meta = stream_probe(args.api, job_id, args.budget, context)
        log(f"probe: {len(results)} ответов, online={meta.get('online_probes')}")

        run_ok = len(results) >= args.min_responses
        if not run_ok:
            log(f"ответов меньше порога {args.min_responses}")

    except Exception as exc:  # noqa: BLE001 — любой сбой должен дать метрику
        log(f"ошибка: {exc}")

    payload = build_metrics(args.target, ip, check, results, meta, run_ok)
    write_atomic(args.out, payload)
    log(f"записано в {args.out}")

    return 0 if run_ok else 1


if __name__ == "__main__":
    sys.exit(main())
