#!/usr/bin/env python3
"""The bridge between the interface and what flatpak knows.

Read-only in this first slice, deliberately. Everything the pages show is a
measurement of the system as it is — what each application asked for, what this
machine has overridden, and what the sandbox will therefore get. Nothing is
changed until the interface can show the difference clearly, because a control
that writes before it can display the result is a control nobody can trust.

The threading rule is v1's, and it earned it: a slot the interface calls runs on
the thread that draws the window, so anything expensive is cached and refreshed
by a worker instead. `flatpak info` costs about a tenth of a second per
application, and a page that asks for it per keystroke would stutter.
"""
from __future__ import annotations

import os
import threading
import time

from PySide6.QtCore import QObject, Signal, Slot

from core import flatpak


class Backend(QObject):
    appsReady = Signal("QVariant")

    # How long a reading of the system stays good. Permissions change when
    # somebody changes them — not on a timer — so this only has to be short
    # enough that a change made elsewhere shows up while you are looking.
    TTL = 5.0

    def __init__(self):
        super().__init__()
        self._cache: dict[str, tuple[float, object]] = {}
        self._lock = threading.RLock()
        if not os.environ.get("LISIN_NO_COLLECT"):
            threading.Thread(target=self._refresh_loop, daemon=True).start()

    # ------------------------------------------------------------- plumbing
    def _cached(self, key: str, fn, ttl: float | None = None):
        now = time.time()
        with self._lock:
            hit = self._cache.get(key)
            if hit and now - hit[0] < (ttl or self.TTL):
                return hit[1]
        value = fn()
        with self._lock:
            self._cache[key] = (now, value)
        return value

    def _refresh_loop(self):
        while True:
            try:
                self._cache.clear()
                self.appsReady.emit(self.applications())
            except RuntimeError:
                return                      # the window is gone
            except Exception:               # noqa: BLE001 — a failed read is not fatal
                pass
            time.sleep(10)

    # ---------------------------------------------------------------- slots
    @Slot(result="QVariant")
    def applications(self):
        """Every installed application, with what it costs and what it may do —
        enough for the list, without paying for the detail of each one."""
        def build():
            out = []
            for app in flatpak.applications():
                eff = flatpak.effective(app["id"])
                allowed = sum(len(v["granted"]) for v in eff.values())
                denied = sum(len(v["denied"]) for v in eff.values())
                out.append(dict(app,
                                permissions=allowed,
                                denials=denied,
                                escapes=flatpak.can_escape(app["id"]),
                                network="network" in eff["shared"]["granted"],
                                overridden=bool(
                                    (flatpak.overrides_dir() / app["id"]).exists())))
            return out
        return self._cached("apps", build)

    @Slot(result=bool)
    def flatpakAvailable(self):
        return flatpak.available()

    @Slot(str, result="QVariant")
    def application(self, app_id):
        """Everything about ONE application: what it says it is, what it weighs
        with what it runs on, and its permissions in three columns — asked for,
        overridden here, and what the sandbox will actually get."""
        def build():
            info = flatpak.describe(app_id)
            req, ovr, eff = (flatpak.requested(app_id), flatpak.override(app_id),
                             flatpak.effective(app_id))
            cats = []
            for key, title, why, icon in flatpak.CATEGORIES:
                e = eff.get(key, {"granted": [], "denied": []})
                # A FAMILY THAT CARRIES THE SANDBOX ESCAPE IS NOT LIKE THE OTHERS.
                # The block is marked, so the eye lands on it before it starts
                # reading forty chips — the alternative is a red line somewhere in
                # the middle of a list nobody reads to the end.
                alarming = any(x.split("=")[0] == flatpak.ESCAPE_NAME
                               for x in e["granted"])
                cats.append({
                    "key": key, "title": title, "why": why, "icon": icon,
                    "alarming": alarming,
                    "requested": req.get(key, []),
                    "override": ovr.get(key, []),
                    "granted": e["granted"], "denied": e["denied"],
                })
            return {
                "id": app_id,
                "summary": info.get("summary", ""),
                "version": info.get("version", ""),
                "license": info.get("license", ""),
                "origin": info.get("origin", ""),
                "installation": info.get("installation", ""),
                "size": info.get("installed_size", ""),
                "runtime": info.get("runtime", ""),
                "depends": flatpak.dependencies(app_id),
                "weight": flatpak.total_size(app_id),
                "categories": cats,
                "escapes": flatpak.can_escape(app_id),
                "portals": flatpak.portal_permissions(app_id),
                "override_file": str(flatpak.overrides_dir() / app_id),
                "has_override": (flatpak.overrides_dir() / app_id).exists(),
            }
        return self._cached("app:" + app_id, build)
