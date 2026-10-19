# Memoir Processor 1.5.0 — Live voices

- Detects speakers during recording from short authenticated audio previews. FluidAudio handles the live view independently of the chosen final diarization engine.
- Remembers people explicitly named in the Recorder, using voice embeddings stored locally. Conservative matching leaves uncertain voices unnamed; automatic guesses do not train the voice bank.
- Carries live speaker names into finished FluidAudio and Pyannote transcripts. Splits merged final clusters where confirmed live identities provide evidence, and excludes mixed voice embeddings from learning.
- Preserves word timings to assign speaker changes within a transcription segment. Naming a person in a finished transcript also prepares a compatible live voice sample when a clean audio excerpt is available.
- Keeps preview processing bounded and separate from full recording uploads. Temporary preview audio is removed after processing. Live models download automatically on first use.

Pair with Memoir Recorder 1.4.0 for the live speaker interface. Existing Recorder versions remain compatible with finished transcription. Requires macOS 15 or later.
