# Memoir Recorder Audio Sync Specification

## 1. Purpose

This document defines the recorder-side requirements for producing **time-aligned** `system.wav` and `mic.wav` tracks so the Memoir Processor can build a reliable combined transcript.

This specification augments:

- [recorder-processor-interface-spec.md](/Users/acousland/Local%20Workspace/Code/memoir-processor/recorder-processor-interface-spec.md)

The core idea is simple:

- do not ask the Processor to guess sync from transcript text alone
- capture both streams against the same monotonic timeline in the Recorder
- export aligned WAV files when possible
- always emit explicit sync metadata

---

## 2. What Reliable Products Usually Do

Products that combine microphone input and system playback typically rely on:

1. one recorder process owning both streams
2. a shared monotonic clock
3. explicit per-stream offsets
4. drift correction when needed
5. echo control so playback bleed into the mic does not dominate the merge

The Processor can still do cleanup, but the Recorder should be the source of truth for timing.

---

## 3. Design Requirements

### 3.1 Single Recorder Timeline

The Recorder must timestamp both the microphone stream and the system stream against the **same monotonic clock**.

Recommended macOS clock sources:

- `AVAudioTime.hostTime`
- `mach_continuous_time`
- equivalent host-time clock exposed by the capture stack

Do not use wall-clock timestamps for alignment.

### 3.2 Session Zero

The Recorder must define a single session zero point:

- `session_zero_host_time_ns`

This is the earliest first-sample host time across the exported streams.

All per-stream offsets are measured relative to this zero point.

### 3.3 Aligned WAV Export

Preferred behavior:

- export `system.wav` and `mic.wav` already aligned to the same session timeline

That means:

- if one stream starts later, pad it with leading silence so both files share the same `t=0`
- if one stream starts earlier, do not trim it; instead use that earlier first sample as session zero
- if drift is detected and can be corrected safely, apply drift correction before final export

If aligned export is implemented correctly, the Processor can merge transcripts directly using transcript timestamps.

### 3.4 Explicit Metadata Is Still Required

Even if aligned WAV export is used, the Recorder must still emit sync metadata so the Processor can:

- verify alignment
- debug failures
- compensate if aligned export is unavailable in a fallback path

### 3.5 Echo / Bleed Control

Sync alone does not solve mic/system duplication if the microphone captures speaker playback.

Recorder recommendations:

- prefer headphones during recording
- if speakers are used, apply acoustic echo cancellation where technically possible
- mark whether echo cancellation was enabled in metadata

The Processor should treat `System` as authoritative for overlapping playback-derived speech, but the Recorder should minimize bleed at capture time.

---

## 4. Normative Metadata Contract

The Recorder must add a `stream_sync` block to `metadata.json`.

### 4.1 Required Shape

```json
{
  "stream_sync": {
    "schema_version": 1,
    "timeline": "host_time_ns",
    "session_zero_host_time_ns": "7758391023301000",
    "reference_stream": "system",
    "aligned_wav_export": true,
    "drift_corrected": false,
    "estimated_drift_ppm": 0.0,
    "relative_offset_to_system_seconds": 0.128625,
    "sync_confidence": "high",
    "echo_cancellation": {
      "applied": false,
      "mode": "none"
    },
    "streams": {
      "system": {
        "first_sample_host_time_ns": "7758391023301000",
        "start_offset_seconds": 0.0,
        "sample_rate_hz": 16000,
        "duration_frames": 534074,
        "latency_frames": 0
      },
      "mic": {
        "first_sample_host_time_ns": "7758391151926000",
        "start_offset_seconds": 0.128625,
        "sample_rate_hz": 16000,
        "duration_frames": 532579,
        "latency_frames": 256
      }
    }
  }
}
```

### 4.2 Field Rules

`schema_version`

- required
- must equal `1`

`timeline`

- required
- must equal `host_time_ns`

`session_zero_host_time_ns`

- required
- decimal string, not JSON number
- must be the earliest first-sample host time among exported streams

`reference_stream`

- required
- must be `"system"` or `"mic"`
- recommended value: `"system"`

