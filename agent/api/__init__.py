"""Слоты Backend, разложенные по разделам (миксины)."""
from .state import StateApi
from .events import EventsApi
from .dashboard import DashboardApi
from .expertise import ExpertiseApi
from .system import SystemApi

__all__ = ["StateApi", "EventsApi", "DashboardApi", "ExpertiseApi", "SystemApi"]
