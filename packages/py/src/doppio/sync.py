"""Delta-sync client for the Python SDK (delta-poll transport)."""

from __future__ import annotations

import json
import time
import urllib.request
import urllib.error
from typing import Any, Callable, Dict, List, Optional

from .types import DoppioOptions, ExposureEvent, FlagDefinition


def normalize_server_flag(raw: Any) -> Optional[FlagDefinition]:
    if not isinstance(raw, dict):
        return None
    key = raw.get("key")
    if not isinstance(key, str) or not key:
        return None
    if raw.get("deleted") is True:
        return None
    enabled = raw.get("enabled", True)
    if not isinstance(enabled, bool):
        enabled = True
    fd = FlagDefinition(key=key, enabled=enabled)
    rp = raw.get("rollout_percentage", raw.get("rolloutPercentage"))
    if isinstance(rp, (int, float)):
        fd.rollout_percentage = min(100, max(0, int(rp)))
    if isinstance(raw.get("variations"), list):
        fd.variations = [FlagDefinition and __import__("doppio.types", fromlist=["Variation"]).Variation.from_mapping(v) for v in raw["variations"]]  # type: ignore
    dv = raw.get("default_variation", raw.get("defaultVariation"))
    if isinstance(dv, (int, float)):
        fd.default_variation = int(dv)
    return fd


