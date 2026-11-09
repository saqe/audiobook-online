#!/bin/sh
# Mounts an S3-compatible bucket read-only at $MOUNT_POINT, waits until the
# mount is live, then runs the command given as arguments (Audiobookshelf).
#
# The mount is lazy: nothing is copied at start-up. rclone fetches a file from
# the bucket when it is read and keeps recently used data in a bounded cache on
# the volume, so start-up time does not depend on how big the library is.
set -eu

log() { printf '[start] %s\n' "$*"; }
die() { printf '[start] ERROR: %s\n' "$*" >&2; exit 1; }

: "${S3_BUCKET:?set S3_BUCKET}"
: "${S3_ENDPOINT:?set S3_ENDPOINT, e.g. https://<account-id>.r2.cloudflarestorage.com}"
: "${S3_ACCESS_KEY_ID:?set S3_ACCESS_KEY_ID}"
: "${S3_SECRET_ACCESS_KEY:?set S3_SECRET_ACCESS_KEY}"
: "${CF_TUNNEL_TOKEN:?set CF_TUNNEL_TOKEN (a Cloudflare Tunnel token). Without it the app is unreachable}"
[ "$#" -gt 0 ] || die "no command given to run after the mount"

S3_PREFIX="${S3_PREFIX:-}"             # optional folder inside the bucket
S3_PROVIDER="${S3_PROVIDER:-Other}"    # Cloudflare, Minio, AWS, Other, ...
S3_REGION="${S3_REGION:-auto}"
MOUNT_POINT="${MOUNT_POINT:-/audiobooks}"
CACHE_DIR="${CACHE_DIR:-/data/rclone-cache}"
VFS_CACHE_MODE="${VFS_CACHE_MODE:-full}"
VFS_CACHE_MAX_SIZE="${VFS_CACHE_MAX_SIZE:-5G}"
DIR_CACHE_TIME="${DIR_CACHE_TIME:-5m}"
# Stop the machine after this many minutes with nobody connected. 0 = never.
IDLE_STOP_MINUTES="${IDLE_STOP_MINUTES:-0}"
case "$IDLE_STOP_MINUTES" in
  ''|*[!0-9]*) die "IDLE_STOP_MINUTES must be a whole number of minutes, got '$IDLE_STOP_MINUTES'" ;;
esac

# rclone reads its S3 settings from RCLONE_S3_* variables, so no rclone.conf is
# needed. The ":s3:" path below is an on-the-fly remote built from them.
export RCLONE_S3_PROVIDER="$S3_PROVIDER"
export RCLONE_S3_ENDPOINT="$S3_ENDPOINT"
export RCLONE_S3_REGION="$S3_REGION"
export RCLONE_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export RCLONE_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export RCLONE_S3_NO_CHECK_BUCKET=true  # a read-only key cannot create buckets

SRC=":s3:${S3_BUCKET}${S3_PREFIX:+/$S3_PREFIX}"

# Fail fast on a bad endpoint, bucket, prefix or key rather than mounting an
# empty directory that Audiobookshelf would happily scan.
log "checking access to $SRC"
LISTING="$(rclone lsf --max-depth 1 --contimeout 20s --timeout 60s "$SRC")" \
  || die "cannot list $SRC. Check the endpoint, bucket, prefix and key permissions."
# S3 has no real folders, so a mistyped prefix lists as empty instead of failing.
if [ -z "$LISTING" ] && [ -n "$S3_PREFIX" ]; then
  die "prefix '$S3_PREFIX' is empty or does not exist in bucket $S3_BUCKET"
fi

mkdir -p "$MOUNT_POINT" "$CACHE_DIR"
if grep -q " $MOUNT_POINT fuse" /proc/mounts; then
  die "$MOUNT_POINT is already mounted"
fi

log "mounting $SRC at $MOUNT_POINT (read-only, cache=$VFS_CACHE_MODE, max=$VFS_CACHE_MAX_SIZE)"
rclone mount "$SRC" "$MOUNT_POINT" \
  --read-only \
  --allow-other \
  --vfs-cache-mode "$VFS_CACHE_MODE" \
  --vfs-cache-max-size "$VFS_CACHE_MAX_SIZE" \
  --cache-dir "$CACHE_DIR" \
  --dir-cache-time "$DIR_CACHE_TIME" \
  --log-level NOTICE &
RCLONE_PID=$!

