"""Storage adapters for the Python SDK."""

from __future__ import annotations

import json
import os
from typing import Any, List, Optional

from .types import FlagDefinition


class MemoryStorage:
    def __init__(self) -> None:
        self._flags: Optional[List[FlagDefinition]] = None

    def load_flags(self) -> Optional[List[FlagDefinition]]:
        return self._flags

    def save_flags(self, flags: List[FlagDefinition]) -> None:
        self._flags = list(flags)


class FileStorage:
    def __init__(self, path: str) -> None:
        self.path = path

    def load_flags(self) -> Optional[List[FlagDefinition]]:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                raw = json.load(f)
            return [FlagDefinition.from_mapping(x) for x in raw]
        except (OSError, ValueError, TypeError):
            return None

    def save_flags(self, flags: List[FlagDefinition]) -> None:
        try:
            os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
            with open(self.path, "w", encoding="utf-8") as f:
                json.dump([f.to_mapping() for f in flags], f)
        except OSError:
            pass


def create_storage(prefer_file: bool = False, path: Optional[str] = None) -> Any:
    if prefer_file and path:
        return FileStorage(path)
    return MemoryStorage()