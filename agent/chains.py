"""ЦЕПОЧКИ СОБЫТИЙ: от отдельных записей к связной истории.

Одиночное событие почти ничего не значит: «открыто соединение», «запущен
процесс», «изменён файл». Значение появляется, когда видно ПОСЛЕДОВАТЕЛЬНОСТЬ:
пользователь вошёл → запустил оболочку → та скачала файл → файл запустился →
пошло соединение наружу. Расследуют именно цепочку, а не строку.

Чем связываем — тем, что реально есть в таксономии, без догадок:

  1. РОДОСЛОВНАЯ ПРОЦЕССОВ — основа. У событий запуска есть process_pid и
     parent_pid; по ним строится карта «потомок → предок», и каждое событие
     поднимается до КОРНЯ своей ветки. Корень и есть идентификатор цепочки.
  2. Событие без процесса (часть журнала, аудит без pid) привязывается по
     пользователю и окну времени — но помечается как связанное слабее.

Цепочка отвечает на четыре вопроса сразу: кто (субъект и пользователь),
когда (начало и конец), что делал (категории и действия по шагам), куда
ходил (адреса). К ней уже можно привязывать всё остальное.
"""
# порядок важности категорий: по ним считается «на что похожа» цепочка
CAT_ORDER = ["process", "authentication", "file", "network", "package",
             "iam", "intrusion_detection"]


def _rows(eventsdb, sql, args=(), max_rows=0):
    try:
        return eventsdb.query(sql, args, max_rows=max_rows).get("rows", [])
    except Exception:
        return []


def _short(cmd: str) -> str:
    cmd = (cmd or "").strip()
    if not cmd:
        return ""
    first = cmd.split()[0]
    return first.rsplit("/", 1)[-1]