# Wait for the mount to appear in /proc/mounts, or for rclone to die.
i=0
until grep -q " $MOUNT_POINT fuse" /proc/mounts; do
  kill -0 "$RCLONE_PID" 2>/dev/null || die "rclone exited before the mount came up"
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    kill "$RCLONE_PID" 2>/dev/null || true
    die "timed out waiting for $MOUNT_POINT to mount"
  fi
  sleep 1
done
log "mounted $MOUNT_POINT"

# rclone has its copy of the credentials now. Remove them from the environment
# so the application process does not inherit them.
unset RCLONE_S3_ACCESS_KEY_ID RCLONE_S3_SECRET_ACCESS_KEY S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY

# --- Cloudflare Tunnel: the app is reachable only through Cloudflare Access ---
# The Fly app has no public service. cloudflared makes an outbound connection to
# Cloudflare, which forwards requests for your hostname to http://127.0.0.1:80.
# Put a Cloudflare Access policy on that hostname so only you can open it. The
# token is read from TUNNEL_TOKEN and removed from the environment right after.
# Set CF_TUNNEL_DISABLED=1 to skip the tunnel (the local docker-compose test).
CF_PID=""
if [ "${CF_TUNNEL_DISABLED:-0}" = "1" ]; then
  log "CF_TUNNEL_DISABLED=1: not starting cloudflared"
else
  log "starting cloudflared"
  TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run &
  CF_PID=$!
  sleep 2
  kill -0 "$CF_PID" 2>/dev/null || die "cloudflared exited during startup. Check CF_TUNNEL_TOKEN."
fi
unset CF_TUNNEL_TOKEN

APP_PID=""
WATCH_PID=""
IDLE_PID=""
IDLE_FLAG=/tmp/idle-stop
rm -f "$IDLE_FLAG"

stop() {
  trap - TERM INT
  if [ -n "$WATCH_PID" ]; then kill "$WATCH_PID" 2>/dev/null || true; fi
  if [ -n "$IDLE_PID" ]; then kill "$IDLE_PID" 2>/dev/null || true; fi
  if [ -n "$APP_PID" ]; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  if [ -n "$CF_PID" ]; then kill -TERM "$CF_PID" 2>/dev/null || true; fi
  # SIGTERM makes rclone unmount cleanly before it exits.
  kill -TERM "$RCLONE_PID" 2>/dev/null || true
  wait "$RCLONE_PID" 2>/dev/null || true
}
trap 'stop; exit 143' TERM INT

log "starting: $*"
"$@" &
APP_PID=$!

# If the mount or the tunnel dies, the app is unusable. Stop it so the machine
# restarts and brings them back. This must start after APP_PID is set, because
# the subshell copies variables when it is forked.
(
  while kill -0 "$RCLONE_PID" 2>/dev/null && { [ -z "$CF_PID" ] || kill -0 "$CF_PID" 2>/dev/null; }; do
    sleep 5
  done
  log "rclone mount or cloudflared stopped; stopping the application"
  kill -TERM "$APP_PID" 2>/dev/null || true
) &
WATCH_PID=$!

# Number of established TCP connections to port 80 (cloudflared -> Audiobookshelf).
# Open pages and the socket.io websocket keep one open, so zero means nobody is
# using the app. Reads /proc, so it needs no extra tools.
active_conns() {
  cat /proc/net/tcp /proc/net/tcp6 2>/dev/null \
    | awk '$2 ~ /:0050$/ && $4 == "01" { n++ } END { print n + 0 }'
}

# Idle stop: after IDLE_STOP_MINUTES with no connections, shut down cleanly. The
# flag file makes this exit 0, so Fly's "on-failure" restart policy leaves the
# machine stopped. Wake it again with the Worker in wake/ (see README.md).
if [ "$IDLE_STOP_MINUTES" -gt 0 ]; then
  log "idle stop enabled: ${IDLE_STOP_MINUTES} min with no connections"
  (
    idle=0
    limit=$((IDLE_STOP_MINUTES * 60))
    while kill -0 "$APP_PID" 2>/dev/null; do
      sleep 15
      if [ "$(active_conns)" -eq 0 ]; then idle=$((idle + 15)); else idle=0; fi
      if [ "$idle" -ge "$limit" ]; then
        log "idle for ${IDLE_STOP_MINUTES} min; stopping the machine"
        : > "$IDLE_FLAG"
        kill -TERM "$APP_PID" 2>/dev/null || true
        exit 0
      fi
    done
  ) &
  IDLE_PID=$!
fi

status=0
wait "$APP_PID" || status=$?
log "application exited with status $status"
# An idle stop is a normal shutdown, not a failure.
if [ -e "$IDLE_FLAG" ]; then status=0; fi
stop
exit "$status"
