"""Worker entry point: reads requests from stdin, answers on the protocol stream,
logs to stderr.

The macOS app owns this process. Startup splits the original stdout into a private
protocol stream and points fd 1 at stderr, so no library can print into the framing.
A reader thread keeps `ping` / `cancel` / `shutdown` responsive while a fit runs on
the main thread; a watchdog exits when the parent dies; a broken pipe exits quietly.
"""

from __future__ import annotations

import os

# BLAS thread pools are pinned before numpy is imported: one thread keeps reductions
# bit-reproducible run to run (the brief requires byte-identical repeat evaluations)
# and keeps a fit from competing with acquisition. The Swift launcher sets the same
# variables; `setdefault` keeps either side from overriding an explicit operator choice.
WORKER_THREADS = os.environ.get("BCI_WORKER_THREADS", "1")
for _var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
             "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ.setdefault(_var, WORKER_THREADS)

import hashlib  # noqa: E402
import io  # noqa: E402
import json  # noqa: E402
import platform  # noqa: E402
import queue  # noqa: E402
import sys  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import traceback  # noqa: E402
from dataclasses import dataclass  # noqa: E402
from importlib import metadata  # noqa: E402
from typing import Any, Callable, Iterable, TextIO  # noqa: E402

import numpy as np  # noqa: E402
import threadpoolctl  # noqa: E402

from . import pipeline, project_io  # noqa: E402
from .protocol import (  # noqa: E402
    CONTROL_METHODS,
    PROTOCOL_VERSION,
    Cancelled,
    ProtocolError,
    Request,
    error,
    event,
    response,
)

# Belt and braces for pools that were created before the environment variables took
# effect (e.g. when this module is imported by tests after numpy).
_THREADPOOL_LIMIT = threadpoolctl.threadpool_limits(limits=int(WORKER_THREADS))


@dataclass(frozen=True)
class Context:
    """What a handler may do besides return a result."""

    emit: Callable[[str, Any], None]
    check_cancelled: Callable[[], None]


Handler = Callable[[Request, Context], Any]


def _versions() -> dict[str, str]:
    out = {"python": platform.python_version()}
    for dist in ("numpy", "scipy", "scikit-learn", "brainflow"):
        try:
            out[dist] = metadata.version(dist)
        except metadata.PackageNotFoundError:
            out[dist] = "missing"
    return out


def hello() -> dict[str, Any]:
    return {
        "protocol": PROTOCOL_VERSION,
        "pid": os.getpid(),
        "versions": _versions(),
        "methods": sorted(set(HANDLERS) | CONTROL_METHODS),
    }


def handle_fit_evaluate_synthetic(req: Request, ctx: Context) -> dict[str, Any]:
    p = req.params
    sfreq = float(p.get("sfreq", 125.0))
    segments = pipeline.make_synthetic_runs(
        n_runs=int(p.get("n_runs", 4)),
        trials_per_run=int(p.get("trials_per_run", 20)),
        n_channels=int(p.get("n_channels", 16)),
        sfreq=sfreq,
        effect=float(p.get("effect", 0.6)),
        seed=int(p.get("seed", 0)),
    )
    t0 = time.monotonic()
    record = pipeline.fit_evaluate(
        segments,
        window=(float(p.get("window_offset_s", 0.5)), float(p.get("window_length_s", 2.0))),
        seed=int(p.get("seed", 0)),
        n_components=int(p.get("csp_components", 4)),
        progress=lambda d: ctx.emit("progress", d),
        check_cancelled=ctx.check_cancelled,
    )
    n_trials = sum(len(s.events) for s in segments)
    record["data_source"] = {
        "kind": "synthetic",
        "warning": "Synthetic data exercises the pipeline only; it is not evidence about any participant.",
        "n_runs": len(segments),
        "n_trials": n_trials,
        "n_channels": int(segments[0].data.shape[0]),
    }
    # Timing is reported as an event, never in `result`: the client stores `result`
    # byte-for-byte as evaluation.json and repeat evaluations must be identical.
    ctx.emit("done", {"elapsed_seconds": time.monotonic() - t0})
    return record


