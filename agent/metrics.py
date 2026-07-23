"""Host metrics and LiSin resource usage."""
import collections
import os
import subprocess
import time
from pathlib import Path


class Sampler:
    """CPU/RAM sampler: a sliding 30 minute window sampled every 10 seconds."""

    def __init__(self):
        self.series = collections.deque(maxlen=181)
        self._cpu_prev = None

    def sample(self):
        try:
            with open("/proc/stat") as f:
                v = [int(x) for x in f.readline().split()[1:]]
            total, idle = sum(v), v[3] + v[4]
            cpu = 0.0
            if self._cpu_prev:
                dt = total - self._cpu_prev[0]
                di = idle - self._cpu_prev[1]
                cpu = round(100 * (dt - di) / dt, 1) if dt > 0 else 0.0
            self._cpu_prev = (total, idle)
            mi = {}
            with open("/proc/meminfo") as f:
                for ln in f:
                    k, _, rest = ln.partition(":")
                    mi[k] = int(rest.split()[0])
            mem = round(100 * (mi["MemTotal"] - mi["MemAvailable"])
                        / mi["MemTotal"], 1)
            self.series.append({"t": time.time(), "cpu": cpu, "mem": mem})
        except Exception:
            pass


def _du_mb(path) -> int:
    try:
        out = subprocess.run(["du", "-sm", str(path)], capture_output=True,
                             text=True, timeout=20).stdout
        return int(out.split()[0])
    except Exception:
        return 0


def _rss_mb(pattern: str) -> int:
    try:
        out = subprocess.run(
            ["bash", "-c", f"ps -o rss= -C {pattern} 2>/dev/null | "
             "awk '{s+=$1} END {print s+0}'"],
            capture_output=True, text=True, timeout=5).stdout
        return round(int(out.strip() or 0) / 1024)
    except Exception:
        return 0


def resource_usage() -> dict:
    try:
        with open(f"/proc/{os.getpid()}/status") as f:
            rss = next((ln for ln in f if ln.startswith("VmRSS")), "0 0 kB")
        app_mb = round(int(rss.split()[1]) / 1024)
    except Exception:
        app_mb = 0
    return {"app_mb": app_mb}


def system_metrics(series: list) -> dict:
    try:
        load = open("/proc/loadavg").read().split()[:3]
    except OSError:
        load = []
    home = Path.home()
    db = home / ".local/share/lisin/state.db"
    return {
        "series": list(series),
        "load": load,
        "disk": {
            "app_mb": _du_mb(Path(__file__).resolve().parent.parent),
            "db_mb": round(db.stat().st_size / 1e6) if db.exists() else 0,
        },
    }
