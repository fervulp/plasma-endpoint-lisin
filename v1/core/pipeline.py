"""v1 collection pipeline: input → store, then the declarative derivation layer.

An input is a self-contained YAML rule: an osquery query plus the destination
table. On each run the query executes and its full result replaces the table.

LOCKING: an osquery run is a SUBPROCESS that can take seconds, and the UI reads
through the same store lock — holding the lock across collection froze the window
for the whole cycle. So collection happens in two phases: query everything with
NO lock held, then take the lock only for the writes (which are fast). The store
is briefly a mix of old and new tables between the two phases; that is fine — the
UI reads one table at a time and every table is internally consistent.
"""
from __future__ import annotations

import glob
import os
from concurrent import futures
import tempfile
import time
from pathlib import Path

from . import osquery, shell, views
from .db import load_yaml_dir
from .store import Store

INPUTS_DIR = Path(__file__).resolve().parent.parent / "expertise" / "inputs"

# How often an input runs, in seconds, when its rule does not say. An input may
# declare its own `interval:` — the inventory of installed packages does not need
# re-reading as often as the process list, and with dozens of sources running
# everything on the shortest interval would keep the machine busy for nothing.
DEFAULT_INTERVAL = 30
# how many sources are queried at once (they are external processes)
WORKERS = int(os.environ.get("LISIN_COLLECT_WORKERS", "6"))
_last_run: dict[str, float] = {}


def load_inputs() -> list[dict]:
    return load_yaml_dir(INPUTS_DIR)


def sweep_temp(older_than: int = 600) -> int:
    """Delete our own leftover collection files. The normal path removes them in
    a finally block, but a process killed mid-collection cannot — and the files
    are a megabyte each. Only our own prefixes, and only ones old enough that no
    running collection could still be using them — a collection is capped
    at a minute, so ten is far past any live one."""
    now = time.time()
    gone = 0
    for pat in ("lisin-osq-*.json", "lisin-cmd-*.tsv"):
        for p in glob.glob(os.path.join(tempfile.gettempdir(), pat)):
            try:
                if now - os.path.getmtime(p) > older_than:
                    os.unlink(p)
                    gone += 1
            except OSError:
                pass
    return gone


def _due(inp: dict, now: float, force: bool) -> bool:
    if force:
        return True
    name = str(inp.get("name") or inp.get("table") or "")
    iv = inp.get("interval", DEFAULT_INTERVAL)
    try:
        iv = float(iv)
    except (TypeError, ValueError):
        iv = DEFAULT_INTERVAL
    return (now - _last_run.get(name, float("-inf"))) >= iv


def run_once(store: Store, force: bool = False) -> list[dict]:
    """Run every enabled input that is DUE. Returns per-input status (numbers,
    not prose, so a run can be verified against v0)."""
    # phase 1: query — subprocesses, no lock held, the UI stays responsive.
    # IN PARALLEL: every source is an external process (osqueryi, rpm, dnf), so
    # the work is waiting, not computing — running them one after another made a
    # full cycle the SUM of thirty-eight waits. Threads are the right tool here
    # precisely because nothing runs in Python while they wait.
    now = time.monotonic()
    due = []
    for inp in load_inputs():
        if inp.get("enabled") is False:
            continue
        kind = str(inp.get("kind", ""))
        if kind == "tetragon":
            continue                      # a stream, not a query (its own reader)
        if not inp.get("query") and not inp.get("command"):
            continue                      # nothing to collect with
        if not _due(inp, now, force):
            continue
        table = inp.get("table") or inp.get("name")
        _last_run[str(inp.get("name") or table)] = now
        due.append((table, kind, inp))

    def collect(item):
        """Run ONE source. Returns (table, path, error, tsv_columns)."""
        table, kind, inp = item
        try:
            # the result lands in a FILE; DuckDB reads it in phase 2. It never
            # becomes Python objects — that conversion was the whole cost of a
            # collection cycle (75 s -> 13 s once it was removed).
            if kind == "command":
                return (table, shell.run_to_file(inp["command"]), "",
                        list(inp.get("tsv_columns") or []))
            return (table, osquery.run_to_file(inp["query"]), "", None)
        except Exception as e:  # noqa: BLE001 — a bad rule must not kill the run
            return (table, None, str(e), None)

    collected = []
    if due:
        # a modest pool: these are subprocesses competing for the same disk and
        # the same osquery tables, and the machine has other work to do
        workers = min(WORKERS, len(due))
        with futures.ThreadPoolExecutor(max_workers=workers) as pool:
            collected = list(pool.map(collect, due))

    # phase 2: write — under the lock, but only for the fast part
    status = []
    try:
        with store._lock:
            for table, path, err, tsv_cols in collected:
                if err:
                    status.append({"table": table, "rows": 0, "error": err})
                    continue
                try:
                    n = (store.replace_table_from_tsv(table, path, tsv_cols)
                         if tsv_cols is not None
                         else store.replace_table_from_json(table, path))
                    status.append({"table": table, "rows": n, "error": ""})
                except Exception as e:  # noqa: BLE001
                    status.append({"table": table, "rows": 0, "error": str(e)})
    finally:
        for _t, path, _e, _c in collected:  # never leave the temp files behind
            if path:
                try:
                    os.unlink(path)
                except OSError:
                    pass
    return status


def run_all(store: Store, force: bool = False) -> dict:
    """Collect the inputs that are due, then rebuild the declarative derivation
    layer (enrichment views + validated edges). Each phase takes the store lock
    itself, so the collector never holds it across a subprocess. The derivation
    is skipped when nothing was collected — the views would only be re-created
    over unchanged tables."""
    inputs = run_once(store, force=force)
    derive: dict = {}
    if inputs:
        with store._lock:
            derive = views.apply(store)
    return {"inputs": inputs, "derive": derive}
