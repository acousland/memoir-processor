# Memoir Recorder to Processor Interface Specification

## 1. Purpose

This document defines the strict integration contract between:

- the **Memoir Recorder** app running on the user's recording Mac
- the **Memoir Processor** app/service running on a separate Mac Mini

This contract replaces shared-folder or manual file transfer workflows with an authenticated, local-network API that is transparent to the user.

The audience for this document is the **Recorder team**. It describes exactly how the Recorder must register, upload, and finalize a completed recording session so the Processor can ingest it reliably.

---

## 2. Goals

The interface must:

- feel automatic to the user
- work across two Macs on the same network
- support reliable transfer of completed recordings
- be restart-safe on both sides
- support idempotent retries
- keep the Recorder and Processor loosely coupled

This is a **post-recording batch handoff**. The Processor is not a live streaming transcription service in v1.

---

## 3. Non-Goals

This interface does not support in v1:

- live upload during recording
- partial transcript streaming back to the Recorder
- cloud relay or internet transport
- browser clients
- multi-user access control

---

## 4. Transport Overview

The Recorder communicates with the Processor over the local network using HTTPS or HTTP on a trusted LAN.

Recommended v1 deployment:

- Processor hosts an authenticated LAN service on the Mac Mini
- Recorder is configured with the Processor base URL and a shared auth token during pairing/setup
- Recorder uploads completed session files after recording finishes

The user experience should be:

1. recording completes on the Recorder Mac
2. Recorder transparently transfers the session to the Processor
3. Processor validates and queues the job
4. user later sees processing status and transcript availability

---

## 5. Protocol Versioning

All requests must include an explicit API version header.

Required header:

```text
X-Memoir-API-Version: 1
```

If the Processor does not support the requested version, it must return:

- `400 Bad Request` or `409 Conflict`
- error code: `unsupported_api_version`

The Recorder must fail closed and surface a sync/integration error rather than guessing.

---

## 6. Authentication

All requests except health checks must include a bearer token.

Required header:

```text
Authorization: Bearer <processor_shared_token>
```

Rules:

- token is provisioned during pairing/setup
- token is required for session creation, uploads, completion, and status polling
- missing or invalid token returns `401 Unauthorized`
- token mismatch must not create partial session records

The Processor should bind intentionally to the local network only. Internet exposure is out of scope.

---

## 7. Canonical Session Model

The Processor treats each uploaded recording as a single immutable **session**.

Each session includes:

- one required `system.wav`
- one optional `mic.wav`
- one required `metadata.json`

The Recorder is responsible for creating a session identifier that is stable across retries of the same completed recording.

### 7.1 Required Session Identity Fields

- `session_id`
- `recording_started_at`
- `recording_ended_at`
- `session_name`

### 7.2 Session ID Rules

`session_id` must:

- be globally unique for the recording
- be stable across retries
- not be regenerated after upload failures

Recommended format:

- UUID v4 generated once when the recording session is created

---

## 8. High-Level Flow

The Recorder must follow this sequence exactly:

1. `POST /v1/sessions`
2. `PUT /v1/sessions/{session_id}/files/metadata`
3. `PUT /v1/sessions/{session_id}/files/system`
4. optionally `PUT /v1/sessions/{session_id}/files/mic`
5. `POST /v1/sessions/{session_id}/complete`
6. optionally `GET /v1/sessions/{session_id}` to observe handoff state

The Processor must not begin processing until the session has been marked complete successfully.

---

## 9. Session Lifecycle States

The Processor exposes two related lifecycles:

### 9.1 Ingestion State

Used for upload and handoff.

- `created`
- `uploading`
- `uploaded`
- `ready_for_processing`
- `rejected`

### 9.2 Processing State

Used after handoff into the processor pipeline.

- `queued`
- `validating`
- `transcribing`
- `diarizing`
- `writing_artifacts`
- `completed`
- `failed`
- `retry_pending`

The Recorder only depends on the ingestion lifecycle for successful transfer. It may display later processing state if desired, but that is optional.

---

## 10. Strict HTTP Contract

Base URL example:

```text
http://memoir-processor.local:8765
```

All JSON requests must use:

```text
Content-Type: application/json
Accept: application/json
```

All successful JSON responses must use:

```text
Content-Type: application/json
```

### 10.1 Health Check

#### `GET /health`

Purpose:

- allows the Recorder to test reachability before upload

Authentication:

- not required

Success response:

```json
{
  "status": "ok",
  "service": "memoir-processor",
  "api_version": 1
}
```

---

### 10.2 Create Session

#### `POST /v1/sessions`