class SyncClient:
    def __init__(self, options: DoppioOptions) -> None:
        self.options = options
        self.flags_by_key: Dict[str, FlagDefinition] = {}
        self.flags_listeners: List[Callable[[List[FlagDefinition]], None]] = []
        self.status_listeners: List[Callable[[dict], None]] = []
        self.error_listeners: List[Callable[[Exception], None]] = []
        self.pending: List[ExposureEvent] = []
        self.last_seq: Optional[int] = None
        self.attempts = 0
        self.status = {"kind": "idle", "transport": None, "attempts": 0, "lastSeq": None, "lastError": None, "lastAt": None}
        self.started = False
        self.stopping = False
        self.flushes = 0
        self.flush_errors = 0

    def _base(self) -> str:
        return (self.options.endpoint or "").rstrip("/")

    def _request(self, url: str, method: str = "GET", data: Any = None, headers: Optional[dict] = None) -> Any:
        h = {"Accept": "application/json"}
        if self.options.client_key:
            h["Authorization"] = f"Bearer {self.options.client_key}"
        if headers:
            h.update(headers)
        body = None
        if data is not None:
            body = json.dumps(data).encode("utf-8")
            h["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=body, headers=h, method=method)
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode("utf-8")

    def current_flags(self) -> List[FlagDefinition]:
        return list(self.flags_by_key.values())

    def get_flags(self) -> List[FlagDefinition]:
        return self.current_flags()

    def notify_flags(self) -> None:
        flags = self.current_flags()
        for cb in list(self.flags_listeners):
            try:
                cb(flags)
            except Exception:
                pass
        if getattr(self, "on_flags", None):
            try:
                self.on_flags(flags)
            except Exception:
                pass

    def apply_snapshot(self, msg: Any) -> List[FlagDefinition]:
        raw = msg.get("flags", []) if isinstance(msg, dict) else []
        self.flags_by_key.clear()
        for item in raw:
            nf = normalize_server_flag(item)
            if nf is not None:
                self.flags_by_key[nf.key] = nf
        seq = msg.get("seq") if isinstance(msg, dict) else None
        if isinstance(seq, int):
            self.last_seq = seq if self.last_seq is None else max(self.last_seq, seq)
            self.status["lastSeq"] = self.last_seq
        self.notify_flags()
        return self.current_flags()

    def apply_delta(self, msg: Any) -> List[FlagDefinition]:
        changes = msg.get("changes", []) if isinstance(msg, dict) else []
        for change in changes:
            if not isinstance(change, dict):
                continue
            key = change.get("key")
            if not isinstance(key, str):
                continue
            if change.get("deleted") is True:
                self.flags_by_key.pop(key, None)
                continue
            nf = normalize_server_flag(change)
            if nf is not None:
                self.flags_by_key[nf.key] = nf
        seq = msg.get("seq") if isinstance(msg, dict) else None
        if isinstance(seq, int):
            self.last_seq = seq if self.last_seq is None else max(self.last_seq, seq)
            self.status["lastSeq"] = self.last_seq
        self.notify_flags()
        return self.current_flags()

    def handle_message(self, msg: Any) -> Optional[List[FlagDefinition]]:
        if not isinstance(msg, dict):
            return None
        kind = msg.get("type")
        if kind == "snapshot":
            return self.apply_snapshot(msg)
        if kind == "delta":
            return self.apply_delta(msg)
        if kind == "ack":
            seq = msg.get("seq")
            if isinstance(seq, int) and (self.last_seq is None or seq > self.last_seq):
                self.last_seq = seq
                self.status["lastSeq"] = seq
            return None
        return None

    def on_flags_change(self, cb):
        self.flags_listeners.append(cb)
        return lambda: self.flags_listeners.remove(cb) if cb in self.flags_listeners else None

    def on_status_change(self, cb):
        self.status_listeners.append(cb)
        return lambda: self.status_listeners.remove(cb) if cb in self.status_listeners else None

    def on_error(self, cb):
        self.error_listeners.append(cb)
        return lambda: self.error_listeners.remove(cb) if cb in self.error_listeners else None

    def queue_exposure(self, exposure: ExposureEvent) -> None:
        self.pending.append(exposure)

    def get_pending_exposures(self) -> List[ExposureEvent]:
        return list(self.pending)

    def make_idempotency_key(self, exposure: ExposureEvent) -> str:
        provided = getattr(exposure, "idempotency_key", None)
        if isinstance(provided, str) and provided:
            return provided
        unit = exposure.unit_id or "anonymous"
        ts = exposure.timestamp if isinstance(exposure.timestamp, int) else int(time.time() * 1000)
        variation = exposure.variation or ""
        return f"{unit}:{exposure.flag_key}:{ts}:{variation}"

    def flush(self) -> dict:
        if not self.pending or not self.options.endpoint:
            return {"sent": 0, "kept": len(self.pending), "ok": True}
        events = []
        for e in self.pending:
            events.append({
                "flag_key": e.flag_key,
                "user_id": e.unit_id,
                "enabled": e.enabled,
                "variation": e.variation,
                "bucket": e.bucket,
                "timestamp": e.timestamp,
                "reason": e.reason,
                "idempotency_key": self.make_idempotency_key(e),
            })
        try:
            url = self._base() + "/collect"
            self._request(url, method="POST", data={"events": events})
            self.pending = []
            self.flushes += 1
            return {"sent": len(events), "kept": 0, "ok": True}
        except Exception as exc:
            self.flush_errors += 1
            for cb in list(self.error_listeners):
                try:
                    cb(exc)
                except Exception:
                    pass
            return {"sent": 0, "kept": len(self.pending), "ok": False}

    def get_status(self) -> dict:
        return dict(self.status)

    def fetch_once(self) -> List[FlagDefinition]:
        if not self.options.endpoint:
            return self.current_flags()
        try:
            seq = self.last_seq if self.last_seq is not None else 0
            url = self._base() + f"/sync/updates/{seq}"
            raw = self._request(url)
            data = json.loads(raw)
            res = self.handle_message(data)
            return res if res is not None else self.current_flags()
        except Exception as exc:
            for cb in list(self.error_listeners):
                try:
                    cb(exc)
                except Exception:
                    pass
            return self.current_flags()

    def start(self) -> None:
        if self.started:
            return
        self.started = True
        self.stopping = False
        if not self.options.endpoint or self.options.sync_strategy == "manual":
            self.status = {**self.status, "kind": "idle", "transport": None, "lastAt": int(time.time() * 1000)}
            return
        strategy = self.options.sync_strategy or "auto"
        transports = []
        if strategy in ("websocket", "auto"):
            transports.append("websocket")
        if strategy in ("sse", "auto"):
            transports.append("sse")
        if strategy in ("delta-poll", "auto"):
            transports.append("delta-poll")
        for t in transports:
            try:
                if t == "websocket":
                    self._start_websocket()
                    return
                if t == "sse":
                    self._start_sse()
                    return
                if t == "delta-poll":
                    self.status = {**self.status, "kind": "connected", "transport": "delta-poll", "lastAt": int(time.time() * 1000)}
                    self._poll()
                    return
            except Exception as exc:
                for cb in list(self.error_listeners):
                    try:
                        cb(exc)
                    except Exception:
                        pass
                continue
        self.status = {**self.status, "kind": "degraded", "transport": None, "lastAt": int(time.time() * 1000)}

    def _start_sse(self) -> None:
        import threading
        url = self._base() + "/sync/stream"
        def run():
            try:
                req = urllib.request.Request(url, headers={"Accept": "text/event-stream"})
                if self.options.client_key:
                    req.add_header("Authorization", f"Bearer {self.options.client_key}")
                with urllib.request.urlopen(req, timeout=60) as resp:
                    self.status = {**self.status, "kind": "connected", "transport": "sse", "lastAt": int(time.time() * 1000)}
                    buf = ""
                    while not self.stopping:
                        chunk = resp.read(1024)
                        if not chunk:
                            break
                        buf += chunk.decode("utf-8", errors="replace")
                        while "\n\n" in buf:
                            raw, buf = buf.split("\n\n", 1)
                            data = ""
                            for line in raw.splitlines():
                                if line.startswith("data:"):
                                    data += line[5:].strip()
                            if data and data != "heartbeat":
                                try:
                                    self.handle_message(json.loads(data))
                                except Exception:
                                    pass
            except Exception as exc:
                for cb in list(self.error_listeners):
                    try:
                        cb(exc)
                    except Exception:
                        pass
        t = threading.Thread(target=run, daemon=True)
        t.start()
        self._sse_thread = t

    def _start_websocket(self) -> None:
        try:
            import websocket as _ws  # type: ignore
        except Exception:
            raise RuntimeError("websocket-client not installed")
        url = self._base().replace("http", "ws", 1) + "/sync/ws"
        def on_message(ws, message):
            try:
                self.handle_message(json.loads(message))
            except Exception:
                pass
        ws = _ws.WebSocketApp(url, on_message=on_message)
        import threading
        t = threading.Thread(target=ws.run_forever, daemon=True)
        t.start()
        self._ws = ws
        self._ws_thread = t
        self.status = {**self.status, "kind": "connected", "transport": "websocket", "lastAt": int(time.time() * 1000)}

    def _poll(self) -> None:
        if self.stopping:
            return
        try:
            seq = self.last_seq if self.last_seq is not None else 0
            url = self._base() + f"/sync/updates/{seq}"
            raw = self._request(url)
            data = json.loads(raw)
            self.handle_message(data)
            self.status = {**self.status, "kind": "connected", "transport": "delta-poll", "lastAt": int(time.time() * 1000)}
            self.attempts = 0
        except Exception as exc:
            self.status = {**self.status, "kind": "degraded", "transport": "delta-poll", "lastAt": int(time.time() * 1000)}
            self.attempts += 1
            for cb in list(self.error_listeners):
                try:
                    cb(exc)
                except Exception:
                    pass
        delay = self.options.poll_interval if self.options.poll_interval and self.options.poll_interval > 0 else 250
        import threading
        t = threading.Timer(max(0.25, delay / 1000.0), self._poll)
        t.daemon = True
        t.start()
        self._timer = t

    def stop(self) -> None:
        self.stopping = True
        self.started = False
        t = getattr(self, "_timer", None)
        if t is not None:
            try:
                t.cancel()
            except Exception:
                pass
        self.status = {**self.status, "kind": "stopped", "lastAt": int(time.time() * 1000)}


def create_sync_client(options: DoppioOptions) -> Optional[SyncClient]:
    if not options.endpoint:
        return None
    return SyncClient(options)