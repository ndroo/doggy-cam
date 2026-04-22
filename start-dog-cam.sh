#!/bin/bash
# Dogcam (audio+video): ffmpeg captures webcam+mic -> HLS in /tmp/dogcam/.
# Python's stdlib http.server serves the dir. cloudflared exposes it publicly.
# iPhone Safari plays the HLS stream natively. Stop with Ctrl+C.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CAM_INDEX="${DOGCAM_CAM:-0}"     # video device (avfoundation)
MIC_INDEX="${DOGCAM_MIC:-0}"     # audio device (avfoundation)
FPS="${DOGCAM_FPS:-30}"
PORT="${DOGCAM_PORT:-8080}"
DIR="/tmp/dogcam"

mkdir -p "$DIR"
# wipe old HLS / JPEG state
rm -f "$DIR"/*.ts "$DIR"/*.m3u8 "$DIR"/frame.jpg 2>/dev/null

cat > "$DIR/index.html" <<'HTML'
<!doctype html>
<html><head><title>dogcam</title>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  body{margin:0;background:#000;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;font-family:-apple-system,sans-serif;color:#ccc}
  video{max-width:100%;max-height:100vh;display:block;background:#000}
  #s{position:fixed;top:8px;left:8px;font-size:12px;background:rgba(0,0,0,.6);padding:4px 8px;border-radius:4px}
</style></head>
<body>
<video id="v" controls playsinline autoplay></video>
<div id="s">loading…</div>
<script>
  const v=document.getElementById('v'), s=document.getElementById('s');
  const src='stream.m3u8';
  if (v.canPlayType('application/vnd.apple.mpegurl')) {
    v.src = src;                 // Safari (iPhone): native HLS
  } else {
    // other browsers: load hls.js from CDN
    const tag=document.createElement('script');
    tag.src='https://cdn.jsdelivr.net/npm/hls.js@1';
    tag.onload=()=>{const h=new Hls();h.loadSource(src);h.attachMedia(v)};
    document.head.appendChild(tag);
  }
  v.addEventListener('playing',()=>{s.textContent='live'});
  v.addEventListener('waiting',()=>{s.textContent='buffering…'});
  v.addEventListener('error', ()=>{s.textContent='error — segments not ready yet, retrying'; setTimeout(()=>v.load(),2000)});
  // browsers usually block unmuted autoplay — fall back to muted so the picture
  // still starts, then the user can tap the unmute icon in the built-in video controls.
  v.muted = false;
  v.play().catch(()=>{ v.muted = true; v.play(); });

  // catch-up: if we drift too far behind live, seek forward; small drift -> nudge speed up.
  setInterval(()=>{
    if (v.paused || !v.buffered.length) return;
    const end = v.buffered.end(v.buffered.length - 1);
    const lag = end - v.currentTime;
    if (lag > 8) {
      v.currentTime = Math.max(end - 2, v.currentTime + 0.5);
      v.playbackRate = 1;
      s.textContent = 'caught up (-' + (lag - 2).toFixed(1) + 's)';
    } else if (lag > 4) {
      v.playbackRate = 1.1;
      s.textContent = 'live (catching up '+ lag.toFixed(1) +'s)';
    } else {
      v.playbackRate = 1;
    }
  }, 1000);
</script>
</body></html>
HTML

FF_LOG=/tmp/dogcam-ff.log
HTTP_LOG=/tmp/dogcam-http.log
TUN_LOG=/tmp/dogcam-tunnel.log
: > "$FF_LOG"; : > "$HTTP_LOG"; : > "$TUN_LOG"

_cleaned=0
cleanup() {
  [ "$_cleaned" = "1" ] && return
  _cleaned=1
  echo
  echo ">> shutting down"
  local pids="${FF_PID:-} ${HTTP_PID:-} ${TUN_PID:-} ${CAF_PID:-}"
  # polite SIGTERM first — lets ffmpeg release the camera cleanly
  for pid in $pids; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  done
  # wait up to ~3s for graceful exit
  for i in 1 2 3 4 5 6 7 8 9 10; do
    local alive=0
    for pid in $pids; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" = "0" ] && break
    sleep 0.3
  done
  # anything still alive (e.g. ffmpeg stuck in avfoundation teardown): SIGKILL
  for pid in $pids; do
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  done
  wait 2>/dev/null
}
on_signal() { cleanup; exit 0; }
trap on_signal INT TERM
trap cleanup EXIT

echo ">> starting caffeinate to keep the Mac awake (display + idle + system + disk)"
caffeinate -dis &
CAF_PID=$!

# burn current wall-clock time into top-left corner of the video.
# Use ffmpeg single-quoted filter value + drawtext default localtime format
# (default is "YYYY-MM-DD HH:MM:SS") to avoid colon-escaping headaches.
DRAWTEXT="drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial Bold.ttf:text='%{localtime}':fontsize=22:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=6:x=12:y=12"

start_ffmpeg() {
  local with_audio="$1"
  if [ "$with_audio" = "1" ]; then
    echo ">> starting ffmpeg HLS encode WITH AUDIO + clock overlay (video=$CAM_INDEX, audio=$MIC_INDEX, ${FPS}fps)"
    ffmpeg -nostdin -hide_banner -loglevel warning \
      -f avfoundation -framerate "$FPS" -video_size 640x480 \
      -i "${CAM_INDEX}:${MIC_INDEX}" \
      -vf "$DRAWTEXT" \
      -c:v h264_videotoolbox -b:v 500k -g 60 -keyint_min 60 \
      -c:a aac -b:a 48k -ar 44100 -ac 1 \
      -f hls -hls_time 2 -hls_list_size 8 \
      -hls_flags delete_segments+independent_segments+omit_endlist \
      -hls_segment_type mpegts \
      -hls_segment_filename "$DIR/seg%05d.ts" \
      "$DIR/stream.m3u8" \
      >"$FF_LOG" 2>&1 &
  else
    echo ">> starting ffmpeg HLS encode VIDEO ONLY + clock overlay (video=$CAM_INDEX, ${FPS}fps)"
    ffmpeg -nostdin -hide_banner -loglevel warning \
      -f avfoundation -framerate "$FPS" -video_size 640x480 \
      -i "${CAM_INDEX}" \
      -vf "$DRAWTEXT" \
      -c:v h264_videotoolbox -b:v 500k -g 60 -keyint_min 60 \
      -an \
      -f hls -hls_time 2 -hls_list_size 8 \
      -hls_flags delete_segments+independent_segments+omit_endlist \
      -hls_segment_type mpegts \
      -hls_segment_filename "$DIR/seg%05d.ts" \
      "$DIR/stream.m3u8" \
      >"$FF_LOG" 2>&1 &
  fi
  FF_PID=$!
}

start_ffmpeg 1
# give the mic-attached run ~3s to fail before falling back
sleep 3
if ! kill -0 "$FF_PID" 2>/dev/null && grep -q "Cannot use .* Microphone\|Failed to create AV capture input device" "$FF_LOG"; then
  echo "!! mic access denied — to fix: System Settings > Privacy & Security > Microphone > enable iTerm, then restart"
  echo ">> falling back to video-only so you still get a picture"
  : > "$FF_LOG"
  rm -f "$DIR"/seg*.ts "$DIR"/stream.m3u8 2>/dev/null
  start_ffmpeg 0
fi

# wait for the playlist + at least one segment to appear
for i in {1..60}; do
  if [ -s "$DIR/stream.m3u8" ] && ls "$DIR"/seg*.ts >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
  if ! kill -0 "$FF_PID" 2>/dev/null; then
    echo "!! ffmpeg died. Last lines:"; tail -40 "$FF_LOG"; exit 1
  fi
done
[ -s "$DIR/stream.m3u8" ] || { echo "!! no playlist after 30s. Log:"; tail -40 "$FF_LOG"; exit 1; }
echo ">> first HLS segment written"

# preflight: if $PORT is already bound, reap our own orphan serve.py but
# refuse to touch anything else (could be an unrelated app the user is running).
existing=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)
for pid in $existing; do
  cmd=$(ps -p "$pid" -o command= 2>/dev/null)
  if echo "$cmd" | grep -q "serve\.py"; then
    echo ">> found orphan serve.py (pid $pid) on port $PORT — killing"
    kill -TERM "$pid" 2>/dev/null
    sleep 0.5
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  else
    echo "!! port $PORT is in use by another process (pid $pid): $cmd"
    echo "   set DOGCAM_PORT=<other> or stop that process, then retry"
    exit 1
  fi
done

echo ">> starting http server on :$PORT with no-cache for .m3u8 (log: $HTTP_LOG)"
( cd "$DIR" && exec python3 "$SCRIPT_DIR/serve.py" "$PORT" 127.0.0.1 ) >"$HTTP_LOG" 2>&1 &
HTTP_PID=$!
sleep 0.5

echo ">> starting cloudflared tunnel (log: $TUN_LOG)"
cloudflared tunnel --url "http://localhost:$PORT" --protocol http2 --no-autoupdate >"$TUN_LOG" 2>&1 &
TUN_PID=$!

URL=""
for i in {1..60}; do
  URL=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUN_LOG" | head -1)
  [ -n "$URL" ] && break
  sleep 1
done
[ -n "$URL" ] || { echo "!! tunnel did not produce a URL. Last lines:"; tail -40 "$TUN_LOG"; exit 1; }

cat <<EOF

============================================================
  DOGCAM IS LIVE (video + audio)
  URL: $URL
============================================================
Open that URL on your iPhone Safari.
The page may start MUTED — tap "unmute" to hear audio.
Latency is ~6-8 seconds (HLS).
URL is unguessable but has no password — don't share it.
Leave this terminal open. Ctrl+C to stop everything.

  Mac will stay awake (caffeinate is running) until you Ctrl+C.

EOF

# block until any child exits (portable for macOS bash 3.2)
while kill -0 "$FF_PID" 2>/dev/null \
   && kill -0 "$HTTP_PID" 2>/dev/null \
   && kill -0 "$TUN_PID" 2>/dev/null \
   && kill -0 "$CAF_PID" 2>/dev/null; do
  sleep 2
done
echo "!! a child process exited:"
kill -0 "$FF_PID"   2>/dev/null || echo "   - ffmpeg died, see $FF_LOG"
kill -0 "$HTTP_PID" 2>/dev/null || echo "   - http.server died, see $HTTP_LOG"
kill -0 "$TUN_PID"  2>/dev/null || echo "   - cloudflared died, see $TUN_LOG"
kill -0 "$CAF_PID"  2>/dev/null || echo "   - caffeinate died (Mac may sleep)"