Purpose:

- registers a new completed recording session before file upload

Headers:

- `Authorization: Bearer <token>`
- `X-Memoir-API-Version: 1`
- `Idempotency-Key: <stable-request-id>`

The `Idempotency-Key` is required. For retries of the same create request, it must be reused.

Request body:

```json
{
  "session_id": "a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92",
  "session_name": "Weekly Product Review",
  "recording_started_at": "2026-04-08T09:00:00Z",
  "recording_ended_at": "2026-04-08T09:42:31Z",
  "recorder": {
    "device_id": "recorder-mbp-01",
    "app_version": "1.0.0",
    "build": "100"
  },
  "expected_files": {
    "metadata": true,
    "system": true,
    "mic": true
  }
}
```

Rules:

- `session_id` must be unique
- `recording_ended_at` must be later than `recording_started_at`
- `expected_files.mic` indicates whether the Recorder intends to upload `mic.wav`

Successful response:

Status:

- `201 Created` for first creation
- `200 OK` for an idempotent replay with matching payload

Body:

```json
{
  "session_id": "a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92",
  "ingestion_state": "created",
  "upload_urls": {
    "metadata": "/v1/sessions/a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92/files/metadata",
    "system": "/v1/sessions/a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92/files/system",
    "mic": "/v1/sessions/a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92/files/mic"
  }
}
```

Conflict conditions:

- same `session_id` with materially different payload returns `409 Conflict`
- error code: `session_conflict`

---

### 10.3 Upload Metadata File

#### `PUT /v1/sessions/{session_id}/files/metadata`

Purpose:

- uploads the exact `metadata.json` generated by the Recorder

Headers:

- `Authorization: Bearer <token>`
- `X-Memoir-API-Version: 1`
- `Content-Type: application/json`
- `X-Content-SHA256: <hex digest>`

Body:

- raw bytes of `metadata.json`

Rules:

- this endpoint accepts the file bytes, not an envelope JSON object
- SHA-256 must match the uploaded bytes exactly
- repeated upload of identical bytes is allowed and must be idempotent

Success response:

```json
{
  "session_id": "a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92",
  "file": "metadata",
  "size_bytes": 482,
  "sha256": "5f8d6d7d6f63f8a91d3f7ecfdf3c2d2a34a6ec6d3e72980ad3d6f4b3a77b6fa1",
  "accepted": true
}
```

---

### 10.4 Upload System Audio

#### `PUT /v1/sessions/{session_id}/files/system`

Purpose:

- uploads the required `system.wav`

Headers:

- `Authorization: Bearer <token>`
- `X-Memoir-API-Version: 1`
- `Content-Type: audio/wav`
- `X-Content-SHA256: <hex digest>`
- `Content-Length: <bytes>`

Body:

- raw bytes of `system.wav`

Rules:

- full-file upload only in v1
- no chunked resumable protocol in v1
- Recorder must retry the full upload on failure
- repeated upload of identical bytes is allowed and must be idempotent

Success response:

```json
{
  "session_id": "a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92",
  "file": "system",
  "size_bytes": 180224000,
  "sha256": "0fcd98fa66ea4b4ee0e9d4db7a11fd8a10d2fd14601f9f1b2604839bbf49b613",
  "accepted": true
}
```

---

### 10.5 Upload Mic Audio

#### `PUT /v1/sessions/{session_id}/files/mic`

Purpose:

- uploads the optional `mic.wav`

Headers and behavior:

- identical to `system`

Rules:

- only call this endpoint if `expected_files.mic` was `true`
- if the session was created with `expected_files.mic: false`, uploading `mic` must return `409 Conflict`
- error code: `unexpected_file`

---

### 10.6 Complete Session Upload

#### `POST /v1/sessions/{session_id}/complete`

Purpose:

- tells the Processor the Recorder has finished all uploads for the session
- triggers Processor-side validation and queue admission

Headers:

- `Authorization: Bearer <token>`
- `X-Memoir-API-Version: 1`
- `Idempotency-Key: <stable-complete-request-id>`

Request body:

```json
{
  "uploaded_files": {
    "metadata": {
      "size_bytes": 482,
      "sha256": "5f8d6d7d6f63f8a91d3f7ecfdf3c2d2a34a6ec6d3e72980ad3d6f4b3a77b6fa1"
    },
    "system": {
      "size_bytes": 180224000,
      "sha256": "0fcd98fa66ea4b4ee0e9d4db7a11fd8a10d2fd14601f9f1b2604839bbf49b613"
    },
    "mic": {
      "size_bytes": 60102400,
      "sha256": "93216a8f7195929b4acf6f8d6f4ad6ed9f6d5cf940ca29b5fdc4a740d1a1e813"
    }
  }
}
```

