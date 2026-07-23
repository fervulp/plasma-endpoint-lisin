"""System: module errors, metrics, settings."""

from PySide6.QtCore import Slot


class SystemApi:
    # A Backend mixin: the slots are registered in metaObject on
    # inheritance Backend(QObject, ...) - verified.

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
        from agent.collect import metrics
        return metrics.system_metrics(self.sampler.series)

    @Slot(result="QVariant")
    def resourceUsage(self):
        from agent.collect import metrics
        return metrics.resource_usage()

    # -------- settings --------
    @Slot(result="QVariant")
    def getSettings(self):
        from agent.core import config
        return config.load()

    @Slot(str, str)
    def setSetting(self, key, value):
        from agent.core import config
        config.set_(key, value)

    # -------- SQL search over the state --------
