"""Backend slots, split by section (mixins).

The module names here deliberately repeat the names of the analysis modules
(state, dashboard): this is the API layer over them, and the import is always
relative to this package.
"""
from .dashboard import DashboardApi
from .events import EventsApi
from .expertise import ExpertiseApi
from .state import StateApi
from .system import SystemApi

__all__ = ["StateApi", "EventsApi", "DashboardApi", "ExpertiseApi", "SystemApi"]
