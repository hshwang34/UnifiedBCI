import io
import json
import os
import queue
import subprocess
import sys
import threading
import time

import pytest

from bciworkspace_worker import main as worker_main
from bciworkspace_worker.protocol import PROTOCOL_VERSION, ProtocolError, Request


# --- parsing ----------------------------------------------------------------------------------


def test_parse_rejects_wrong_version_but_keeps_id():
    with pytest.raises(ProtocolError) as exc:
        Request.parse(json.dumps({"v": 99, "id": "1", "method": "ping"}))
    assert exc.value.code == "unsupported_version"
    assert exc.value.request_id == "1"


def test_parse_rejects_non_object_without_id():
    with pytest.raises(ProtocolError) as exc:
        Request.parse("[1,2,3]")
    assert exc.value.code == "bad_request" and exc.value.request_id is None


def test_parse_bad_params_keeps_id():
    with pytest.raises(ProtocolError) as exc:
        Request.parse(json.dumps({"v": 1, "id": "p", "method": "ping", "params": [1]}))
    assert exc.value.code == "bad_request" and exc.value.request_id == "p"


# --- serve() with an in-memory transport ------------------------------------------------------


class LineFeed:
    """A blocking stdin stand-in: the test pushes lines while the server runs."""

    def __init__(self):
        self.q: queue.Queue[str | None] = queue.Queue()

    def push(self, obj):
        self.q.put(json.dumps(obj) + "\n")

    def close(self):
        self.q.put(None)

    def __iter__(self):
        while (line := self.q.get()) is not None:
            yield line


class Sink:
    def __init__(self):
        self.lines: list[dict] = []
        self.cv = threading.Condition()

    def __call__(self, line: str):
        with self.cv:
            self.lines.append(json.loads(line))
            self.cv.notify_all()

    def wait_for(self, pred, timeout=60.0):
        deadline = time.monotonic() + timeout
        with self.cv:
            while True:
                hits = [m for m in self.lines if pred(m)]
                if hits:
                    return hits[0]
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f"timed out waiting; have {self.lines}")
                self.cv.wait(remaining)

    def response(self, rid, timeout=60.0):
        return self.wait_for(lambda m: m.get("id") == rid and "ok" in m, timeout)


def run_serve(lines):
    out = []
    stdin = io.StringIO("".join(json.dumps(l) + "\n" for l in lines))
    worker_main.serve(stdin=stdin, write=out.append)
    return [json.loads(l) for l in out]


def by_id(msgs, rid):
    return next(m for m in msgs if m.get("id") == rid and "ok" in m)


def test_serve_emits_ready_then_answers_and_shuts_down():
    msgs = run_serve(
        [
            {"v": PROTOCOL_VERSION, "id": "a", "method": "ping", "params": {"echo": "hi"}},
            {"v": PROTOCOL_VERSION, "id": "b", "method": "nope"},
            {"v": PROTOCOL_VERSION, "id": "c", "method": "shutdown"},
        ]
    )
    assert msgs[0]["event"] == "ready"
    assert msgs[0]["data"]["protocol"] == PROTOCOL_VERSION
    assert {"fit_evaluate_synthetic", "cancel", "ping", "shutdown"} <= set(msgs[0]["data"]["methods"])
    assert "mne" not in msgs[0]["data"]["versions"], "MNE is a dev dependency only"
    assert by_id(msgs, "a")["result"]["echo"] == "hi"
    assert by_id(msgs, "b")["ok"] is False and by_id(msgs, "b")["error"]["code"] == "unknown_method"
    assert by_id(msgs, "c")["result"] == {"bye": True}


def test_serve_survives_garbage_line():
    msgs = run_serve_raw("not json\n" + json.dumps({"v": 1, "id": "z", "method": "shutdown"}) + "\n")
    assert msgs[1]["ok"] is False and msgs[1]["error"]["code"] == "bad_json" and msgs[1]["id"] is None
    assert by_id(msgs, "z")["ok"] is True


def run_serve_raw(text):
    out = []
    worker_main.serve(stdin=io.StringIO(text), write=out.append)
    return [json.loads(l) for l in out]


def test_wrong_version_request_is_answered_under_its_own_id():
    """The defect: a v99 request used to be answered with id null, which the client
    drops, leaving the caller waiting forever."""
    msgs = run_serve([
        {"v": 99, "id": "old", "method": "ping"},
        {"v": 1, "id": "s", "method": "shutdown"},
    ])
    err = by_id(msgs, "old")
    assert err["ok"] is False and err["error"]["code"] == "unsupported_version"


def test_eof_without_shutdown_exits_cleanly():
    msgs = run_serve([{"v": 1, "id": "a", "method": "ping"}])
    assert by_id(msgs, "a")["ok"] is True