def build(eventsdb, limit: int = 4000, min_len: int = 2,
          statedb=None, want_steps=None, want_index=False) -> dict:
    """Собрать цепочки из последних событий.

    limit — сколько последних событий рассматриваем (цепочки строятся по
    окну, а не по всей базе: иначе на сотнях тысяч записей это бессмысленно
    долго и цепочки склеиваются между собой).
    """
    if eventsdb is None:
        return {"chains": [], "total": 0, "linked": 0, "events": 0}

    # ВСЕ поля: шаги цепочки показываются той же таблицей и той же боковой
    # панелью, что и обычная лента, поэтому им нужна вся таксономия
    ev = _rows(eventsdb, "SELECT * FROM events ORDER BY _id DESC LIMIT ?",
               (int(limit),), max_rows=int(limit))
    ev.reverse()                       # хронологический порядок
    if not ev:
        return {"chains": [], "total": 0, "linked": 0, "events": 0}

    # ---- карта родословной: pid -> ppid ----
    # Строится ШИРЕ, чем окно: у событий journal/audit/netmon есть pid, но
    # НЕТ parent_pid, поэтому по одному окну они не поднимались до корня и
    # связывались лишь слабо, по пользователю. Берём родословную из двух
    # полных источников: все события procmon (у них ppid есть всегда) и
    # ЖИВОЙ снимок процессов состояния. После этого событие с одним только
    # pid находит свою ветку.
    parent = {}
    name_of = {}
    for r in _rows(eventsdb,
                   "SELECT process_pid p, parent_pid pp, process_name n "
                   "FROM events WHERE COALESCE(parent_pid,'') <> '' "
                   "ORDER BY _id DESC LIMIT 40000", max_rows=40000):
        pp_, p_ = str(r["pp"] or "").strip(), str(r["p"] or "").strip()
        if p_ and pp_ and p_ != pp_:
            parent.setdefault(p_, pp_)
        if p_ and r["n"]:
            name_of.setdefault(p_, r["n"])
    if statedb is not None:
        try:
            import sqlite3
            con = sqlite3.connect("file:%s?mode=ro" % statedb.path, uri=True)
            for pid_, ppid_, cmd_ in con.execute(
                    "SELECT pid, ppid, command FROM processes"):
                a_, b_ = str(pid_ or "").strip(), str(ppid_ or "").strip()
                if a_ and b_ and a_ != b_:
                    parent.setdefault(a_, b_)
                if a_ and cmd_ and a_ not in name_of:
                    name_of[a_] = str(cmd_).split()[0].rsplit("/", 1)[-1]
            con.close()
        except Exception:
            pass
    for e in ev:
        p = str(e.get("process_pid") or "").strip()
        pp = str(e.get("parent_pid") or "").strip()
        if p and pp and p != pp:
            parent.setdefault(p, pp)
        if p and e.get("process_name"):
            name_of.setdefault(p, e["process_name"])

    # ГРАНИЦА ИСТОРИИ — команда, которую запустил пользователь.
    # Родословная сама по себе границы не даёт: всё в сессии сходится к
    # systemd, и получалась ОДНА цепочка на 15000 событий, из которой
    # ничего не вычитать. Поэтому поднимаемся только до процесса, чей
    # РОДИТЕЛЬ — интерактивная оболочка. Список оболочек берём из
    # /etc/shells: system сама объявляет, что считает оболочкой входа,
    # никаких имён от нас.
    shells = set()
    try:
        with open("/etc/shells") as f:
            for ln in f:
                ln = ln.strip()
                if ln and not ln.startswith("#"):
                    shells.add(ln.rsplit("/", 1)[-1])
    except OSError:
        pass

    def root_of(pid: str) -> str:
        """Корень ветки — но НЕ init.

        Если подниматься до самого верха, всё, что запущено в графической
        сессии, оказывается в ОДНОЙ цепочке имени какого-нибудь
        dbus-broker-launch: 900 событий, из которых историю не вычитать.
        Поэтому останавливаемся на ПОСЛЕДНЕМ предке, у которого ещё есть
        свой предок в карте, — то есть на приложении, запущенном
        менеджером сессии (терминал, браузер, служба), а не на менеджере.
        Признак структурный: «родитель родителя уже неизвестен» — никаких
        списков имён.

        Защита от петель обязательна: pid переиспользуются, и цикл в карте
        предков подвесил бы сборку.
        """
        seen, cur = set(), str(pid)
        while cur not in seen:
            seen.add(cur)
            up = parent.get(cur)
            if up is None or up in seen:
                return cur
            # родитель — интерактивная оболочка: значит ТЕКУЩИЙ процесс и
            # есть введённая команда, дальше подниматься незачем
            if name_of.get(up, "").rsplit("/", 1)[-1] in shells:
                return cur
            # выше родителя ничего не знаем — он менеджер сессии
            if parent.get(up) is None:
                return cur
            cur = up
        return cur

    # ---- КАСКАД СВЯЗЫВАНИЯ ----
    # Одна родословная покрывает только события, у которых есть pid: у
    # netmon без владельца, rpmdb, fim, statediff его нет по природе. Но это
    # не значит, что они «ничьи» — их можно привязать по ДРУГИМ фактам, и
    # каждый способ честно помечается, чтобы было видно, насколько связь
    # надёжна:
    #   1) ancestry — тот же процесс или его предок (самая надёжная);
    #   2) socket   — тот же сокет (адрес и порт с обеих сторон), что уже
    #                 встречался у события с известным владельцем;
    #   3) object   — тот же файл/пакет, которого касалась цепочка;
    #   4) time     — тот же пользователь и то же окно времени (слабая).
    LINK_STRENGTH = {"ancestry": "strong", "socket": "strong",
                     "object": "medium", "time": "weak"}

    def sock_key(e):
        d = str(e.get("destination_ip") or "")
        dp = str(e.get("destination_port") or "")
        return (d + ":" + dp) if d else ""

    def obj_key(e):
        for f in ("file_path", "object_name", "package_name"):
            v = str(e.get(f) or "").strip()
            if v:
                return v
        return ""

    chains = {}
    by_link = {}
    sock_owner, obj_owner, user_last = {}, {}, {}

    def touch(key, e, how):
        c = chains.get(key)
        if c is None:
            c = chains[key] = {
                "id": key, "how": how, "steps": [], "pids": [],
                "cats": {}, "actions": {}, "dests": {}, "users": [],
                "links": {}, "severity": 0,
                "start": e["ts"], "end": e["ts"]}
        c["steps"].append(e)
        c["end"] = e["ts"]
        c["links"][how] = c["links"].get(how, 0) + 1
        by_link[how] = by_link.get(how, 0) + 1
        pid = str(e.get("process_pid") or "").strip()
        if pid and pid not in c["pids"]:
            c["pids"].append(pid)
        cat = e.get("event_category") or ""
        if cat:
            c["cats"][cat] = c["cats"].get(cat, 0) + 1
        act = e.get("event_action") or ""
        if act:
            c["actions"][act] = c["actions"].get(act, 0) + 1
        d = e.get("destination_ip") or ""
        if d:
            c["dests"][d] = c["dests"].get(d, 0) + 1
        u = (e.get("subject_name") or e.get("user_name") or "").strip()
        if u and u not in c["users"]:
            c["users"].append(u)
        try:
            c["severity"] = max(c["severity"], int(e.get("event_severity") or 0))
        except (TypeError, ValueError):
            pass
        # запоминаем «отпечатки» цепочки, чтобы к ней могли привязаться
        # последующие события без процесса
        sk = sock_key(e)
        if sk:
            sock_owner[sk] = key
        ok = obj_key(e)
        if ok:
            obj_owner[ok] = key
        # ОТПЕЧАТОК ПО КОМАНДНОЙ СТРОКЕ. События rpmdb («установлен btop») и
        # переходы состояния не имеют pid и по родословной не привязываются.
        # Но имя пакета стоит АРГУМЕНТОМ у команды, которая его ставила:
        # «sudo dnf install btop». Регистрируем значимые аргументы как
        # отпечаток цепочки — тогда «установлен btop» находит именно ту
        # команду, а не общую кучу. Это связь средней надёжности, и она
        # помечена как object.
        cmd = str(e.get("process_command_line") or "")
        if cmd:
            for tok in cmd.split():
                tok = tok.strip("\"'`")
                if (len(tok) > 3 and not tok.startswith("-")
                        and "/" not in tok and tok not in ("sudo", "install",
                                                           "remove", "update")):
                    obj_owner.setdefault(tok, key)
        if u:
            user_last[u] = key

    for e in ev:
        pid = str(e.get("process_pid") or "").strip()
        if pid:
            touch("proc:" + root_of(pid), e, "ancestry")
            continue
        sk = sock_key(e)
        if sk and sk in sock_owner:
            touch(sock_owner[sk], e, "socket")
            continue
        ok = obj_key(e)
        if ok and ok in obj_owner:
            touch(obj_owner[ok], e, "object")
            continue
        u = (e.get("subject_name") or e.get("user_name") or "").strip()
        if u and u in user_last:
            touch(user_last[u], e, "time")
            continue
        if u:
            touch("user:" + u, e, "time")
            continue
        # совсем без опознавательных знаков — отдельная цепочка источника,
        # чтобы событие всё равно было видно, а не потерялось
        touch("mod:" + str(e.get("event_module") or "?"), e, "time")

    linked = by_link.get("ancestry", 0) + by_link.get("socket", 0)

    out = []
    for key, c in chains.items():
        if len(c["steps"]) < min_len:
            continue
        root_pid = key.split(":", 1)[1]
        first = c["steps"][0]
        title = name_of.get(root_pid) or _short(first.get("process_command_line")) \
            or first.get("process_name") or root_pid
        # разнообразие категорий — признак «содержательной» цепочки:
        # запуск + сеть + файл интереснее, чем сто одинаковых записей
        span = len(c["cats"])
        out.append({
            "id": key, "title": title, "how": c["how"],
            "root_pid": root_pid if key.startswith("proc:") else "",
            "users": ", ".join(c["users"][:3]),
            "start": c["start"], "end": c["end"],
            "count": len(c["steps"]), "pids": len(c["pids"]),
            "categories": sorted(c["cats"], key=lambda x:
                                 CAT_ORDER.index(x) if x in CAT_ORDER else 99),
            "cat_counts": c["cats"],
            "top_actions": sorted(c["actions"].items(),
                                  key=lambda kv: -kv[1])[:4],
            "destinations": sorted(c["dests"].items(),
                                   key=lambda kv: -kv[1])[:4],
            "severity": c["severity"], "span": span,
            "links": c["links"],
        })
    # сортировка: сначала разнообразные и критичные — в них есть история
    out.sort(key=lambda c: (-c["span"], -c["severity"], -c["count"]))
    strong = by_link.get("ancestry", 0) + by_link.get("socket", 0)
    steps_of = []
    if want_steps and want_steps in chains:
        steps_of = chains[want_steps]["steps"]
    # индекс «событие -> цепочка»: по нему переход состояния показывает,
    # частью какой истории он был, и туда можно перейти
    index_of = {}
    if want_index:
        titles = {c["id"]: c["title"] for c in out}
        for key, c in chains.items():
            t = titles.get(key, key)
            for e in c["steps"]:
                eid = e.get("event_id")
                if eid:
                    index_of[eid] = {"id": key, "title": t}
    return {"chains": out, "total": len(out), "linked": linked,
            "steps_of": steps_of, "index_of": index_of,
            "events": len(ev), "by_link": by_link,
            "strength": LINK_STRENGTH,
            "strong_pct": strong * 100 // max(1, len(ev)),
            "covered_pct": sum(v for v in by_link.values()) * 100 // max(1, len(ev))}


def detail(eventsdb, chain_id: str, limit: int = 4000, statedb=None) -> dict:
    """Шаги одной цепочки — ПОЛНЫМИ строками событий.

    Собирается тем же build(), что и список: разная логика связывания в
    списке и в разборе уже приводила к тому, что по клику показывалось
    пусто. Одна функция — один результат.
    """
    if eventsdb is None:
        return {"id": chain_id, "steps": [], "count": 0,
                "error": "no event database"}
    d = build(eventsdb, limit=limit, min_len=1, statedb=statedb,
              want_steps=chain_id)
    return {"id": chain_id, "steps": d.get("steps_of", []),
            "count": len(d.get("steps_of", [])), "error": ""}
