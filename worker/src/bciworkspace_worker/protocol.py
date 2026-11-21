"""Versioned line-delimited JSON protocol between the macOS app and this worker.

Framing: one UTF-8 JSON object per line on stdin (requests) and the protocol stream
(responses and events). The protocol stream is a private duplicate of the original
stdout taken at startup; fd 1 itself is redirected to stderr so library chatter
(MNE "Computing rank…", BLAS, warnings) can never corrupt the framing. stderr is
free-form logging. Binary sample data is never sent in-band: requests reference
immutable chunk files inside the project directory instead. The one bounded exception is
`live_push` (below): one drained chunk of a live stream, at most `MAX_PUSH_SAMPLES`.

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
  the worker never repairs or skips it), `internal`; for the model methods below also
  `invalid_model` (the fitted arrays fail validation, or their SHA-256 no longer matches:
  "model file changed since it was frozen") and `channel_mismatch` (channel ids, their
  order, or the sample rate differ from the model's; nothing is reordered or resampled).

Frozen models, replay and live inference (brief 006). A model is named by
`model: {"arrays_path", "sha256", "which": "reference" | "baseline"}`: the pipeline's
`fitted.npz`, loaded with `allow_pickle=False` and validated (`pipeline.validate_model_arrays`)
on every use. Scores are the LDA decision value `s` (positive favours `lda_classes[1]`);
`confidence` is max(sigma(s), 1 - sigma(s)) = sigma(|s|): the shrinkage-LDA posterior of the
predicted class, always >= 0.5 and not calibrated (no calibration step is fitted, and the
LDA's Gaussian equal-covariance assumption sets its scale). The UI calls it "model confidence",
never a probability of intent. The worker never abstains or hides anything:
abstention, staleness and feedback are the app's policy, so every prediction carries what
the policy needs (validity + detail, score, confidence, class, window, eligibility).
A prediction is `{segment, kind: "hop" | "cue_locked", window_start, window_stop (segment
sample indices, half-open), validity: "valid" | "insufficient_window" | "invalid_input",
detail, score, confidence, predicted_class, trial_id, feedback_eligible, gap}`.

- `validate_model` — params `{model, n_channels?}`; result the model summary
  (feature_kind, n_channels, n_features, filter_warmup_samples, lda_classes, sha256).
- `replay_recording` — params `{project_dir, recording_id, model, expected_channel_ids,
  expected_sample_rate_hz, window: {offset_s, length_s}, warmup_samples?, hop_samples? (16),
  labels: {left, right}, cue_length_s? (imagery span when a trial has no `cue_end` event),
  abstain_threshold? (0.6, for decisions in the report), chunkings? ([1, 7, 13, 125,
  "random"]), seed?, predictions_path}`. Streams the recording's verified chunks through the
  model at each chunking beside the offline reference and writes one JSON line per streamed
  prediction (first chunking, with the offline validity and score) to `predictions_path`, a
  path in the app's staging directory: predictions never cross the pipe. Result: `passed`,
  `windows_compared`, `tolerances`, `max_deviation` per quantity, `boundary_windows`,
  `first_valid_window_stop` per segment, one parity report per chunking, `model`, `window`,
  `predictions_file`, `n_predictions`. Progress: `loading`, `replay`; cancellation is checked
  every 256 pushes or windows, in the offline reference pass and in every streaming pass.
- `live_open` — params `{model, channel_ids, sample_rate_hz, expected_channel_ids,
  expected_sample_rate_hz, window, warmup_samples?, hop_samples?}`; result `{session, model,
  window: {offset_samples, length_samples, hop_samples, warmup_samples}}`. At most
  `MAX_LIVE_SESSIONS` open per worker; sessions die with the worker process.
- `live_push` — params `{session, segment, first_sample, n_samples, samples, gaps?, cues?}`.
  `samples` is base64 of the chunk's channel rows only, little-endian float64, row-major
  (n_channels x n_samples), n_samples <= `MAX_PUSH_SAMPLES` (512; a drained chunk is ~6). A new
  `segment` value resets filter state and window buffer and must start at `first_sample` 0;
  otherwise `first_sample` must continue the segment exactly, so a lost push is a
  `bad_request`, never silently spliced. `gaps` `[{after_sample, evidence}]` are the chunk's
  detected gaps; `cues` `[{sample, trial_id, end_sample?}]` register cues as soon as their
  sample is known (each list at most `MAX_PUSH_EVENTS`). Refused with `bad_request`: non-finite
  samples (they would poison the filter state), a `segment` lower than the current one
  (segments only increase), a cue `sample` before 0 or more than one window length +
  `MAX_PUSH_SAMPLES` past the push's last sample, an `end_sample` before its cue or more than
  `MAX_CUE_SPAN_SAMPLES` after it, and more than `MAX_OPEN_CUES` (64) cues open at once. A
  rejected push leaves the session unchanged. Result `{session, segment, n_samples, predictions, worker_compute_nanos}`, one
  prediction per window due in the chunk (every validity included).
- `live_close` — params `{session}`; result `{closed: true, predictions}` (cue-locked windows
  the segment ended before, as `window_exceeds_segment`).

These methods are additive and listed by `hello`, so PROTOCOL_VERSION stays 1: an older
client never calls them and nothing it already uses changed shape.

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
