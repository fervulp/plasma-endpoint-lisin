"""Кто стоит за IP: ASN, организация-владелец, страна, обратный DNS.

БЕЗ API-ключей и без сторонних библиотек:
  * ASN/страна — DNS-сервис Team Cymru (origin.asn.cymru.com), обычный TXT-
    запрос через dig: работает везде, не требует регистрации и HTTP;
  * организация ASN — AS<n>.asn.cymru.com;
  * обратный DNS — stdlib socket;
  * whois(1) — запасной вариант, если DNS ничего не дал.

Приватные/служебные адреса НАРУЖУ НЕ ОТПРАВЛЯЕМ (это утечка топологии) —
помечаем их локально как private. Результаты кэшируются на диске (TTL 7 дней),
за один прогон делаем не больше MAX_NEW новых запросов, чтобы конвейер не
блокировался на сетевых таймаутах — остальное подтянется следующими прогонами.
"""
import ipaddress
import json
import socket
import subprocess
import time
from pathlib import Path

CACHE_PATH = Path.home() / ".local/share/lisin/ipintel.json"
TTL = 7 * 24 * 3600
MAX_NEW = 20            # новых (несохранённых) адресов за один прогон
_MEM: dict = {}
_LOADED = False


def _load():
    global _LOADED
    if _LOADED:
        return
    _LOADED = True
    try:
        _MEM.update(json.loads(CACHE_PATH.read_text()))
    except Exception:
        pass


def _save():
    try:
        CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        CACHE_PATH.write_text(json.dumps(_MEM, ensure_ascii=False))
    except Exception:
        pass


def is_public(ip: str) -> bool:
    try:
        a = ipaddress.ip_address(ip)
    except Exception:
        return False
    return not (a.is_private or a.is_loopback or a.is_link_local
                or a.is_multicast or a.is_reserved or a.is_unspecified)


def _dig_txt(name: str) -> str:
    try:
        r = subprocess.run(["dig", "+short", "+time=2", "+tries=1", "TXT", name],
                           capture_output=True, text=True, timeout=6)
        for ln in r.stdout.strip().splitlines():
            ln = ln.strip().strip('"')
            if ln:
                return ln
    except Exception:
        pass
    return ""


def _cymru(ip: str) -> dict:
    """origin.asn.cymru.com: '15169 | 8.8.8.0/24 | US | arin | 2023-12-28'."""
    try:
        a = ipaddress.ip_address(ip)
    except Exception:
        return {}
    if a.version == 4:
        q = ".".join(reversed(ip.split("."))) + ".origin.asn.cymru.com"
    else:
        nib = a.exploded.replace(":", "")
        q = ".".join(reversed(nib)) + ".origin6.asn.cymru.com"
    txt = _dig_txt(q)
    if not txt:
        return {}
    p = [x.strip() for x in txt.split("|")]
    asn = p[0].split()[0] if p and p[0] else ""
    out = {"as_number": asn,
           "country": p[2] if len(p) > 2 else "",
           "prefix": p[1] if len(p) > 1 else ""}
    if asn:
        # 'AS15169 | US | arin | 2000-03-30 | GOOGLE - Google LLC, US'
        t2 = _dig_txt("AS%s.asn.cymru.com" % asn)
        if t2:
            q2 = [x.strip() for x in t2.split("|")]
            if q2:
                out["as_org"] = q2[-1]
    return out


def _whois_org(ip: str) -> str:
    """Запасной путь: имя организации из whois(1)."""
    try:
        r = subprocess.run(["whois", ip], capture_output=True, text=True,
                           timeout=8)
        for ln in r.stdout.splitlines():
            low = ln.lower()
            for k in ("org-name:", "orgname:", "organization:", "descr:",
                      "netname:"):
                if low.startswith(k):
                    v = ln.split(":", 1)[1].strip()
                    if v:
                        return v
    except Exception:
        pass
    return ""


def _rdns(ip: str) -> str:
    try:
        return socket.gethostbyaddr(ip)[0]
    except Exception:
        return ""


def lookup_many(ips) -> dict:
    """{ip: {as_number, as_org, country, rdns, scope}} с кэшем и лимитом."""
    _load()
    now = time.time()
    out, fresh = {}, 0
    for ip in ips:
        if not ip:
            continue
        if ip in out:
            continue
        hit = _MEM.get(ip)
        if hit and now - hit.get("ts", 0) < TTL:
            out[ip] = hit["d"]
            continue
        if not is_public(ip):
            d = {"scope": "private", "as_number": "", "as_org": "",
                 "country": "", "rdns": ""}
            _MEM[ip] = {"ts": now, "d": d}
            out[ip] = d
            continue
        if fresh >= MAX_NEW:
            continue            # добьём на следующем прогоне
        fresh += 1
        d = {"scope": "public"}
        d.update(_cymru(ip))
        d.setdefault("as_number", "")
        d.setdefault("country", "")
        if not d.get("as_org"):
            d["as_org"] = _whois_org(ip)
        d["rdns"] = _rdns(ip)
        _MEM[ip] = {"ts": now, "d": d}
        out[ip] = d
    if fresh:
        _save()
    return out


def lookup(ip: str) -> dict:
    return lookup_many([ip]).get(ip, {})


def whois_details(ip: str) -> dict:
    """ПОЛНЫЙ WHOIS по адресу — для интерактивного запроса из интерфейса.

    В отличие от lookup_many() (быстрый ASN через DNS для массового
    обогащения) здесь спрашивается whois(1) и разбираются поля, которые
    нужны при расследовании: чья сеть, диапазон, страна, контакт для жалоб.
    Приватные адреса наружу НЕ отправляются.
    """
    out = {"ip": ip, "scope": "public", "raw": ""}
    if not is_public(ip):
        return {"ip": ip, "scope": "private",
                "note": "private address — not sent to external whois", "raw": ""}
    try:
        r = subprocess.run(["whois", ip], capture_output=True, text=True,
                           timeout=15)
        text = r.stdout or ""
    except Exception as e:
        return {"ip": ip, "scope": "public", "error": str(e), "raw": ""}

    FIELDS = {
        "netname": ("netname",), "organization": ("org-name", "orgname",
                                                  "organization", "owner"),
        "descr": ("descr",), "country": ("country",),
        "range": ("inetnum", "netrange", "cidr", "route"),
        "abuse": ("abuse-mailbox", "orgabuseemail"),
        "registrar": ("source", "registrar"),
        "created": ("created", "regdate"),
        "updated": ("last-modified", "updated"),
    }
    low = {}
    for ln in text.splitlines():
        if ":" not in ln or ln.strip().startswith(("%", "#")):
            continue
        k, _, v = ln.partition(":")
        k, v = k.strip().lower(), v.strip()
        if v:
            low.setdefault(k, v)
    for dst, keys in FIELDS.items():
        for k in keys:
            if k in low:
                out[dst] = low[k]
                break
    out["rdns"] = _rdns(ip)
    cy = _cymru(ip)
    out["as_number"] = cy.get("as_number", "")
    out["as_org"] = cy.get("as_org", "")
    out["prefix"] = cy.get("prefix", "")
    out["raw"] = text[:6000]
    return out
