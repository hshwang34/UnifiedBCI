"""Worker entry point: reads requests from stdin, answers on stdout, logs to stderr.

The macOS app owns this process. It must never block on anything except stdin,
must never print non-protocol text to stdout, and should exit cleanly on EOF or a
`shutdown` request so the app can restart it after a failure.
"""

from __future__ import annotations

import os
import platform
import sys
import time
import traceback
from importlib import metadata
from typing import Any, Callable

from . import pipeline
from .protocol import PROTOCOL_VERSION, ProtocolError, Request, error, event, response

Handler = Callable[[Request, Callable[[str, Any], None]], Any]


def _versions() -> dict[str, str]:
    out = {"python": platform.python_version()}
    for dist in ("numpy", "scipy", "scikit-learn", "mne", "brainflow"):
        try:
            out[dist] = metadata.version(dist)
        except metadata.PackageNotFoundError:
            out[dist] = "missing"
    return out


def handle_hello(req: Request, emit) -> dict[str, Any]:
    return {
        "protocol": PROTOCOL_VERSION,
        "pid": os.getpid(),
        "versions": _versions(),
        "methods": sorted(HANDLERS),
    }


def handle_ping(req: Request, emit) -> dict[str, Any]:
    return {"pong": True, "echo": req.params.get("echo"), "t": time.time()}


def handle_fit_evaluate_synthetic(req: Request, emit) -> dict[str, Any]:
    p = req.params
    sfreq = float(p.get("sfreq", 125.0))
    X, y, groups = pipeline.make_synthetic_mi(
        n_runs=int(p.get("n_runs", 4)),
        trials_per_run=int(p.get("trials_per_run", 20)),
        n_channels=int(p.get("n_channels", 16)),
        sfreq=sfreq,
        effect=float(p.get("effect", 0.6)),
        seed=int(p.get("seed", 0)),
    )
    t0 = time.monotonic()
    record = pipeline.fit_evaluate(
        X, y, groups, sfreq=sfreq,
        seed=int(p.get("seed", 0)),
        n_components=int(p.get("csp_components", 4)),
        progress=lambda d: emit("progress", d),
    )
    record["data_source"] = {
        "kind": "synthetic",
        "warning": "Synthetic data exercises the pipeline only; it is not evidence about any participant.",
        "shape": list(X.shape),
    }
    record["elapsed_seconds"] = time.monotonic() - t0
    return record


def handle_shutdown(req: Request, emit) -> dict[str, Any]:
    return {"bye": True}


HANDLERS: dict[str, Handler] = {
    "hello": handle_hello,
    "ping": handle_ping,
    "fit_evaluate_synthetic": handle_fit_evaluate_synthetic,
    "shutdown": handle_shutdown,
}


def _write(line: str) -> None:
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def serve(stdin=None, write=_write) -> int:
    stdin = stdin or sys.stdin
    write(event("ready", handle_hello(Request(id="", method="hello"), None)))
    for raw in stdin:
        line = raw.strip()
        if not line:
            continue
        req_id: str | None = None
        try:
            req = Request.parse(line)
            req_id = req.id
            handler = HANDLERS.get(req.method)
            if handler is None:
                raise ProtocolError("unknown_method", f"no such method: {req.method}")
            result = handler(req, lambda name, data: write(event(name, data, req.id)))
            write(response(req.id, result))
            if req.method == "shutdown":
                return 0
        except ProtocolError as exc:
            write(error(req_id, exc.code, exc.message))
        except Exception as exc:  # noqa: BLE001 - surface anything to the app, keep serving
            print(traceback.format_exc(), file=sys.stderr, flush=True)
            write(error(req_id, "internal", f"{type(exc).__name__}: {exc}"))
    return 0


def main() -> None:
    sys.exit(serve())


if __name__ == "__main__":
    main()