def test_ping_and_cancel_are_answered_while_a_fit_runs():
    feed, sink = LineFeed(), Sink()
    t = threading.Thread(target=worker_main.serve, kwargs={"stdin": feed, "write": sink}, daemon=True)
    t.start()
    sink.wait_for(lambda m: m.get("event") == "ready")
    feed.push({"v": 1, "id": "fit", "method": "fit_evaluate_synthetic",
               "params": {"n_runs": 6, "trials_per_run": 20, "n_channels": 16, "seed": 1}})
    sink.wait_for(lambda m: m.get("event") == "progress" and m.get("id") == "fit")
    feed.push({"v": 1, "id": "p", "method": "ping"})
    pong = sink.response("p", timeout=5.0)
    assert pong["result"]["pong"] is True
    assert not any(m.get("id") == "fit" and "ok" in m for m in sink.lines), "ping must not wait for the fit"

    feed.push({"v": 1, "id": "c", "method": "cancel", "params": {"id": "fit"}})
    assert sink.response("c", timeout=5.0)["result"] == {"cancelled": True}
    fit = sink.response("fit")
    assert fit["ok"] is False and fit["error"]["code"] == "cancelled"

    feed.push({"v": 1, "id": "c2", "method": "cancel", "params": {"id": "fit"}})
    assert sink.response("c2", timeout=5.0)["result"] == {"cancelled": False}
    feed.push({"v": 1, "id": "s", "method": "shutdown"})
    assert sink.response("s", timeout=5.0)["result"] == {"bye": True}
    t.join(timeout=30)
    assert not t.is_alive()


def test_shutdown_during_fit_cancels_it_and_exits():
    feed, sink = LineFeed(), Sink()
    t = threading.Thread(target=worker_main.serve, kwargs={"stdin": feed, "write": sink}, daemon=True)
    t.start()
    sink.wait_for(lambda m: m.get("event") == "ready")
    feed.push({"v": 1, "id": "fit", "method": "fit_evaluate_synthetic", "params": {"n_runs": 6, "trials_per_run": 20, "seed": 2}})
    feed.push({"v": 1, "id": "queued", "method": "fit_evaluate_synthetic", "params": {"n_runs": 4, "trials_per_run": 8}})
    sink.wait_for(lambda m: m.get("event") == "progress")
    feed.push({"v": 1, "id": "s", "method": "shutdown"})
    assert sink.response("s", timeout=5.0)["result"] == {"bye": True}
    t.join(timeout=60)
    assert not t.is_alive()
    assert sink.response("fit")["error"]["code"] == "cancelled"
    assert sink.response("queued")["error"]["code"] == "cancelled"


def test_duplicate_in_flight_id_is_rejected():
    msgs = run_serve([
        {"v": 1, "id": "x", "method": "fit_evaluate_synthetic", "params": {"n_runs": 4, "trials_per_run": 6, "n_channels": 4}},
        {"v": 1, "id": "x", "method": "fit_evaluate_synthetic"},
        {"v": 1, "id": "s", "method": "shutdown"},
    ])
    codes = [m["error"]["code"] for m in msgs if m.get("id") == "x" and m.get("ok") is False]
    assert "bad_request" in codes


def test_broken_pipe_on_write_stops_quietly():
    calls = {"n": 0}

    def write(line):
        calls["n"] += 1
        if calls["n"] > 1:
            raise BrokenPipeError()

    feed = LineFeed()
    feed.push({"v": 1, "id": "a", "method": "ping"})
    feed.push({"v": 1, "id": "b", "method": "ping"})
    t = threading.Thread(target=worker_main.serve, kwargs={"stdin": feed, "write": write}, daemon=True)
    t.start()
    t.join(timeout=10)
    assert not t.is_alive()


def test_handler_result_is_byte_identical_across_repeats():
    """The client stores `result` verbatim as evaluation.json, so nothing run-dependent
    (timing, pids) may live in it; timing travels as a `done` event instead."""
    from bciworkspace_worker.protocol import Request
    events = []
    ctx = worker_main.Context(emit=lambda name, data: events.append((name, data)), check_cancelled=lambda: None)
    req = Request(id="r", method="fit_evaluate_synthetic", params={"n_runs": 4, "trials_per_run": 6, "n_channels": 4, "seed": 5})
    a = json.dumps(worker_main.handle_fit_evaluate_synthetic(req, ctx))
    b = json.dumps(worker_main.handle_fit_evaluate_synthetic(req, ctx))
    assert a == b
    assert "elapsed_seconds" not in a
    assert [e for e in events if e[0] == "done"] and all("elapsed_seconds" in e[1] for e in events if e[0] == "done")


