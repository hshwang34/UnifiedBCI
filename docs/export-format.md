# Export format

`ProjectStore.export(result:to:)` writes one folder per result. Everything in it is
readable without the app: flat binary, JSON, JSON lines, and one `.npz` of plain arrays.

```
<name>/
  recording.json      {"manifest": <RecordingManifest>, "samples": <header, below>}
  segment-<runID>.f64 one per stream segment: the samples, float64 little-endian, no header
  events.jsonl        one EventRecord per line, exactly as stored in the project
  channels.json       {"sampleRateHz", "reference", "montage", "channels": [ChannelSpec]}
  pipeline.json       PipelineRecord (configuration, expected channels/rate, seed, hashes)
  model.npz           fitted arrays (reference model at top level, baseline as baseline__*)
  evaluation.json     the worker's evaluation record, byte-identical to the stored one
  result.meta.json    ResultMeta: wall clock, durations, worker versions, reproduction link
  ATTRIBUTION.md      dataset source, license and citations, built from the manifest
  runs/<runID>.plan.json            cued recordings only: each run's RunPlan, as stored
  protocols/<uuid>/protocol.json    cued recordings only: each protocol version a plan names
```

## Samples

`recording.json` carries a `samples` header:

```json
"samples": {
  "dtype": "float64",
  "byteOrder": "little",
  "layout": "row-major: channelCount rows × sampleCount columns, channel i = manifest.channels[i]",
  "channelCount": 16,
  "sampleRateHz": 160,
  "files": [
    {"file": "segment-S001R04.f64", "segment": 0, "runID": "S001R04", "sessionID": null,
     "sampleCount": 20000, "sha256": "…"}
  ]
}
```

Each `segment-<runID>.f64` is every chunk of that segment concatenated in sample order,
with **only the channel rows** (counter and timestamp rows a live recording stores are
left out), in the order of `manifest.channels`. Values are in the unit each channel
declares (`channels[i].unit`, `uV` for the bundled example). Segments are never joined:
one file per segment, and the filter state the worker uses resets at each one. When two
segments would share a name (a reconnect inside one run, or run ids that differ only in
characters replaced by `_` or in case), each of them gets its segment index appended,
`segment-<runID>-<index>.f64`; the `files[].file` entries are always the names to open.
An export whose chunks do not tile a segment contiguously from sample 0 is refused.
The folder is written as a `.tmp-<name>` sibling and renamed into place, so it is
complete or absent.

Read it with numpy alone (`python -I` ignores every environment variable, so this is a
clean-room check; `np.fromfile` needs the explicit `<f8` dtype):

```sh
python -I -c "import json,sys,numpy as np;d=sys.argv[1];h=json.load(open(d+'/recording.json'))['samples'];x={f['runID']:np.fromfile(d+'/'+f['file'],'<f8').reshape(h['channelCount'],f['sampleCount']) for f in h['files']};print({k:v.shape for k,v in x.items()})" /path/to/export
```

The model arrays are a plain `.npz` with no pickled objects:

```sh
python -I -c "import sys,numpy as np;z=np.load(sys.argv[1]+'/model.npz',allow_pickle=False);print({k:z[k].shape for k in z.files})" /path/to/export
```

`worker/src/bciworkspace_worker/pipeline.py:predict_from_arrays` is the reference reader
for `model.npz`; the test suite checks it reproduces the sklearn objects' predictions.

## Events

`events.jsonl` lines are `EventRecord`s. A cue's sample position is
`sampleAssociation.segment` / `sampleAssociation.sampleIndex`, an index into that
segment's `.f64` file. `timingUncertaintyNanos` is `null` unless it was measured.

## Run plans and protocols (cued recordings)

A recording made with the cued protocol (brief 005) has one run plan per run. The export
copies each plan and **exactly** the protocol versions those plans name, byte for byte
from the project, at the same relative paths as in the project (`runs/` sits under the
recording there). Each file is read once with a size cap, validated, and the validated
bytes are what is written. `recording.json` then has a `runPlans` header; a recording
without plan files has no `runPlans` key at all, so its export reads as before.

```json
"runPlans": {
  "plans": [
    {"file": "runs/R1.plan.json", "runID": "R1", "runIndex": 0, "sessionID": "…",
     "protocolID": "…", "protocolVersion": 2, "protocolContentHash": "…", "seed": 41,
     "sha256": "…"}
  ],
  "protocols": [
    {"file": "protocols/<uuid>/protocol.json", "protocolID": "…",
     "name": "Left vs right hand (Graz-style)", "version": 2, "contentHash": "…", "sha256": "…"}
  ],
  "unreadable": 0,
  "unverified": []
}
```

- `sha256` is over the exported file's bytes; `contentHash` / `protocolContentHash` is the
  protocol's own hash over its timing and class fields (`docs/data-contracts.md`), so a
  reader can check that each plan was made from the protocol beside it.
- A plan is exported only when the protocol version it names is stored, readable, valid and
  has the same content hash. Valid plans that fail this are listed by run id in
  `unverified` and not copied; plan files that can't be read or fail validation are counted
  in `unreadable`. Neither stops the export.
- Two plans whose run ids differ only in case (possible on a case-sensitive volume) refuse
  the export instead of overwriting each other.

To reproduce a run's order and rests from the folder alone, feed the protocol and the
plan's seed to the worker's mirror of the schedule (it imports nothing but the standard
library; run from `worker/src`):

```sh
python -I -c "import json,sys;sys.path.insert(0,'.');from bciworkspace_worker.protocol_schedule import schedule;d,r=sys.argv[1:];p=json.load(open(f'{d}/runs/{r}.plan.json'));q=json.load(open(f'{d}/protocols/{p[\"protocolID\"]}/protocol.json'));t=q['timing'];print(schedule([c['label'] for c in q['classes']],q['trialsPerClass'],t['fixationMs'],t['cueMs'],t['restMinMs'],t['restMaxMs'],p['seed'],r)==p['trials'])" /path/to/export R1
```

## Why `evaluation.json` is byte-identical

The app stores the worker's record without re-encoding, and the worker puts nothing
time- or machine-dependent into it (timings go to `result.meta.json`). Two exports of
the same result have the same `evaluation.json` bytes; two runs of the same
evaluation (same recording, configuration and seed, same worker build) do too, which is
what `result.meta.json`'s `reproductionOf` link records.