Rules:

- `metadata` and `system` are always required
- `mic` is required if and only if `expected_files.mic` was `true`
- Processor must compare declared hashes and sizes to uploaded files before accepting completion
- Processor must not start processing if required files are missing

Successful response:

```json
{
  "session_id": "a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92",
  "ingestion_state": "ready_for_processing",
  "processing_state": "queued",
  "accepted_at": "2026-04-08T09:43:12Z"
}
```

Failure examples:

- missing upload: `409 Conflict`, `missing_required_file`
- checksum mismatch: `409 Conflict`, `checksum_mismatch`
- duplicate completion with identical prior success: `200 OK`

---

### 10.7 Get Session Status

#### `GET /v1/sessions/{session_id}`

Purpose:

- lets the Recorder check whether handoff succeeded
- optionally allows the Recorder to show downstream processing progress

Headers:

- `Authorization: Bearer <token>`
- `X-Memoir-API-Version: 1`

Success response:

```json
{
  "session_id": "a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92",
  "session_name": "Weekly Product Review",
  "ingestion_state": "ready_for_processing",
  "processing_state": "transcribing",
  "created_at": "2026-04-08T09:42:40Z",
  "updated_at": "2026-04-08T09:44:03Z",
  "expected_files": {
    "metadata": true,
    "system": true,
    "mic": true
  },
  "received_files": {
    "metadata": true,
    "system": true,
    "mic": true
  },
  "error": null
}
```

If processing fails:

```json
{
  "session_id": "a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92",
  "ingestion_state": "ready_for_processing",
  "processing_state": "failed",
  "error": {
    "code": "audio_decode_failed",
    "message": "system.wav could not be decoded as PCM WAV"
  }
}
```

---

## 11. Required Metadata Contract

The Recorder must upload a `metadata.json` file. The file must be valid UTF-8 JSON.

Required fields:

```json
{
  "session_id": "a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92",
  "session_name": "Weekly Product Review",
  "recording_started_at": "2026-04-08T09:00:00Z",
  "recording_ended_at": "2026-04-08T09:42:31Z",
  "timezone": "Australia/Melbourne",
  "system_audio": {
    "filename": "system.wav",
    "sample_rate_hz": 16000,
    "channels": 1,
    "duration_seconds": 2551.4
  }
}
```

Optional fields:

```json
{
  "mic_audio": {
    "filename": "mic.wav",
    "sample_rate_hz": 16000,
    "channels": 1,
    "duration_seconds": 2548.7
  },
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
  },
  "language_hint": "en",
  "notes": "optional freeform recorder-side notes"
}
```

Strict rules:

- `metadata.session_id` must equal the session ID used in the API path
- `system_audio.filename` must equal `system.wav`
- if `mic_audio` is present, `filename` must equal `mic.wav`
- timestamps must be ISO 8601 strings
- duration must be greater than zero

### 11.1 Recommended Sync Metadata

If the Recorder captures both `system.wav` and `mic.wav`, it should also emit a `stream_sync` block describing the shared capture timeline and the per-stream offset.

This is strongly recommended because transcript-text-only alignment is not reliable enough when:

- microphone audio includes speaker bleed from system playback
- system and mic streams have different device latencies
- the two capture paths begin on slightly different buffers

The authoritative recorder-side sync extension is defined in:

- [recorder-audio-sync-spec.md](/Users/acousland/Local%20Workspace/Code/memoir-processor/recorder-audio-sync-spec.md)

The Processor may reject malformed metadata with:

- `422 Unprocessable Entity`
- error code: `invalid_metadata`

---

## 12. Audio File Requirements

### 12.1 Required System File

`system.wav` is mandatory.

### 12.2 Optional Mic File

`mic.wav` is optional.

### 12.3 Format Expectations

Preferred format:

- WAV container
- PCM 16-bit
- mono
- 16 kHz

The Processor may accept compatible variations and normalize them internally, but the Recorder should target the preferred format to reduce failure risk and processing cost.

### 12.4 Recorder Responsibilities

Before upload, the Recorder must ensure:

- recording is fully complete
- file handles are closed
- file size is stable
- the bytes being hashed are exactly the bytes being uploaded

---

## 13. Idempotency and Retry Rules

This section is strict. The Recorder team must implement retries using these rules.

### 13.1 Session Creation

- `POST /v1/sessions` must include `Idempotency-Key`
- if the Recorder times out waiting for the response, it must retry with the same key
- the payload must be byte-for-byte equivalent in semantic content across retries

