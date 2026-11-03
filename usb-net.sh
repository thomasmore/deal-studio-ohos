#!/usr/bin/env bash
# Gives the whole phone this computer's internet over the USB cable, for the
# app's "USB network" switch (Generate > Settings > Advanced). Runs the
# gnirehtet relay here (needs java) and maps the phone's 127.0.0.1:28416 to it
# with `hdc rport`, re-adding the mapping when the phone is replugged.
# Stop with Ctrl-C; the phone's VPN then waits and resumes when this runs again.
#
#   ./usb-net.sh
#   VERA_PHONE=<serial> ./usb-net.sh   # when several devices are attached
set -euo pipefail
cd "$(dirname "$0")"
source ./tool-paths.sh

PORT=31416        # the relay, here
PHONE_PORT=28416  # on the phone; 31150-31950 is reserved there
HDC="$(vera_hdc_dir)/hdc"
JAR=tools/gnirehtet/gnirehtet.jar

command -v java >/dev/null || { echo "ERROR: java not found (the relay needs a JRE)" >&2; exit 1; }

# A second copy must not start: its exit would remove the first one's mapping.
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  echo "ERROR: 127.0.0.1:$PORT is already in use -- is usb-net.sh already running?" >&2
  exit 1
fi

java -jar "$JAR" relay -p "$PORT" &
relay=$!
cleanup() {
  kill "$relay" 2>/dev/null || true
  "$HDC" fport rm "tcp:$PHONE_PORT" "tcp:$PORT" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM

echo "relay on 127.0.0.1:$PORT; Ctrl-C to stop"
mapped=""
told_many=""
last_err=""
# hdc's output is read into variables before grepping: with pipefail, `hdc ... |
# grep -q` can fail when grep stops early and hdc gets SIGPIPE.
while kill -0 "$relay" 2>/dev/null; do
  targets="$("$HDC" list targets 2>/dev/null || true)"
  targets="$(grep -v -e '^\[Empty\]$' -e '^$' <<<"$targets" || true)"
  serial=""
  if [ -n "${VERA_PHONE:-}" ]; then
    if grep -qxF "$VERA_PHONE" <<<"$targets"; then serial="$VERA_PHONE"; fi
  elif [ "$(grep -c . <<<"$targets" || true)" = 1 ]; then
    serial="$targets"
  elif [ -n "$targets" ] && [ -z "$told_many" ]; then
    echo "several devices attached; run again with VERA_PHONE set to one of: $(tr '\n' ' ' <<<"$targets")" >&2
    told_many=1
  fi
  if [ -z "$serial" ]; then
    [ -z "$mapped" ] || { echo "phone gone, waiting"; mapped=""; }
    sleep 2
    continue
  fi
  maps="$("$HDC" fport ls 2>/dev/null || true)"
  if grep -q "$serial.*tcp:$PHONE_PORT tcp:$PORT" <<<"$maps"; then
    [ -n "$mapped" ] || { echo "phone connected"; mapped=1; }
  else
    out="$("$HDC" -t "$serial" rport "tcp:$PHONE_PORT" "tcp:$PORT" 2>&1 || true)"
    if grep -q "result:OK" <<<"$out"; then
      echo "phone 127.0.0.1:$PHONE_PORT -> relay"; mapped=1
    elif [ "$last_err" != "$out" ]; then
      echo "hdc rport: $out" >&2; last_err="$out"
    fi
  fi
  sleep 2
done
echo "ERROR: the relay exited" >&2
exit 1