`aligned_wav_export`

- required
- `true` if exported WAVs already share the same session zero
- `false` only if fallback/raw export is used

`drift_corrected`

- required
- `true` if the Recorder actively corrected cross-stream drift before export

`estimated_drift_ppm`

- required
- floating-point number
- `0.0` if no measurable drift was observed

`relative_offset_to_system_seconds`

- required when both streams exist
- signed floating-point number
- defined as:
  - `mic.start_offset_seconds - system.start_offset_seconds`
- positive value means the mic stream starts later than the system stream

`sync_confidence`

- required
- one of:
  - `high`
  - `medium`
  - `low`

`echo_cancellation`

- required
- records whether AEC was active

`streams.system.first_sample_host_time_ns`

- required if `system.wav` exists
- decimal string

`streams.mic.first_sample_host_time_ns`

- required if `mic.wav` exists
- decimal string

`streams.<name>.start_offset_seconds`

- required
- seconds from `session_zero_host_time_ns` to the first sample of that stream
- must be non-negative

`streams.<name>.sample_rate_hz`

- required
- must match the actual exported file

`streams.<name>.duration_frames`

- required
- must match the actual exported file length in frames

`streams.<name>.latency_frames`

- required
- frame latency estimate at capture/export boundary
- `0` if unavailable

---

## 5. Recorder Export Rules

### 5.1 Export Rule

If both streams exist, the Recorder should export them so that:

- transcript time `0.0` corresponds to the same real session moment in both files

### 5.2 Padding Rule

When a stream starts later than session zero:

- pad the beginning of that stream with silence during export

Do not “shift left” by trimming real audio from the earlier stream.

### 5.3 Drift Rule

If measurable cross-stream drift exists:

- correct it before export if possible
- otherwise emit the measured drift in metadata

Recommended threshold for correction:

- absolute misalignment greater than `20 ms` over `30 minutes`

### 5.4 Residual Error Target

After alignment:

- target residual offset of `<= 10 ms` at start
- target cumulative drift error of `<= 20 ms` over a normal meeting-length recording

---

## 6. Processor Consumption Rules

The Processor should interpret recorder sync metadata as follows:

1. if `aligned_wav_export = true`, trust the exported files as already aligned
2. still retain `stream_sync` metadata for logging and diagnostics
3. if `aligned_wav_export = false`, shift transcript segment times using `start_offset_seconds`
4. if `estimated_drift_ppm` is non-zero and no recorder-side correction was applied, surface a warning

The Processor should not use transcript-text matching as the primary source of sync when recorder metadata is available. Transcript-based alignment should remain a fallback/debug tool only.

---

## 7. Recorder Implementation Guidance

### 7.1 Capture Topology

Preferred:

- capture mic and system audio inside the same app process
- timestamp incoming buffers using the same host-time clock

### 7.2 Common Timeline

For each stream, record:

- host time of the first captured sample
- total frames written
- effective sample rate used for export

### 7.3 Export

At finalize time:

1. compute session zero
2. compute each stream’s `start_offset_seconds`
3. pad later-starting streams with silence
4. resample if drift correction is required
5. write final WAVs
6. emit `stream_sync`

### 7.4 Validation

Before upload, the Recorder should validate:

- actual WAV duration matches metadata duration
- actual WAV sample rate matches metadata sample rate
- `relative_offset_to_system_seconds` agrees with per-stream offsets
- `aligned_wav_export = true` only if padding/correction has actually been applied

---

## 8. Reliability Checklist For The Recorder Team

- use one monotonic clock for both streams
- record first-sample host time for each stream
- export aligned WAVs with silence padding where needed
- emit `stream_sync` metadata on every session
- include signed relative mic-to-system offset
- include drift estimate
- include echo cancellation status
- prefer headphones or AEC to reduce playback bleed

---

## 9. Recommended Next Processor Step

Once the Recorder emits this metadata, the Processor should:

- stop guessing cross-track alignment from transcript text
- apply metadata-based offsets before merging segments
- use overlap dedupe only as a cleanup step for bleed/echo cases

That is the most reliable architecture for this product.