### 13.2 File Uploads

- file uploads are idempotent by `(session_id, file_type, sha256)`
- if the same file is uploaded again with the same checksum, the Processor must accept it
- if the same file slot is re-uploaded with different bytes before completion, the Processor may replace the prior file or reject with `409 Conflict`
- recommended Processor behavior is to reject changed bytes with `file_conflict`

### 13.3 Session Completion

- `POST /complete` must include `Idempotency-Key`
- retries of the same completion request must reuse the same key
- duplicate completion after a successful acceptance must return success rather than error

### 13.4 Recorder Retry Policy

Recommended v1 retry behavior:

- immediate retry once for transient connection reset
- then exponential backoff with jitter
- backoff example: 2s, 5s, 15s, 30s, 60s
- stop after a bounded number of attempts and mark the session as transfer failed locally

The Recorder must never generate a new `session_id` because of transport failure.

---

## 14. Error Contract

All non-2xx responses must return JSON:

```json
{
  "error": {
    "code": "checksum_mismatch",
    "message": "Uploaded file hash does not match X-Content-SHA256 header",
    "retryable": false
  }
}
```

Required error object fields:

- `code`
- `message`
- `retryable`

### 14.1 Standard Error Codes

- `unauthorized`
- `unsupported_api_version`
- `invalid_request`
- `session_conflict`
- `session_not_found`
- `unexpected_file`
- `missing_required_file`
- `checksum_mismatch`
- `invalid_metadata`
- `file_conflict`
- `payload_too_large`
- `processor_busy`
- `internal_error`

### 14.2 Retryability Guidance

Usually retryable:

- `processor_busy`
- `internal_error`

Usually not retryable without code or data change:

- `invalid_metadata`
- `checksum_mismatch`
- `unexpected_file`
- `session_conflict`

---

## 15. Timeouts and Size Expectations

Recommended v1 expectations:

- health check timeout: 3 seconds
- create session timeout: 10 seconds
- complete session timeout: 15 seconds
- file upload timeout: Recorder-defined based on file size and LAN conditions

The Recorder must assume uploads can take minutes for long meetings and must keep the UI asynchronous.

Suggested Processor limits:

- reject obviously unreasonable payload sizes with `413 Payload Too Large`
- keep exact max file size configurable

---

## 16. Processor Validation Rules

After successful `POST /complete`, the Processor must validate:

- all required uploads were received
- uploaded hashes match declared hashes
- `metadata.json` is readable
- `system.wav` exists and can be decoded
- `system.wav` duration is non-zero
- `mic.wav` is present if declared as expected

If validation fails:

- session must not enter transcription
- processing state becomes `failed`
- `GET /v1/sessions/{session_id}` must expose a structured error

---

## 17. Separation of Responsibilities

### 17.1 Recorder Responsibilities

- create a stable `session_id`
- ensure recording is finished before upload begins
- upload `metadata.json`
- upload required audio files
- send accurate sizes and SHA-256 digests
- call `complete` only after all uploads succeed
- retry transport failures idempotently

### 17.2 Processor Responsibilities

- authenticate requests
- store uploaded session files durably
- reject malformed or conflicting requests
- validate completed sessions before queueing
- process accepted sessions asynchronously
- expose status and failure state

### 17.3 Contract Boundary

The Recorder does not need to know:

- where the Processor stores files internally
- which transcription engine the Processor uses
- how retries inside the processing pipeline are implemented

The Processor does not depend on Recorder internals beyond this API and the `metadata.json` contract.

---

## 18. Recorder UX Expectations

The Recorder should present the transfer as background work.

Recommended states:

- `Preparing transfer`
- `Uploading to processor`
- `Queued for processing`
- `Processing`
- `Processing failed`

The user should never be asked to manually move files between Macs in the normal flow.

---

## 19. Pairing and Configuration Assumptions

This interface assumes the Recorder has already been configured with:

- Processor base URL
- shared bearer token
- optional friendly name for the target Processor

Pairing UX is out of scope for this document, but the API assumes that pairing is complete before recording transfer begins.

---

## 20. Example End-to-End Flow

### 20.1 Create

```http
POST /v1/sessions HTTP/1.1
Authorization: Bearer memoir-secret
X-Memoir-API-Version: 1
Idempotency-Key: 6b862f08-3ca1-4f0b-9c0b-53be8dd68f89
Content-Type: application/json

{
  "session_id": "a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92",
  "session_name": "Weekly Product Review",
  "recording_started_at": "2026-04-08T09:00:00Z",
  "recording_ended_at": "2026-04-08T09:42:31Z",
  "recorder": {
    "device_id": "recorder-mbp-01",
    "app_version": "1.0.0",
    "build": "100"
  },
  "expected_files": {
    "metadata": true,
    "system": true,
    "mic": true
  }
}
```