def _fit_progress(ctx: Context, d: dict[str, Any]) -> None:
    """`pipeline.fit_evaluate` reports per fold and per holdout fit; the protocol
    labels each with its stage so the app can show `fit:<model>:fold k/n` / `holdout`."""
    stage = "holdout" if d.get("holdout") else "fit"
    ctx.emit("progress", {"stage": stage, **{k: v for k, v in d.items() if k != "holdout"}})


def _config_hash(block: dict[str, Any]) -> str:
    """SHA-256 over canonical JSON (sorted keys, compact) of what determines the fit."""
    canonical = json.dumps(
        {k: block[k] for k in ("configuration", "expectedChannelIDs", "expectedSampleRateHz", "dependencyVersions")},
        sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def handle_fit_evaluate_project(req: Request, ctx: Context) -> dict[str, Any]:
    """Evaluate the reference recipe and the baseline over one recording of a project.

    params: project_dir, recording_id, window {offset_s, length_s}, labels {left, right}
    (event labels to use as class 0 / class 1), seed, csp_components, optional
    split_manifest (re-score a frozen split), optional fitted_arrays_path (where to
    write the `.npz`; the caller supplies a path inside its own staging directory so
    binary never crosses the pipe).

    result: {"evaluation": <record, stored verbatim as evaluation.json>,
             "pipeline": <PipelineRecord fields the worker determines>,
             "fitted_arrays_file": path or null}. Timing goes to the `done` event only.
    """
    p = req.params
    try:
        project_dir = str(p["project_dir"])
        recording_id = str(p["recording_id"])
    except KeyError as exc:
        raise ProtocolError("bad_request", f"missing parameter {exc}", req.id) from exc
    window_p = p.get("window", {})
    window = (float(window_p.get("offset_s", 0.5)), float(window_p.get("length_s", 3.5)))
    labels_p = p.get("labels", {})
    left, right = str(labels_p.get("left", "cue_left_fist")), str(labels_p.get("right", "cue_right_fist"))
    seed = int(p.get("seed", 0))
    n_components = int(p.get("csp_components", 4))
    bandpass = pipeline.BandpassSpec()
    holdout_fraction = float(p.get("holdout_fraction", 0.25))
    split_manifest = p.get("split_manifest")
    arrays_path = p.get("fitted_arrays_path")

    t0 = time.monotonic()
    ctx.emit("progress", {"stage": "loading"})
    try:
        rec = project_io.open_recording(project_dir, recording_id)
        segments = project_io.load_segments(rec, {left: 0, right: 1})
    except project_io.IntegrityError as exc:
        raise ProtocolError("integrity", str(exc), req.id) from exc
    except project_io.ProjectError as exc:
        raise ProtocolError("bad_request", str(exc), req.id) from exc
    ctx.check_cancelled()
    t_loaded = time.monotonic()

    record, fitted = pipeline.fit_evaluate(
        segments,
        window=window,
        seed=seed,
        n_components=n_components,
        bandpass=bandpass,
        holdout_fraction=holdout_fraction,
        split_manifest=split_manifest,
        progress=lambda d: _fit_progress(ctx, d),
        check_cancelled=ctx.check_cancelled,
        return_fitted=True,
    )
    record["data_source"] = project_io.data_source(rec, segments)
    t_fit = time.monotonic()

    arrays_file = None
    if arrays_path:
        # Reference model at the top level (the recipe the pipeline record names); the
        # baseline's arrays prefixed `baseline__` so one file carries both fits.
        arrays = dict(fitted["reference_csp_rlda"])
        arrays.update({f"baseline__{k}": v for k, v in fitted["baseline_logvar_rlda"].items()})
        with open(arrays_path, "wb") as f:
            np.savez(f, **arrays)
        arrays_file = str(arrays_path)

    configuration = {
        "window_offset_s": repr(window[0]),
        "window_length_s": repr(window[1]),
        "bandpass_low_hz": repr(bandpass.low_hz),
        "bandpass_high_hz": repr(bandpass.high_hz),
        "bandpass_order": str(bandpass.order),
        "csp_components": str(n_components),
        "holdout_fraction": repr(holdout_fraction),
        "label_left": left,
        "label_right": right,
        "baseline": "logvar_rlda_v1",
    }
    pipeline_block: dict[str, Any] = {
        "recipe": "csp_rlda_v1",
        "configuration": configuration,
        "expectedChannelIDs": rec.channel_ids,
        "expectedSampleRateHz": rec.sfreq,
        "preprocessingStatePolicy": "reset_on_segment_start",
        "splitManifest": json.dumps(record["split_manifest"], sort_keys=True, separators=(",", ":")),
        "dependencyVersions": _versions(),
        "seed": seed,
    }
    pipeline_block["configHash"] = _config_hash(pipeline_block)

    ctx.emit("done", {
        "elapsed_seconds": t_fit - t0,
        "stages": {"loading": t_loaded - t0, "fit": t_fit - t_loaded},
    })
    return {"evaluation": record, "pipeline": pipeline_block, "fitted_arrays_file": arrays_file}


HANDLERS: dict[str, Handler] = {
    "fit_evaluate_synthetic": handle_fit_evaluate_synthetic,
    "fit_evaluate_project": handle_fit_evaluate_project,
}


def open_protocol_stream() -> TextIO:
    """Duplicate fd 1 for protocol output, then point fd 1 at stderr so stray prints
    from any library (and `sys.stdout`) land in the log, never in the framing."""
    proto = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8", newline="\n")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return proto


class Server:
    """One worker session: a reader thread for requests, the calling thread for work."""

    def __init__(self, stdin: Iterable[str], write: Callable[[str], None], watch_parent: bool = False):
        self._stdin = stdin
        self._write_fn = write
        self._watch_parent = watch_parent
        self._lock = threading.Lock()
        self._queue: queue.Queue[Request | None] = queue.Queue()
        # Request id -> cancel flag, for every request that is queued or running. Touched by
        # both threads, so every access goes through `_active_lock`.
        self._active: dict[str, threading.Event] = {}
        self._active_lock = threading.Lock()
        self._shutting_down = False
        self._pipe_broken = False

    # -- output ---------------------------------------------------------------

    def write(self, line: str) -> None:
        with self._lock:
            if self._pipe_broken:
                return
            try:
                self._write_fn(line)
            except (BrokenPipeError, ValueError, OSError):
                # The app went away (or closed our stdout). Nothing to report to; stop quietly.
                self._pipe_broken = True
                self._shutting_down = True
                self._cancel_all()
                self._queue.put(None)

    # -- control ---------------------------------------------------------------

    def _cancel_all(self) -> None:
        with self._active_lock:
            flags = list(self._active.values())
        for flag in flags:
            flag.set()

    def _register(self, request_id: str) -> threading.Event | None:
        """Creates the cancel flag for a new request; None if the id is already in flight."""
        with self._active_lock:
            if request_id in self._active:
                return None
            flag = self._active[request_id] = threading.Event()
            return flag

    def _lookup(self, request_id: str) -> threading.Event | None:
        with self._active_lock:
            return self._active.get(request_id)

    def _forget(self, request_id: str) -> None:
        with self._active_lock:
            self._active.pop(request_id, None)

    def _handle_control(self, req: Request) -> None:
        if req.method == "hello":
            self.write(response(req.id, hello()))
        elif req.method == "ping":
            self.write(response(req.id, {"pong": True, "echo": req.params.get("echo"), "t": time.time()}))
        elif req.method == "cancel":
            target = req.params.get("id")
            flag = self._lookup(target) if isinstance(target, str) else None
            if flag is not None:
                flag.set()
            self.write(response(req.id, {"cancelled": flag is not None}))
        elif req.method == "shutdown":
            self._shutting_down = True
            self._cancel_all()
            self.write(response(req.id, {"bye": True}))

    def _read_loop(self) -> None:
        try:
            for raw in self._stdin:
                line = raw.strip()
                if not line:
                    continue
                try:
                    req = Request.parse(line)
                except ProtocolError as exc:
                    self.write(error(exc.request_id, exc.code, exc.message))
                    continue
                if req.method in CONTROL_METHODS:
                    self._handle_control(req)
                elif req.method in HANDLERS:
                    if self._register(req.id) is None:
                        self.write(error(req.id, "bad_request", f"request id {req.id!r} is already in flight"))
                        continue
                    self._queue.put(req)
                else:
                    self.write(error(req.id, "unknown_method", f"no such method: {req.method}"))
                if self._shutting_down:
                    break
        except Exception:  # noqa: BLE001 - a dead stdin is treated like EOF
            print(traceback.format_exc(), file=sys.stderr, flush=True)
        finally:
            # The sentinel must reach the work loop whatever else fails here, or the main
            # thread blocks on `queue.get()` forever.
            try:
                self._shutting_down = True
                self._cancel_all()
            except Exception:  # noqa: BLE001 - log, never let the sentinel be skipped
                print(traceback.format_exc(), file=sys.stderr, flush=True)
            finally:
                self._queue.put(None)

    def _watch_parent_loop(self) -> None:
        parent = os.getppid()
        while True:
            time.sleep(0.5)
            if os.getppid() != parent:
                os._exit(0)

    # -- work ------------------------------------------------------------------

    def _run(self, req: Request) -> None:
        flag = self._lookup(req.id)
        if flag is None:
            return

        def check_cancelled() -> None:
            if flag.is_set():
                raise Cancelled()

        ctx = Context(emit=lambda name, data: self.write(event(name, data, req.id)), check_cancelled=check_cancelled)
        try:
            check_cancelled()
            result = HANDLERS[req.method](req, ctx)
            check_cancelled()
            self.write(response(req.id, result))
        except Cancelled:
            self.write(error(req.id, "cancelled", "request was cancelled"))
        except ProtocolError as exc:
            self.write(error(req.id, exc.code, exc.message))
        except Exception as exc:  # noqa: BLE001 - surface anything to the app, keep serving
            print(traceback.format_exc(), file=sys.stderr, flush=True)
            self.write(error(req.id, "internal", f"{type(exc).__name__}: {exc}"))
        finally:
            self._forget(req.id)

    def serve(self) -> int:
        self.write(event("ready", hello()))
        threading.Thread(target=self._read_loop, name="worker-reader", daemon=True).start()
        if self._watch_parent:
            threading.Thread(target=self._watch_parent_loop, name="worker-parent-watchdog", daemon=True).start()
        while True:
            req = self._queue.get()
            if req is None:
                return 0
            self._run(req)


def serve(stdin: Iterable[str] | None = None, write: Callable[[str], None] | None = None,
          watch_parent: bool = False) -> int:
    """Run one session. Tests pass an iterable of lines and a sink; the real entry
    point passes the process stdin and the private protocol stream."""
    if write is None:
        proto = open_protocol_stream()

        def write(line: str) -> None:
            proto.write(line + "\n")
            proto.flush()

    if stdin is None:
        stdin = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace")
    return Server(stdin, write, watch_parent=watch_parent).serve()


def main() -> None:
    status = serve(watch_parent=True)
    # The reader thread may still be blocked in stdin.readline(); a normal interpreter
    # shutdown would wait on it and complain about locks. Flush and leave.
    sys.stderr.flush()
    os._exit(status)


if __name__ == "__main__":
    main()
