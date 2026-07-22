"""Служебное: ошибки модулей, метрики, настройки, AI-помощник и чаты."""

from PySide6.QtCore import Slot


class SystemApi:
    # Миксин Backend: слоты регистрируются в metaObject при
    # наследовании Backend(QObject, ...) — проверено.

    @Slot(result="QVariant")
    def errorsLog(self):
        self._collect_errors()
        return list(self.errors_log)

    @Slot()
    def clearErrors(self):
        self.errors_log.clear()
        self._err_seen.clear()

    @Slot(result="QVariant")
    def systemMetrics(self):
        from agent import metrics
        return metrics.system_metrics(self.sampler.series)

    @Slot(result="QVariant")
    def resourceUsage(self):
        from agent import metrics
        return metrics.resource_usage()

    # -------- настройки --------
    @Slot(result="QVariant")
    def getSettings(self):
        from agent import config
        return config.load()

    @Slot(str, str)
    def setSetting(self, key, value):
        from agent import config
        config.set_(key, value)

    # -------- SQL-поиск по состоянию --------
