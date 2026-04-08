# Memoir – Mac Mini Processor Product Specification

## 1. Overview

Memoir Processor is the local processing system that runs on a Mac Mini and converts completed Memoir recording sessions into structured, searchable outputs.

It is a **post-recording batch processor**, not a live transcription server in v1.

The processor ingests completed session folders produced by the Memoir recorder, runs transcription and optional diarization locally, and writes analysis-ready artifacts back to disk.

**Primary goal:** Reliable, local-first post-processing of meeting recordings.

**Non-goals (v1):**

- Live transcription
- Live diarization
- Browser-based multi-user access
- Cloud processing
- Tight coupling to the recorder during capture

---

## 2. Product Goals

### 2.1 Core Goals

- Process recordings entirely locally on the Mac Mini
- Support completed recordings with separate `system` and `mic` tracks
- Produce accurate transcripts with timestamps
- Optionally add speaker segmentation / diarization
- Generate outputs that are easy to inspect and easy to build on later
- Be resilient to failures, restarts, and partial jobs

### 2.2 Design Principles

- **Local-first:** no cloud dependency required for transcription
- **Asynchronous:** processing happens after recording, not during capture
- **File-driven:** session folders are the source of truth
- **Recoverable:** crashes should not lose work
- **Extensible:** later support summaries, action items, search, and UI

---

## 3. Inputs and Outputs

### 3.1 Input Contract

The processor consumes completed session folders created by the Memoir recorder.

Expected structure:

```text
YYYY-MM-DD_HH-MM-SS_<SessionName>/
  system.wav
  mic.wav                # optional
  metadata.json
```

### 3.2 Input Requirements

#### Required

- `system.wav`
- `metadata.json`

#### Optional

- `mic.wav`

### 3.3 Output Contract

Each processed session should produce:

```text
YYYY-MM-DD_HH-MM-SS_<SessionName>/
  system.wav
  mic.wav
  metadata.json
  processing/
    job.json
    transcript.json
    transcript.txt
    transcript.srt
    diarization.json      # optional in v1
    analysis.json         # reserved for future
    logs.txt
```

### 3.4 Output Goals

Outputs must be:

- human-readable
- machine-readable
- stable enough for future downstream tools

---

## 4. User Stories

### 4.1 Core User Stories

- As a user, I want completed recordings to be picked up automatically by the Mac Mini.
- As a user, I want transcripts stored locally so I can inspect them later.
- As a user, I want processing to continue even if the Mac Mini restarts.
- As a user, I want failed jobs to be visible and retryable.
- As a user, I want my own microphone track handled separately when available.

### 4.2 Future User Stories

- As a user, I want summaries and action items generated from transcripts.
- As a user, I want to search across meetings.
- As a user, I want recurring speakers identified consistently.

---

## 5. High-Level Architecture

```text
Inbox / Watched Sessions
        ↓
Session Discovery
        ↓
Job Queue
        ↓
Preflight Validation
        ↓
Transcription Worker
        ↓
Optional Diarization Worker
        ↓
Post-Processing / Merge
        ↓
Artifact Writer
        ↓
Completed / Failed State
```

### 5.1 Major Components

- Session Discovery
- Job Queue
- Preflight Validator
- Audio Normalization Layer
- Transcription Worker
- Diarization Worker
- Transcript Merger / Formatter
- Artifact Writer
- Job State Store
- Logging / Observability

---

## 6. Processing Model

### 6.1 Batch-Only v1

The processor only handles **completed recordings**.

A session is eligible for processing when:

- required files exist
- the recorder has finished writing the session
- the session is not already being processed

### 6.2 Session States

Each session should move through explicit states:

- `discovered`
- `queued`
- `validating`
- `transcribing`
- `diarizing`
- `writing_artifacts`
- `completed`
- `failed`
- `retry_pending`

These states should be written to `processing/job.json`.

### 6.3 Idempotency

Processing should be idempotent where practical.

Re-running a job should either:

- overwrite prior generated artifacts cleanly, or
- create versioned outputs if configured

Default behavior in v1: overwrite generated outputs for the session.

---

## 7. Session Discovery and Ingestion

### 7.1 Ingestion Modes

Support at least one of the following in v1:

#### Option A: Watched Folder (recommended)

- Recorder syncs completed session folders into an inbox directory on the Mac Mini
- Processor watches that directory and enqueues new sessions

#### Option B: Local Upload API

- Recorder uploads completed sessions to an HTTP endpoint on the Mini
- Uploaded sessions are written into the inbox directory

### 7.2 Recommended v1 Approach

Use a **watched folder** first.

Recommended directories:

```text
~/Memoir/inbox
~/Memoir/processing
~/Memoir/completed
~/Memoir/failed
```

### 7.3 Folder Lifecycle

When a session is discovered:

1. validate folder contents
2. create processing state
3. move or mark session as in-progress
4. run job
5. place into completed or failed state

Preferred behavior:

- keep the original session folder intact
- write processing artifacts into a `processing/` subdirectory

---

## 8. Preflight Validation

Before a job begins, validate:

- session folder exists
- `metadata.json` is readable
- `system.wav` exists and is readable
- file is not still being written
- audio duration is non-zero
- sample rate / format can be decoded

### 8.1 Validation Failures

If validation fails:

- mark job as `failed`
- write structured reason into `job.json`
- do not start transcription

Example failure reasons:

- missing required file
- corrupt WAV
- malformed metadata
- empty audio

---

## 9. Audio Handling

### 9.1 Expected Input Audio

Preferred recorder output:

- mono WAV per track
- 16 kHz PCM16

### 9.2 Normalization Layer

The processor should not assume perfect input forever.

It should be able to:

- inspect audio properties
- resample if needed
- downmix to mono if needed
- normalize loudness conservatively if helpful
- produce temporary normalized working files

### 9.3 Working Audio Layout

Recommended temporary structure:

```text
processing/work/
  system.normalized.wav
  mic.normalized.wav
```

### 9.4 Design Rule

Never modify the original recording files.

---

## 10. Transcription Pipeline

### 10.1 Recommended v1 Engine

Use a local Whisper-family engine optimized for Apple Silicon.

Recommended options:

- WhisperKit
- MLX Whisper

### 10.2 Recommendation

For v1, optimize for:

- reliability
- timestamp support
- straightforward local execution
- maintainability on an M4 Mac Mini with 16 GB RAM

### 10.3 Transcription Strategy

Process the `system` track first, because it contains the full meeting audio heard on the Mac.

If `mic.wav` exists, optionally:

- transcribe it separately, or
- use it as a speaker-assistance signal in later stages

Recommended v1 path:

- primary transcript from `system.wav`
- preserve `mic.wav` for future diarization / alignment improvements

### 10.4 Required Transcript Features

Transcript output should include:

- segment text
- start timestamp
- end timestamp
- model metadata
- language (detected or configured)

### 10.5 Segment Granularity

Use segment-level timestamps in v1.

Word-level timestamps may be added later if supported cleanly by the chosen engine.

---

## 11. Diarization Strategy

### 11.1 Scope

Diarization in v1 is **optional** but the architecture should support it.

### 11.2 Reality Constraint

The `system.wav` track contains a mixed meeting output stream. The processor cannot recover true per-participant isolated channels from that track alone.

### 11.3 Practical Strategy

If `mic.wav` exists:

- treat the mic track as a strong indicator for the local user
- diarize the `system` track to estimate speaker turns for everyone else
- merge results later

If `mic.wav` does not exist:

- diarize `system.wav` only

### 11.4 Recommended v1 Diarization Engine

Use a local diarization pipeline such as pyannote in a post-transcription pass.

### 11.5 Diarization Outputs

`diarization.json` should contain:

- speaker labels
- time ranges
- confidence if available
- source notes

Example:

```json
{
  "speakers": [
    {"label": "speaker_0", "start": 0.0, "end": 4.2},
    {"label": "speaker_1", "start": 4.5, "end": 8.9}
  ]
}
```

---

## 12. Transcript Merge and Formatting

### 12.1 Merge Responsibilities

The post-processing layer should:

- take raw transcript segments
- optionally overlay diarization labels
- normalize punctuation where appropriate
- create stable output artifacts

### 12.2 Required Output Files

#### `transcript.json`

Canonical structured transcript.

#### `transcript.txt`

Human-readable plain text transcript.

#### `transcript.srt`

Subtitle-style timestamped export.

### 12.3 Canonical JSON Shape

Example:

```json
{
  "session_id": "uuid",
  "source_files": {
    "system": "system.wav",
    "mic": "mic.wav"
  },
  "transcription": {
    "engine": "whisperkit",
    "model": "base",
    "language": "en"
  },
  "segments": [
    {
      "start": 0.0,
      "end": 3.4,
      "speaker": "speaker_0",
      "text": "Welcome everyone, let's get started."
    }
  ]
}
```

### 12.4 Future Compatibility

The JSON schema should be stable enough to support later:

- summaries
- action item extraction
- search indexing
- UI rendering

---

## 13. Job Queue and Scheduling

### 13.1 Queue Requirements

The processor needs a persistent queue.

It must:

- survive process restarts
- avoid duplicate execution
- support retries
- record failure reasons

### 13.2 Concurrency

Recommended v1 behavior:

- process **one session at a time**

Reasons:

- simpler resource management
- lower thermal risk
- fewer race conditions
- easier debugging

### 13.3 Retry Policy

For transient failures:

- retry a small number of times
- use exponential backoff

For permanent failures:

- mark as failed
- require manual retry or explicit cleanup

---

## 14. Storage Layout

Recommended root:

```text
~/Memoir/
  inbox/
  sessions/
  logs/
```

Alternative lifecycle-based layout:

```text
~/Memoir/
  inbox/
  completed/
  failed/
```

