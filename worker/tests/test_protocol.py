import io
import json

import pytest

from bciworkspace_worker import main as worker_main
from bciworkspace_worker.protocol import PROTOCOL_VERSION, ProtocolError, Request


def test_parse_rejects_wrong_version():
    with pytest.raises(ProtocolError) as exc:
        Request.parse(json.dumps({"v": 99, "id": "1", "method": "ping"}))
    assert exc.value.code == "unsupported_version"


def test_parse_rejects_non_object():
    with pytest.raises(ProtocolError) as exc:
        Request.parse("[1,2,3]")
    assert exc.value.code == "bad_request"


def run_serve(lines):
    out = []
    stdin = io.StringIO("".join(json.dumps(l) + "\n" for l in lines))
    worker_main.serve(stdin=stdin, write=out.append)
    return [json.loads(l) for l in out]


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
    assert "fit_evaluate_synthetic" in msgs[0]["data"]["methods"]
    assert msgs[1] == {"v": 1, "id": "a", "ok": True, "result": msgs[1]["result"]}
    assert msgs[1]["result"]["echo"] == "hi"
    assert msgs[2]["ok"] is False and msgs[2]["error"]["code"] == "unknown_method"
    assert msgs[3]["ok"] is True and msgs[3]["result"] == {"bye": True}


def test_serve_survives_garbage_line():
    out = []
    stdin = io.StringIO("not json\n" + json.dumps({"v": 1, "id": "z", "method": "shutdown"}) + "\n")
    worker_main.serve(stdin=stdin, write=out.append)
    msgs = [json.loads(l) for l in out]
    assert msgs[1]["ok"] is False and msgs[1]["error"]["code"] == "bad_json"
    assert msgs[2]["ok"] is True
