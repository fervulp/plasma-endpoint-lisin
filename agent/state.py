"""Сводка об ОС для карточки состояния. Только stdlib, без root.

Табличные данные (порты, сервисы и т.д.) собирает конвейер:
expertise/inputs/ + expertise/normalize/ (Python-плагины: normalize(text)).
"""
import os
import platform
import pwd
import time
from pathlib import Path


def os_info() -> dict:
    osr = {}
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                osr[k] = v.strip('"')
    except OSError:
        pass
    uptime_s = 0.0
    try:
        uptime_s = float(Path("/proc/uptime").read_text().split()[0])
    except OSError:
        pass
    d, rem = divmod(int(uptime_s), 86400)
    h, rem = divmod(rem, 3600)
    mem_kb = 0
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                mem_kb = int(line.split()[1])
                break
    except OSError:
        pass
    cpu = ""
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    u = platform.uname()
    return {
        "os": osr.get("PRETTY_NAME", u.system),
        "kernel": u.release,
        "hostname": u.node,
        "arch": u.machine,
        "cpu": cpu,
        "mem_gb": round(mem_kb / 1048576, 1),
        "uptime": f"{d}d {h}h {rem // 60}m",
        "boot_time": time.strftime("%Y-%m-%d %H:%M", time.localtime(time.time() - uptime_s)),
        "user": pwd.getpwuid(os.getuid()).pw_name,
    }
