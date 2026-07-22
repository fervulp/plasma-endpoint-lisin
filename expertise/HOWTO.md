# Как написать экспертизу LiSin

Всё, что нужно знать, чтобы добавить новый источник данных, — здесь.
Заглядывать в код приложения не требуется. Проверить написанное можно
кнопками **Run** и **Tests** в разделе «Экспертиза».

Объект экспертизы — один YAML-файл. Категорию определяет поле `type`,
а не каталог. Каталог — просто папка (`fedora/` — наши, рядом можно
завести свою).

---

## Поток данных

```
точка входа  →  нормализация  →  [обогащение]  →  [фильтр]  →  точка выхода
  (bash)         (python)          (python)      (условия)     (таблица/события)
```

Узлы соединяются в конвейере (`expertise/pipelines/*.yaml`).

---

## 1. Точка входа — `type: input`

Просто команда shell. Её stdout попадёт в нормализацию.

```yaml
name: myservice
id: LS-I-99
type: input
version: 1.0.0
title: My service state
command: systemctl show myservice --property=ActiveState,MainPID
interval: 60          # секунд
enabled: true
```

`command` — строка (выполняется как `bash -c`). Пишите так, чтобы команда
**никогда не падала**: добавляйте `2>/dev/null` и `|| true`, иначе узел
будет краснеть на машинах, где утилиты нет.

---

## 2. Нормализация — `type: normalization_rule`

Главный объект. Внутри — обычный Python.

**Контракт:**

* обязана быть функция `normalize(text) -> list[dict]`;
* `text` — stdout точки входа;
* **колонки таблицы = ключи возвращённых dict** (порядок — из первой строки).
  Объявлять колонки нигде не нужно;
* таблица и ключ задаются в **точке выхода**, не здесь;
* `re` и `json` уже импортированы; любой модуль stdlib можно импортировать
  внутри функции;
* строку можно отбросить, просто не добавив её в список.

```yaml
name: myservice
id: LS-N-99
type: normalization_rule
version: 1.0.0
title: My service
code: |
  def normalize(text):
      rows = []
      for line in text.splitlines():
          if "=" not in line:
              continue
          k, _, v = line.partition("=")
          rows.append({"item": k.strip(), "value": v.strip()})
      return rows

tests:
  - name: две строки
    input: |
      ActiveState=active
      MainPID=1234
    expect:
      rows: 2
      contains: {item: ActiveState, value: active}
```

### Тесты правила

Лежат рядом с правилом, запускаются кнопкой **Tests**. Виды ожиданий:

| ключ | смысл |
|---|---|
| `rows: N` | ровно N строк |
| `min_rows: N` | не меньше N |
| `contains: {поле: значение}` | среди строк есть такая |
| `row0: {поле: значение}` | проверка строки по индексу (`row0`, `row1`, …) |

Кнопка **Run** прогоняет правило на **живом** входе (выполнит команду точки
входа) и покажет разобранные строки и колонки — удобно, когда формат вывода
утилиты заранее неизвестен.

---

## 3. Точка выхода

Для состояния (таблица-снимок) — `type: statedb`:

```yaml
name: db_myservice
id: LS-O-myservice
type: statedb
version: 1.0.0
title: My service
table: myservice
key: [item]           # по этим полям строки обновляются, а не дублируются
icon: view-list-details
```

Для событий (поток) — `type: events`. Таблица и ключ там берутся из
**таксономии** (`expertise/taxonomy/events.yaml`), поэтому в самом выходе
их указывать не нужно.

---

## 4. События: пишите под таксономию

Если правило готовит **события**, возвращайте поля из таксономии
(`expertise/taxonomy/events.yaml`, 88 полей, ECS-подобные имена). Минимум:

```python
{
  "ts": "2026-07-19T15:33:06Z",      # ISO-8601 UTC
  "event_id": "уникально",           # ключ дедупликации
  "event_category": "process",       # process|network|file|authentication|...
  "event_type": "start",
  "event_action": "process_started",
  "event_outcome": "success",
  "event_severity": 30,              # 0..100
  "event_module": "мой_источник",
  "message": "человекочитаемо",
}
```

Поле `not_normalized` заполняйте именами полей исходной записи, которые вы
**не** разобрали — сразу видно, что ещё можно вытащить.

Дедупликация: `event_id` уникален, вставка идёт `INSERT OR IGNORE`. Поэтому
точка входа может собирать **с перекрытием окна** — дублей не будет.

---

## 5. Обогащение — `type: enrichment`

Добавляет колонки к уже разобранным строкам.

```yaml
name: my_enrich
id: LS-E-99
type: enrichment
version: 1.0.0
title: My enrichment
code: |
  def enrich(rows):
      for r in rows:
          r["extra"] = r.get("name", "").upper()
      return rows
```

Плагин может читать БД состояния (`~/.local/share/lisin/state.db`,
только чтение) — так сделан `fedora/enrich/app_deps`.

---

## 6. Фильтр — `type: filter`

Либо условия (проходит строка, где истинны **все**):

```yaml
conditions:
  - field: event_category
    op: eq            # eq|ne|contains|not_contains|regex|in|not_in
    value: process
```

Либо таблица шаблонов шума — строка, совпавшая с **любым** шаблоном,
отбрасывается (`action: drop`) или помечается (`action: tag`):

```yaml
templates:
  - name: спам-логи
    event_provider: kwin_wayland
    match: "TypeError"       # регулярное выражение по message
    action: drop
```

---

## 7. Подключение в конвейер

`expertise/pipelines/state.yaml` (состояние) или `events.yaml` (события):

```yaml
nodes:
  - {id: in_myservice,  kind: input,     ref: fedora/inputs/myservice,    x: 40,  y: 4000}
  - {id: no_myservice,  kind: normalize, ref: fedora/normalize/myservice, x: 360, y: 4000}
  - {id: out_myservice, kind: output,    ref: fedora/outputs/myservice,   x: 680, y: 4000}
edges:
  - [in_myservice, no_myservice]
  - [no_myservice, out_myservice]
```

`ref` — путь от корня экспертизы **без** `.yaml`.

---

## Порядок работы

1. Создайте элемент кнопкой **Element…** — получите готовый шаблон с
   комментариями и заготовкой теста.
2. Напишите `command`, нажмите **Run** — увидите сырой вход и что из него
   разобралось.
3. Правьте `normalize`, пока колонки не станут нужными.
4. Зафиксируйте результат в `tests:` и нажмите **Tests**.
5. Добавьте узлы в конвейер.

## Доверие

Код правила **исполняется** (как и `command` точки входа). Импортируйте
чужую экспертизу только из проверенных источников.
