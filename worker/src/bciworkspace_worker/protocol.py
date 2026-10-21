"""Versioned line-delimited JSON protocol between the macOS app and this worker.

Framing: one UTF-8 JSON object per line on stdin (requests) and stdout (responses
and events). stderr is free-form logging. Binary sample data is never sent in-band:
requests reference immutable chunk files inside the project directory instead.

Request   {"v": 1, "id": "<client id>", "method": "<name>", "params": {...}}
Response  {"v": 1, "id": "<client id>", "ok": true,  "result": {...}}
          {"v": 1, "id": "<client id>", "ok": false, "error": {"code": "...", "message": "..."}}
Event     {"v": 1, "event": "<name>", "id": "<request id or null>", "data": {...}}

The Swift side mirrors these shapes in WorkerClient.swift; bump PROTOCOL_VERSION in
both places together.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

PROTOCOL_VERSION = 1


class ProtocolError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class Request:
    id: str
    method: str
    params: dict[str, Any] = field(default_factory=dict)

    @staticmethod
    def parse(line: str) -> "Request":
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ProtocolError("bad_json", f"could not parse request: {exc}") from exc
        if not isinstance(obj, dict):
            raise ProtocolError("bad_request", "request must be a JSON object")
        if obj.get("v") != PROTOCOL_VERSION:
            raise ProtocolError(
                "unsupported_version",
                f"worker speaks protocol v{PROTOCOL_VERSION}, got {obj.get('v')!r}",
            )
        rid = obj.get("id")
        method = obj.get("method")
        if not isinstance(rid, str) or not isinstance(method, str):
            raise ProtocolError("bad_request", "request needs string 'id' and 'method'")
        params = obj.get("params", {})
        if not isinstance(params, dict):
            raise ProtocolError("bad_request", "'params' must be an object")
        return Request(id=rid, method=method, params=params)


def response(request_id: str, result: Any) -> str:
    return json.dumps(
        {"v": PROTOCOL_VERSION, "id": request_id, "ok": True, "result": result},
        separators=(",", ":"),
        allow_nan=False,
    )


def error(request_id: str | None, code: str, message: str) -> str:
    return json.dumps(
        {
            "v": PROTOCOL_VERSION,
            "id": request_id,
            "ok": False,
            "error": {"code": code, "message": message},
        },
        separators=(",", ":"),
    )


def event(name: str, data: Any, request_id: str | None = None) -> str:
    return json.dumps(
        {"v": PROTOCOL_VERSION, "event": name, "id": request_id, "data": data},
        separators=(",", ":"),
        allow_nan=False,
    )
