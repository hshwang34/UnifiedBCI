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
one file per segment, and the filter state the worker uses resets at each one.

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

## Why `evaluation.json` is byte-identical

The app stores the worker's record without re-encoding, and the worker puts nothing
time- or machine-dependent into it (timings go to `result.meta.json`). Two exports of
the same result have the same `evaluation.json` bytes; two runs of the same
evaluation (same recording, configuration and seed, same worker build) do too, which is
what `result.meta.json`'s `reproductionOf` link records.
