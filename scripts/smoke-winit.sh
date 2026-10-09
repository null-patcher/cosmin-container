#!/usr/bin/env bash
# Smoke-test cosmic-comp in the winit backend under a virtual X server.
# Runs entirely inside the dev container. Succeeds if the compositor stays
# alive for the whole duration (it is killed by `timeout`, exit 124).
set -u

COMP="${COMP:-/work/target/debug/cosmic-comp}"
SECS="${1:-12}"

export XDG_RUNTIME_DIR=/tmp/xdg-smoke
export XDG_CONFIG_HOME=/tmp/xdg-smoke/config
export XDG_DATA_HOME=/tmp/xdg-smoke/data
rm -rf "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
chmod 700 "$XDG_RUNTIME_DIR"

export COSMIC_BACKEND=winit
export LIBGL_ALWAYS_SOFTWARE=1
export RUST_BACKTRACE=1
export RUST_LOG="${RUST_LOG:-cosmic_comp=debug,info,warn}"

LOG=/tmp/smoke-winit.log
echo "running $COMP for ${SECS}s (log: $LOG)"
xvfb-run -a -s "-screen 0 1280x720x24" timeout "$SECS" "$COMP" --no-xwayland >"$LOG" 2>&1
code=$?
echo "exit code: $code"
tail -n 40 "$LOG"
if [ "$code" -eq 124 ]; then
    echo "SMOKE OK: compositor stayed alive for ${SECS}s"
    exit 0
fi
echo "SMOKE FAIL: compositor exited early"
exit 1
