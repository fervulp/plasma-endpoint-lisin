"""Who is behind an IP: ASN, the owning organisation, country, reverse DNS.

WITHOUT API keys and without third-party libraries:
  * ASN/country - the Team Cymru DNS service (origin.asn.cymru.com), an
    ordinary TXT query through dig: it works everywhere, needs no registration
    and no HTTP;
  * the ASN organisation - AS<n>.asn.cymru.com;
  * reverse DNS - stdlib socket;

Private/service addresses are NOT SENT OUTSIDE (that would leak the topology) -
they are marked as private locally. Results are cached on disk (TTL 7 days), and
in one run we make no more than MAX_NEW new queries so that the pipeline does not
block on network timeouts - the rest is picked up by the following runs.
"""
import ipaddress
import json
import socket
import subprocess
import time
from pathlib import Path

CACHE_PATH = Path.home() / ".local/share/lisin/ipintel.json"
TTL = 7 * 24 * 3600
MAX_NEW = 20            # new (uncached) addresses per run
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
    """origin.asn.cymru.com: '64496 | 192.0.2.0/24 | US | arin | 2023-12-28'."""
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
    """The fallback path: the organisation name from whois(1)."""
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
    """{ip: {as_number, as_org, country, rdns, scope}} with a cache and a limit."""
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
            continue            # we will finish these on the next run
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
    """THE FULL WHOIS for an address - for an interactive query from the interface.

    Unlike lookup_many() (a fast ASN over DNS for bulk enrichment) here whois(1)
    is asked and the fields needed during an investigation are parsed: whose
    network it is, the range, the country, the abuse contact.
    Private addresses are NOT sent outside.
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