### 14.1 Recommended v1 Layout

```text
~/Memoir/
  inbox/
  logs/
```

Each session remains self-contained inside its own folder, with artifacts written under `processing/`.

### 14.2 Design Principle

Keep all assets for a session together. This makes backup, inspection, and manual repair much easier.

---

## 15. Job Metadata

Each session should have a `processing/job.json` file.

Example:

```json
{
  "job_id": "uuid",
  "session_id": "uuid",
  "status": "transcribing",
  "attempt": 1,
  "created_at": "ISO8601",
  "updated_at": "ISO8601",
  "engine": "whisperkit",
  "model": "base",
  "error": null
}
```

This file is the source of truth for job state.

---

## 16. Failure Handling and Recovery

### 16.1 Failure Categories

- input validation failure
- audio decode failure
- model execution failure
- diarization failure
- artifact write failure
- disk full
- unexpected process crash

### 16.2 Recovery Rules

- original recordings must remain intact
- partial output files may be overwritten on retry
- logs must be preserved
- failures must be visible per session

### 16.3 Restart Recovery

On service startup:

- scan for sessions with incomplete jobs
- detect stale in-progress states
- move stale jobs to `retry_pending` or restart safely

---

## 17. Logging and Observability

### 17.1 Logging Requirements

Write logs for:

- session discovery
- validation results
- job state transitions
- engine invocation
- artifact generation
- failure details

### 17.2 Log Locations

Per-session log:

```text
processing/logs.txt
```

Optional service-level log:

```text
~/Memoir/logs/service.log
```

### 17.3 Debuggability

Logs should be readable enough to diagnose:

- bad input
- bad model settings
- repeated failure loops

---

## 18. Configuration

### 18.1 Required Configuration

- watched folder path
- transcription engine
- model name / size
- diarization enabled flag
- output formats to generate
- max retries

### 18.2 Optional Configuration

- language hint
- normalization enabled flag
- auto-cleanup temp files
- retention policy

### 18.3 Config Storage

Use a local config file such as:

```text
~/Memoir/config.json
```

---

## 19. Security and Privacy

### 19.1 Privacy Requirements

- all processing should remain local by default
- do not upload recordings or transcripts to third-party services in v1
- logs must avoid leaking sensitive transcript content unless explicitly intended

### 19.2 Local Access Assumption

The Mini is assumed to be on a trusted local environment.

If a local upload API is added later, it should at minimum:

- bind to local network intentionally
- support an authentication token or shared secret

---

## 20. Performance Targets

### 20.1 v1 Performance Goals

- stable processing of completed sessions without manual intervention
- reasonable throughput on an M4 Mac Mini with 16 GB RAM
- no system-wide instability under normal meeting workloads

### 20.2 Throughput Philosophy

Optimize first for:

- correctness
- recoverability
- maintainability

Then optimize for speed.

---

## 21. Recommended Tech Stack

### 21.1 Core Service

Recommended options:

- Python service for fastest iteration
- Swift service only if strong native integration is needed later

### 21.2 Suggested v1 Stack

- Python
- filesystem watcher
- persistent local queue
- WhisperKit or MLX Whisper wrapper
- pyannote for optional diarization
- JSON artifacts

### 21.3 Why Python for v1

- fastest iteration for model orchestration
- strongest ecosystem for diarization and transcript post-processing
- easiest integration with local pipelines

---

## 22. API / Interface Boundary with Recorder

The processor should depend only on the session folder contract, not on recorder internals.

### 22.1 Required Boundary

Recorder responsibilities:

- create valid session folder
- ensure files are complete
- optionally copy session to Mini

Processor responsibilities:

- detect valid session
- process it
- write outputs

### 22.2 Contract Rule

The session folder format is the integration boundary between the two repos.

---

## 23. MVP Scope

### Included in MVP

- watched folder ingestion
- session validation
- one-job-at-a-time queue
- local transcription
- transcript.json
- transcript.txt
- transcript.srt
- per-session job state file
- retry and failure handling

### Optional in MVP

- diarization
- mic-aware speaker labeling

### Excluded from MVP

- live streaming
- web UI
- search UI
- summaries and action items
- multi-user authentication

---

## 24. Success Criteria

The Memoir Processor MVP is successful if it:

- automatically detects completed sessions
- reliably processes them locally
- generates timestamped transcripts
- preserves original recordings
- survives restarts and recoverable failures
- produces outputs suitable for later analysis features

---

## 25. Suggested Build Order

### Phase 1

- watched folder
- validation
- basic queue
- transcription only
- artifact writing

### Phase 2

- retries and crash recovery
- better logs
- configurable models

### Phase 3

- diarization
- mic-aware speaker merge
- downstream analysis hooks

---

## 26. Final Product Definition

Memoir Processor is a local-first, batch-oriented meeting audio processing service for Mac Mini. It turns completed Memoir recording sessions into reliable transcript artifacts, while keeping the recorder independent, simple, and resilient.

