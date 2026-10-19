# Memoir Processor

The backend for the Memoir meeting app: it accepts recordings, transcribes locally, stores the archive, indexes transcript text and returns finished transcripts to recorder clients. Its window remains an operator console for runtime, queue and service administration. Requires macOS 15 or later.

Version 1.3.0 brings the recorder’s **Thread** visual design to the operator console: rose accents, serif headings, month-grouped conversations, clear progress states and separate Overview, Speakers and Processing log tabs. Configuration, runtime and people screens share the same light/dark palette. Pairing tokens are hidden until revealed; window controls remain available at smaller sizes.

Version 1.2.0 introduced the authenticated meeting library API. Existing transcripts are indexed on upgrade. Clients can browse/search, read timestamped speaker-labelled transcripts and correct meeting or speaker names. Edits use revisions to protect against stale changes from another Mac. No cloud AI, notepad or summaries are added. Watched-folder ingestion from the original specification is not implemented.


## Use

Move **Memoir Processor.app** to Applications before installing its launch agent. Open Settings, save configuration, then install/start the agent. Copy the API token into the recorder. It is stored in Keychain; macOS may request access when the agent first reads a token created by the GUI.

Default HTTPS listens on port 8765. The internal HTTP listener is loopback-only on the next port. With Tailscale running and HTTPS certificates enabled in its admin console, the proxy obtains a trusted certificate for this Mac's full Tailscale DNS name. Enter `https://<machine>.<tailnet>.ts.net:8765` in the recorder; keep both Macs connected to Tailscale. Certificate renewal is checked every six hours and loaded without interrupting existing connections. Complete certificate/key pairs are published atomically under `<storage root>/tls/tailscale-certificates`, and provisioning failures retain the previous certificate and appear in the agent error log.

Without Tailscale HTTPS provisioning, the processor uses the certificate and key at `<storage root>/tls/server.crt` and `server.key` (generating a self-signed pair if absent). Supply a trusted certificate matching the hostname or establish certificate trust on the recording Mac before connecting.

Prepare the WhisperKit model from Runtime. Initial preparation requires a download; transcription thereafter runs locally. Start with diarization disabled. Completed sessions contain JSON, plain-text and SRT transcripts. Refresh updates the session list; artifacts can be opened from the session view. Audio, metadata, outputs and job logs remain together.

Speaker identification is optional. Choose **FluidAudio · Core ML** or **Pyannote Community-1 · GPU** in Settings, prepare that engine, and **Save Configuration**. The choice applies to the next queued meeting without restarting or interrupting active processing. Existing configurations default to FluidAudio when upgraded. Transcription remains WhisperKit for either diarization engine.

- **FluidAudio** uses its offline VBx pipeline with Core ML configured for CPU and Apple Neural Engine. Models download once through **Prepare FluidAudio Models**. It needs no Python or Hugging Face token. Core ML controls actual operation placement; the log reports the configured CPU/ANE backend.
- **Pyannote Community-1** uses an isolated Python 3.11 environment and PyTorch MPS on Apple Silicon. Install Python 3.11 and use **Prepare Pyannote Community-1**. Accept [Community-1 model conditions](https://huggingface.co/pyannote/speaker-diarization-community-1), save your Hugging Face token, and enable **Read access to contents of all public gated repos you can access** for fine-grained tokens. The previous legacy 3.1 Python environment is retained but no longer used. CPU fallback is optional and applies only to inference failures. Pyannote telemetry is disabled.

Voice samples are tagged with their engine/model family. Names and old samples remain stored, while automatic matches only compare compatible samples. When using the other engine, identify a person again to enrol a voice sample for that engine. The processing log and diarization artifact identify the engine/backend used. **Retry** on an existing meeting runs the saved engine and replaces its speaker clusters; original audio remains available. Model downloads need internet access; audio processing stays local. A diarization failure produces a visible warning while retaining the basic transcript.

## Develop and test

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project MemoirProcessor.xcodeproj -scheme MemoirProcessorApp -destination 'platform=macOS' test
scripts/package_app.sh
```

The GUI scheme runs the app and includes core tests. Test coverage includes alignment, echo deduplication, Python JSON decoding, restart recovery, invalid session paths, permanent errors, bounded HTTP framing and subprocess pipe draining. The package lock records WhisperKit and Sparkle dependencies.

A GPU diarization smoke check synthesizes two voices, reads the saved Keychain token, and runs the actual models with CPU fallback disabled. It uses temporary files and never changes the meeting archive:

```sh
python3 scripts/smoke-diarization.py --engine pyannote
python3 scripts/smoke-diarization.py --engine fluidaudio
```

An optional end-to-end smoke check synthesizes speech, launches an isolated agent, checks HTTP errors/authentication/uploads, runs WhisperKit, and validates transcript artifacts. It downloads a base model and never records a microphone:

```sh
python3 scripts/smoke-agent.py /path/to/MemoirProcessorAgent
```

For headless deployment, `MemoirProcessorAgent --config /absolute/config.json` reads an explicit configuration directly. Keep that file owner-readable only if it contains a token. Without this flag, the agent uses the GUI configuration and Keychain. An exclusive storage lock prevents duplicate agents. Upload bodies are limited to 1 GiB per file and streamed to temporary storage; the native listener admits at most 64 concurrent connections with a ten-minute request deadline. Transcription jobs run one at a time.

An integration check uploads isolated synthetic meetings to one real agent, changes the saved engine between jobs, and verifies the resulting speaker-labelled artifacts without restarting:

```sh
python3 scripts/smoke-engine-switch.py /path/to/MemoirProcessorAgent
```

## Release and updates

```sh
scripts/notarize-release.sh
# Review, commit and push source, then explicitly publish:
scripts/publish-release.sh
```

The release process uses the local Developer ID identity, `MEMOIR_NOTARY_PROFILE` (default `renoir-notary`), and Sparkle Keychain account `memoir`. Private credentials never enter source control. Increment `Assets/version` and `Assets/build-number` for subsequent releases. App and DMG notarization, ticket stapling, Gatekeeper verification, and Sparkle signature verification are mandatory.

The updater checks its signed feed and exposes **Check for Updates…** in the application menu. Installation waits for active jobs, stops the installed service before replacing its executable, and restarts it when the updated GUI launches. Existing pre-Sparkle installations need one manual replacement.
