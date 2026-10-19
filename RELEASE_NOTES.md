# Memoir Processor 1.1.1

- Automatically obtains trusted HTTPS certificates for this Mac's Tailscale hostname when Tailscale HTTPS is enabled.
- Checks certificate renewal every six hours and applies renewed certificates without interrupting existing connections.
- Fixes duplicate request headers that prevented macOS recorder clients from connecting through the HTTPS proxy.

Requires macOS 15 or later and Apple Silicon. Basic transcription uses local WhisperKit models. Speaker identification remains optional and requires a separate runtime and Hugging Face model access.
