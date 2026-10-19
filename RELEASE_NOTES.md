# Memoir Processor 1.4.0 — Choose your speaker engine

- Switch between **FluidAudio · Core ML** and **Pyannote Community-1 · GPU** in Settings. Save Configuration applies the choice to the next meeting without interrupting active processing.
- FluidAudio uses the offline VBx pipeline on Core ML with CPU/Neural Engine compute. Its models download without a token or Python installation. Older configurations start with FluidAudio on upgrade.
- Upgrades Pyannote from legacy 3.1 to Community-1, including exclusive speaker turns for transcript alignment and built-in voice embeddings. Uses a separate Python 3.11 runtime, MPS acceleration and optional CPU inference fallback. Hugging Face model approval and token access are required; telemetry is disabled.
- Adds engine-specific model preparation controls and runtime status. Logs and artifacts identify the engine/backend used.
- Keeps voice samples separate by model family to prevent incompatible samples from producing false speaker matches. Names and existing samples are preserved. Reprocessing replaces old speaker clusters cleanly.

Compatible with Memoir Recorder 1.2.0 or later. Audio processing remains local. Requires macOS 15 or later.
