"""Экспертиза и конвейеры: каталог, CRUD правил, граф, запуск и тесты правил."""
import json
import threading
from pathlib import Path

import yaml
from PySide6.QtCore import Slot

from agent.pipeline import EXPERTISE


class ExpertiseApi:
    # Миксин Backend: слоты регистрируются в metaObject при
    # наследовании Backend(QObject, ...) — проверено.

    @Slot(result="QVariant")
    def pipelinesInfo(self):
        return self.pipe.pipelines_info()

    @Slot(str, result="QVariant")
    def pipelineGraph(self, name):
        return self.pipe.graph(name)

    @Slot(str, result="QVariant")
    def pipelineFlows(self, name):
        # конвейер как список потоков (витрина вместо графа)
        return self.pipe.flows(name)

    @Slot(str, result="QVariant")
    def pipelineGraphDraft(self, name):
        return self.pipe.graph_draft(name)

    @Slot(str, str, result="QVariant")
    def nodePeek(self, pipe, node_id):
        # последнее выполнение узла: что пришло / что ушло
        p = self.pipe.peek.get((pipe, node_id), {})
        import json as _j
        def fmt_rows(rows):
            if not rows:
                return ""
            return "\n".join(_j.dumps(r, ensure_ascii=False) for r in rows[:100])
        return {
            "in_text": p.get("in_text") or "",
            "in_rows": fmt_rows(p.get("in_rows")),
            "out_text": p.get("out_text") or "",
            "out_rows": fmt_rows(p.get("out_rows")),
            "error": p.get("error") or "",
            "has": bool(p),
        }

    @Slot(str, str)
    def savePipeline(self, name, graph_json):
        g = json.loads(graph_json)
        self.pipe.save_graph(name, g["nodes"], g["edges"])
        self._emit_pipe()

    @Slot(str, str)
    def savePipelineDraft(self, name, graph_json):
        g = json.loads(graph_json)
        self.pipe.save_draft(name, g["nodes"], g["edges"])

    @Slot(str, str)
    def savePipelineLayout(self, name, graph_json):
        """Сохранить ТОЛЬКО координаты узлов рабочего конвейера.

        Перетаскивание — оформление, а не изменение конвейера: связи и
        привязки не меняются. Поэтому раскладка пишется сразу в рабочий
        файл, без черновика и без «применить конфигурацию» — иначе, чтобы
        просто разложить узлы поудобнее, пришлось бы входить в режим правки.
        """
        g = json.loads(graph_json)
        pos = {n["id"]: (n.get("x", 0), n.get("y", 0))
               for n in g.get("nodes", [])}
        self.pipe.save_layout(name, pos)

    @Slot(str)
    def applyPipeline(self, name):
        self.pipe.apply_draft(name)
        self._emit_pipe()

    @Slot(str)
    def discardPipelineDraft(self, name):
        self.pipe.discard_draft(name)
        self._emit_pipe()

    # -------- детали процесса (EDR-обзор) --------
    @Slot(str)
    def createPipeline(self, title):
        self.pipe.create_pipeline(title)
        self._emit_pipe()

    @Slot(str)
    def runPipeline(self, name):
        def go():
            self.pipe.run_pipeline(name)
            self.stateReady.emit(self.db.snapshot())
            self._emit_pipe()
        threading.Thread(target=go, daemon=True).start()

    @Slot(str, bool)
    def setInputEnabled(self, ref, enabled):
        self.pipe.set_enabled(ref, enabled)
        self._emit_pipe()

    # -------- AI-помощник --------
    @Slot(result="QVariant")
    def expertiseDirs(self):
        return self.pipe.expertise_dirs()

    @Slot(str, result="QVariant")
    def expertiseElements(self, dirpath):
        return self.pipe.expertise_elements(dirpath)

    @Slot(str, result="QVariant")
    def expertiseParsed(self, rel):
        return self.pipe.parsed(rel)

    @Slot(str, result="QVariant")
    def expertiseCatalog(self, category):
        return self.pipe.expertise_catalog(category)

    @Slot(str, result="QVariant")
    def expertiseRefs(self, category):
        return sorted(self.pipe.objects.get(category, {}).keys())

    @Slot(str, result=str)
    def deleteExpertiseDir(self, dirpath):
        import shutil as _sh
        p = (EXPERTISE / dirpath).resolve()
        if (not p.is_relative_to(EXPERTISE) or p == EXPERTISE
                or p.name == "pipelines" or dirpath.strip() in ("", "fedora")):
            return "this folder cannot be deleted"
        if not p.is_dir():
            return "no such folder"
        _sh.rmtree(p)
        self.pipe.reload()
        self._emit_pipe()
        return ""

    @Slot(str, str, result=str)
    def createExpertiseDir(self, parent, name):
        name = name.strip().replace(" ", "_").strip("/.")
        if not name:
            return "empty name"
        p = (EXPERTISE / parent / name).resolve()
        if not p.is_relative_to(EXPERTISE):
            return "invalid path"
        p.mkdir(parents=True, exist_ok=True)
        return ""

    @Slot(str, str, str, result=str)
    def createExpertise(self, dirpath, category, name):
        from agent.pipeline import TEMPLATES
        if category not in TEMPLATES:
            return "unknown category"
        name = name.strip().replace(" ", "_")
        if not name:
            return "empty name"
        p = (EXPERTISE / dirpath / f"{name}.yaml").resolve()
        if not p.is_relative_to(EXPERTISE):
            return "invalid path"
        if p.exists():
            return "file already exists"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(TEMPLATES[category].format(
            n=p.stem, id=self.pipe.next_id(category)))
        self.pipe.reload()
        return ""

    @Slot(str, str, result=str)
    def exportExpertise(self, rel, dest_url):
        src = (EXPERTISE / rel).resolve()
        if not src.is_relative_to(EXPERTISE) or not src.exists():
            return "no such file"
        dest = Path(QUrl(dest_url).toLocalFile() or dest_url)
        try:
            dest.write_text(src.read_text())
            return ""
        except OSError as e:
            return str(e)

    @Slot(str, str, result=str)
    def importExpertise(self, dirpath, src_url):
        src = Path(QUrl(src_url).toLocalFile() or src_url)
        try:
            text = src.read_text()
            yaml.safe_load(text)
        except Exception as e:
            return f"error: {e}"
        dest = (EXPERTISE / dirpath / src.name).resolve()
        if not dest.is_relative_to(EXPERTISE):
            return "invalid path"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
        self.pipe.reload()
        return ""

    @Slot(str, result=str)
    def readExpertise(self, rel):
        p = (EXPERTISE / rel).resolve()
        if not p.is_relative_to(EXPERTISE) or p.suffix != ".yaml":
            return ""
        try:
            return p.read_text()
        except OSError:
            return ""

    @Slot(str, str, result=str)
    def saveExpertise(self, rel, text):
        p = (EXPERTISE / rel).resolve()
        if not p.is_relative_to(EXPERTISE) or p.suffix != ".yaml":
            return "invalid path"
        try:
            yaml.safe_load(text)
        except Exception as e:
            return f"YAML error: {e}"
        p.write_text(text)
        self.pipe.reload()
        self._emit_pipe()
        return ""

    # -------- правки БД состояния --------

    # -------- запуск и тесты правила прямо из UI --------
    @Slot(str, str, result="QVariant")
    def ruleRun(self, ref, sample):
        """«Выполнить сейчас»: прогнать правило на живом входе (или на
        вставленном образце) и вернуть получившиеся строки."""
        from agent import ruletest
        try:
            return ruletest.run_now(self.pipe, ref, sample or "")
        except Exception as e:
            return {"error": str(e)}

    @Slot(str, result="QVariant")
    def ruleTests(self, ref):
        """Прогнать секцию tests: внутри правила (приём из R-Vision)."""
        from agent import ruletest
        try:
            return ruletest.run_tests(self.pipe, ref)
        except Exception as e:
            return {"error": str(e), "tests": []}

    @Slot(str, result="QVariant")
    def ruleInput(self, ref):
        """Какая точка входа подключена к правилу (для подсказки в UI)."""
        from agent import ruletest
        try:
            return ruletest.input_for(self.pipe, ref)
        except Exception:
            return {}
