# Memoir Processor 1.2.0

- Becomes the backend for Memoir's meeting library, returning timestamped transcripts to recorder clients.
- Adds authenticated archive browsing, full-text search, transcript retrieval, meeting/speaker naming and retry endpoints.
- Indexes existing transcripts on upgrade; refreshes search and exports when speaker names change.
- Uses revisions to protect against stale edits from another Mac.
- Preserves upload compatibility, local WhisperKit transcription, managed Tailscale HTTPS and signed Sparkle updates.

Use with Memoir 1.2.0 for the new library. The processor window remains an operator console. Requires macOS 15 or later and Apple Silicon. Optional speaker diarization requires its separate runtime and model access.