### 20.2 Upload Files

```http
PUT /v1/sessions/a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92/files/system HTTP/1.1
Authorization: Bearer memoir-secret
X-Memoir-API-Version: 1
Content-Type: audio/wav
X-Content-SHA256: 0fcd98fa66ea4b4ee0e9d4db7a11fd8a10d2fd14601f9f1b2604839bbf49b613
Content-Length: 180224000
```

### 20.3 Complete

```http
POST /v1/sessions/a34b65d8-f5d2-4d4a-8d8d-3fb71b1f0a92/complete HTTP/1.1
Authorization: Bearer memoir-secret
X-Memoir-API-Version: 1
Idempotency-Key: d7c9c6ef-f4c7-4ec2-a68d-d435479d1974
Content-Type: application/json

{
  "uploaded_files": {
    "metadata": {
      "size_bytes": 482,
      "sha256": "5f8d6d7d6f63f8a91d3f7ecfdf3c2d2a34a6ec6d3e72980ad3d6f4b3a77b6fa1"
    },
    "system": {
      "size_bytes": 180224000,
      "sha256": "0fcd98fa66ea4b4ee0e9d4db7a11fd8a10d2fd14601f9f1b2604839bbf49b613"
    },
    "mic": {
      "size_bytes": 60102400,
      "sha256": "93216a8f7195929b4acf6f8d6f4ad6ed9f6d5cf940ca29b5fdc4a740d1a1e813"
    }
  }
}
```

---

## 21. Acceptance Criteria for Recorder Integration

The Recorder integration is complete when it can:

- authenticate to the Processor
- create a session once and retry safely
- upload `metadata.json` and `system.wav` reliably
- upload `mic.wav` when available
- finalize the session with `POST /complete`
- avoid duplicate sessions on retry
- surface transfer failure separately from recording failure

---

## 22. Recommended Future Extensions

Not part of v1, but this contract leaves room for:

- resumable chunked uploads
- mTLS or stronger pairing/auth
- webhook or push status callbacks
- transcript download endpoints
- remote retry or delete endpoints

These should be introduced under a later API version rather than changing v1 semantics.

## Meeting library extension — Memoir 1.2.0

These routes use the same bearer token and `X-Memoir-API-Version: 1` header as upload routes. The original session/upload contract is unchanged. New library DTOs use camelCase JSON field names.

| Method | Route | Request / result |
| --- | --- | --- |
| GET | `/v1/meetings` | First 100 meeting summaries, newest recording first |
| POST | `/v1/meetings/search` | `{ "query": "budget", "offset": 0, "limit": 100 }`; summaries, including matching transcript excerpts |
| GET | `/v1/meetings/{uuid}` | `{ "meeting": summary, "segments": [...] }` |
| POST | `/v1/meetings/{uuid}/title` | `{ "title": "Planning", "expectedRevision": 1 }`; updated document |
| POST | `/v1/meetings/{uuid}/speaker` | `{ "speakerID": "track:mic", "name": "Alex", "expectedRevision": 1 }`; updated document |
| POST | `/v1/meetings/{uuid}/retry` | Retry a failed transcription; returns 202 with `{ "status": "queued" }` |

Summary fields: `id`, `title`, `startedAt`, `endedAt`, `status`, `updatedAt`, `transcriptAvailable`, optional `language`, optional `durationSeconds`, optional `excerpt`, optional `error`, and integer `revision`. Segment fields: stable `id`, `start`/`end` in seconds, stable `speakerID`, `speaker`, and `text`.

Search uses all provided words, with prefix matching and Unicode/diacritic folding. Punctuation is treated as separators; user input is not interpreted as FTS operators. A page contains at most 100 records. Existing transcript files are indexed on upgrade. No audio is served by the library API.

Meeting title edits are presentation metadata and preserve the original upload metadata/idempotency contract. Speaker edits update the canonical transcript and text/SRT artifacts and refresh search. Stale edits return HTTP 409 with `meeting_conflict`; active-job conflicts return `session_busy`. UUID/path validation and authentication apply to every transcript route.

Without diarization, `track:mic` means the local microphone (Me), and `track:system` means the combined remote/system audio (Others). Naming that source changes its label throughout the transcript; it does not perform individual speaker separation. Other stable speaker IDs preserve diarization clusters or existing speaker identity.
