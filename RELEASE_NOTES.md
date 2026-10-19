# Memoir Processor 1.3.1 — GPU diarization repair

- Keeps input audio on CPU while pyannote transfers inference chunks to the Apple GPU (MPS).
- Moves both the voice-embedding model and its inference device when CPU fallback is required. Disabling fallback prevents silent CPU execution.
- Separates model setup failures from inference failures. Missing Hugging Face model permissions now explain which token setting and model approval are required, instead of reporting a failed CPU retry.
- Adds links to all three required model approvals and token permissions in Settings. Runtime installation status is separate from GPU availability.
- Records the actual combined backend when system and microphone tracks use different devices.

Compatible with Memoir Recorder 1.2.0 or later. Model downloads require authorized Hugging Face access; recording and transcription remain local.