def test_reader_exit_delivers_sentinel_even_if_cancel_all_raises(monkeypatch):
    """Regression: a RuntimeError in the reader's finally (dict changed size during
    iteration) used to skip the sentinel and leave the work loop blocked forever."""
    def boom(self):
        raise RuntimeError("dict changed size during iteration")
    monkeypatch.setattr(worker_main.Server, "_cancel_all", boom)
    feed, sink = LineFeed(), Sink()
    t = threading.Thread(target=worker_main.serve, kwargs={"stdin": feed, "write": sink}, daemon=True)
    t.start()
    sink.wait_for(lambda m: m.get("event") == "ready")
    feed.close()  # EOF
    t.join(timeout=10)
    assert not t.is_alive(), "work loop must exit on EOF even when cancellation bookkeeping fails"


def test_cancel_all_snapshots_active_while_work_thread_pops():
    """Deterministic interleaving: the main thread pops from `_active` while
    `_cancel_all` iterates; with the lock+snapshot this cannot raise."""
    server = worker_main.Server(iter([]), lambda line: None)
    for i in range(50):
        server._register(f"r{i}")
    original = dict.values

    def racing_values(d):
        # Simulate the work thread finishing a request mid-iteration.
        server._forget("r0")
        return original(d)
    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(worker_main.Server, "_cancel_all", lambda self: [f.set() for f in list(racing_values(self._active))])
        server._cancel_all()
    assert server._lookup("r0") is None and server._lookup("r1").is_set()


def test_eof_during_fit_terminates_promptly_stress():
    for i in range(5):
        feed, sink = LineFeed(), Sink()
        t = threading.Thread(target=worker_main.serve, kwargs={"stdin": feed, "write": sink}, daemon=True)
        t.start()
        sink.wait_for(lambda m: m.get("event") == "ready")
        feed.push({"v": 1, "id": "fit", "method": "fit_evaluate_synthetic", "params": {"n_runs": 6, "trials_per_run": 20, "seed": i}})
        sink.wait_for(lambda m: m.get("event") == "progress")
        feed.close()
        t.join(timeout=60)
        assert not t.is_alive(), f"iteration {i}: worker hung after EOF during a fit"
        assert sink.response("fit")["error"]["code"] == "cancelled"


# --- the real process -------------------------------------------------------------------------


def spawn():
    env = dict(os.environ, PYTHONUNBUFFERED="1")
    return subprocess.Popen(
        [sys.executable, "-m", "bciworkspace_worker"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True,
    )


def test_process_keeps_stray_prints_off_the_protocol_stream():
    """fd 1 is redirected to stderr at startup: anything printed by a library (or by
    `print`) must appear on stderr, never between JSON lines."""
    proc = spawn()
    try:
        ready = json.loads(proc.stdout.readline())
        assert ready["event"] == "ready"
        # A fit imports sklearn/scipy and runs BLAS; everything they say goes to stderr.
        req = {"v": 1, "id": "f", "method": "fit_evaluate_synthetic", "params": {"n_runs": 4, "trials_per_run": 6, "n_channels": 4}}
        proc.stdin.write(json.dumps(req) + "\n")
        proc.stdin.flush()
        lines = []
        while not any(m.get("id") == "f" and "ok" in m for m in lines):
            lines.append(json.loads(proc.stdout.readline()))
        proc.stdin.write(json.dumps({"v": 1, "id": "s", "method": "shutdown"}) + "\n")
        proc.stdin.flush()
        out, err = proc.communicate(timeout=120)
        lines += [json.loads(l) for l in out.splitlines() if l.strip()]
        assert all("v" in m for m in lines)
        assert any(m.get("id") == "f" and m.get("ok") for m in lines)
        assert proc.returncode == 0
    finally:
        proc.kill()


def test_process_exits_when_parent_dies():
    """A throwaway parent spawns the worker on *our* stdin pipe (so the worker never
    sees EOF) and then dies; only the getppid watchdog can end the worker."""
    script = r"""
import os, subprocess, sys
p = subprocess.Popen([sys.executable, "-m", "bciworkspace_worker"], stdin=sys.stdin, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
p.stdout.readline()
print(p.pid, flush=True)
os._exit(0)
"""
    parent = subprocess.Popen([sys.executable, "-c", script], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        worker_pid = int(parent.stdout.readline().strip())
        parent.wait(timeout=30)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                os.kill(worker_pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.1)
        os.kill(worker_pid, 9)
        pytest.fail("worker outlived its parent")
    finally:
        parent.stdin.close()


def test_open_protocol_stream_redirects_fd1_to_stderr():
    snippet = (
        "import sys, os\n"
        "from bciworkspace_worker.main import open_protocol_stream\n"
        "proto = open_protocol_stream()\n"
        "print('noise on fd 1')\n"
        "os.write(1, b'raw noise\\n')\n"
        "proto.write('{\"v\":1}\\n'); proto.flush()\n"
    )
    out = subprocess.run([sys.executable, "-c", snippet], capture_output=True, text=True, timeout=60)
    assert out.stdout == '{"v":1}\n'
    assert "noise on fd 1" in out.stderr and "raw noise" in out.stderr
