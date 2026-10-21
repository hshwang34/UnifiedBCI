"""Versioned line-delimited JSON protocol between the macOS app and this worker.

Framing: one UTF-8 JSON object per line on stdin (requests) and the protocol stream
(responses and events). The protocol stream is a private duplicate of the original
stdout taken at startup; fd 1 itself is redirected to stderr so library chatter
(MNE "Computing rank…", BLAS, warnings) can never corrupt the framing. stderr is
free-form logging. Binary sample data is never sent in-band: requests reference
immutable chunk files inside the project directory instead.

Request   {"v": 1, "id": "<client id>", "method": "<name>", "params": {...}}
Response  {"v": 1, "id": "<client id>", "ok": true,  "result": {...}}
          {"v": 1, "id": "<client id>", "ok": false, "error": {"code": "...", "message": "..."}}
Event     {"v": 1, "event": "<name>", "id": "<request id or null>", "data": {...}}

Rules the client relies on:

- **Every request gets exactly one response carrying the request's `id`**, including
  requests that fail to parse. The worker extracts `id` best-effort before validating
  anything else, so a wrong `v`, a bad `params` type, or an unknown method is answered
  under the caller's own id and never leaves the caller waiting. Only a line that is
  not a JSON object, or has no string `id`, is answered with `"id": null`.
- Control methods (`hello`, `ping`, `cancel`, `shutdown`) are answered immediately by
  the reader thread even while a long request runs on the work thread. Responses
  are therefore matched by `id`, never by arrival order.
- `cancel` — params `{"id": "<request id>"}`. Result `{"cancelled": true}` if that
  request was queued or running and has now been asked to stop, `false` otherwise.
  The cancelled request itself answers with error code `cancelled` as soon as the
  handler reaches a checkpoint (between cross-validation folds for fits). A queued
  request that is cancelled before it starts also answers `cancelled`.
- `shutdown` — answers `{"bye": true}`, cancels anything running or queued, and the
  process exits once the current handler reaches a checkpoint.
- Error codes: `bad_json`, `bad_request`, `unsupported_version`, `unknown_method`,
  `cancelled`, `integrity` (a project chunk's bytes do not match its manifest hash;
  the worker never repairs or skips it), `internal`.

The Swift side mirrors these shapes in WorkerClient.swift; bump PROTOCOL_VERSION in
both places together.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

PROTOCOL_VERSION = 1

CONTROL_METHODS = frozenset({"hello", "ping", "cancel", "shutdown"})


class ProtocolError(Exception):
    """A request the worker refuses. `request_id` is the best-effort id of the
    offending request so the error can still be delivered to its caller."""

    def __init__(self, code: str, message: str, request_id: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.request_id = request_id


class Cancelled(Exception):
    """Raised inside a handler when its request has been cancelled."""


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
        # Recover the id first so every later rejection can still be routed to its caller.
        raw_id = obj.get("id")
        rid = raw_id if isinstance(raw_id, str) else None
        if obj.get("v") != PROTOCOL_VERSION:
            raise ProtocolError(
                "unsupported_version",
                f"worker speaks protocol v{PROTOCOL_VERSION}, got {obj.get('v')!r}",
                rid,
            )
        method = obj.get("method")
        if rid is None or not isinstance(method, str):
            raise ProtocolError("bad_request", "request needs string 'id' and 'method'", rid)
        params = obj.get("params", {})
        if not isinstance(params, dict):
            raise ProtocolError("bad_request", "'params' must be an object", rid)
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
