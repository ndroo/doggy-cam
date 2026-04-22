# dogcam

A tiny macOS script that turns your Mac's webcam + mic into a personal live stream you can watch from your phone. Leave your Mac at home pointed at the dog, open the URL on Safari, hear them bark at the mail carrier.

Built around:

- `ffmpeg` — captures webcam + mic via AVFoundation, encodes to HLS (H.264 + AAC)
- Python `http.server` — serves the HLS segments locally with `Cache-Control: no-cache` on the playlist
- `cloudflared` — creates an ephemeral public HTTPS tunnel (`*.trycloudflare.com`)
- `caffeinate` — keeps the Mac awake so it doesn't sleep mid-stream

Latency is ~6–8 seconds (typical HLS). Good enough for checking in on a pet; not good enough for a two-way conversation.

## Requirements

- macOS (uses `avfoundation`, `caffeinate`, `h264_videotoolbox`)
- [Homebrew](https://brew.sh) (install it if you don't have it)
- `ffmpeg` and `cloudflared`:
  ```sh
  brew install ffmpeg cloudflared
  ```
- Python 3 (already on macOS)
- **Camera + microphone permission for the specific terminal app you'll run the script from** — e.g. Terminal.app, iTerm, or VS Code's integrated terminal. macOS grants these per-app, not per-script, so if you launch from iTerm, it's iTerm that needs the permission (not Python, not ffmpeg). Grant via System Settings → Privacy & Security → Camera / Microphone.

## Usage

```sh
sh start-dog-cam.sh
```

The script prints a URL like `https://fitted-ate-investigators-catalog.trycloudflare.com`. Open it on your phone's Safari. It may start muted — tap the unmute icon in the video controls.

Stop with `Ctrl+C`. The script cleans up ffmpeg, the HTTP server, the tunnel, and `caffeinate` on exit.

## Configuration

All optional, set via environment variables:

| Var | Default | Meaning |
| --- | ------- | ------- |
| `DOGCAM_CAM` | `0` | AVFoundation video device index |
| `DOGCAM_MIC` | `0` | AVFoundation audio device index |
| `DOGCAM_FPS` | `30` | Capture framerate |
| `DOGCAM_PORT` | `8080` | Local HTTP port |

To list your devices:

```sh
ffmpeg -f avfoundation -list_devices true -i ""
```

## Security notes

- The tunnel URL is random and unguessable, but there is **no password**. Don't share it — anyone with the link can watch.
- The tunnel is ephemeral; a fresh URL is generated on each run.
- Cloudflare can see the stream in transit (standard for any reverse proxy). Don't use this for anything sensitive.
- If your webcam / mic permission is denied, the script falls back to video-only automatically.

## Troubleshooting

- **`http.server` dies with `Address already in use`** — a previous run left an orphan `serve.py` on the port. The script now auto-reaps its own orphans on start; if another app is using the port, set `DOGCAM_PORT` to something else.
- **Camera LED stays on after Ctrl+C** — the script now SIGTERMs ffmpeg, waits ~3s, then SIGKILLs. If it's still lingering, `pkill ffmpeg`.
- **"mic access denied"** — System Settings → Privacy & Security → Microphone → enable your terminal app, then restart the script.
- **Logs** live in `/tmp/dogcam-ff.log`, `/tmp/dogcam-http.log`, `/tmp/dogcam-tunnel.log`.

## License

MIT. See [LICENSE](LICENSE).
