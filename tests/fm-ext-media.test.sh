#!/usr/bin/env bash
# Behavior tests for outbound Discord media through the local Communication
# Officer bridge: screening, private staging under generic names, refusals,
# the real gateway poster's multipart upload, retry without a duplicate post,
# 14-day retention, and pulling a screenshot from a remote second mate.
#
# Hermetic: no Discord network. The real poster posts to a local fake Discord
# REST server through the DISCORD_API_BASE test seam, and the remote second
# mate is a fake ssh that runs the real bin/fm-remote-file.sh. Cases that need
# ffmpeg or ImageMagick report a skip line when the tool is absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
for tool in jq python3 base64; do
  tool_path=$(command -v "$tool" 2>/dev/null) || fail "test needs $tool"
  BASE_PATH="$(dirname "$tool_path"):$BASE_PATH"
done
FFMPEG_DIR=
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
  FFMPEG_DIR=$(dirname "$(command -v ffmpeg)")
  BASE_PATH="$BASE_PATH:$FFMPEG_DIR:$(dirname "$(command -v ffprobe)")"
fi
MAGICK_DIR=
if command -v magick >/dev/null 2>&1; then
  MAGICK_DIR=$(dirname "$(command -v magick)")
elif command -v convert >/dev/null 2>&1; then
  MAGICK_DIR=$(dirname "$(command -v convert)")
fi
PYTHON_BIN=$(command -v python3)
TMP_ROOT=$(fm_test_tmproot fm-ext-media)

INTAKE="$ROOT/bin/fm-ext-intake.sh"
EMIT="$ROOT/bin/fm-ext-emit.sh"
OPEN="$ROOT/bin/fm-ext-open.sh"
MEDIA="$ROOT/bin/fm-ext-media.sh"
POLL="$ROOT/bin/fm-ext-poll.sh"
PLUGIN="$ROOT/contrib/hermes-gateway-firstmate-comms"

GUILD=111111111111111111
CHANNEL=222222222222222222
THREAD=333333333333333333
AUTHOR=555555555555555555

setup_home() {
  local home=$1
  mkdir -p "$home/config" "$home/data" "$home/state"
  : > "$home/config/ext-bridge"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
}

# Firstmate's own environment: never a task worker's.
home_env() {
  local home=$1
  shift
  env -u FM_TASK_ID PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$@"
}

request_id() { printf 'discord:%s:%s:%s:%s' "$GUILD" "$CHANNEL" "$THREAD" "$1"; }

intake() {
  local home=$1 message=$2
  printf 'show me the new screen' > "$home/request.txt"
  home_env "$home" "$INTAKE" --request-id "$(request_id "$message")" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$THREAD" \
    --message-id "$message" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/request.txt" --no-wake
}

# write_png <path> [noise-bytes]: a valid PNG; noise makes it incompressible.
write_png() {
  "$PYTHON_BIN" - "$1" "${2:-0}" <<'PY'
import os, struct, sys, zlib
path, noise = sys.argv[1], int(sys.argv[2])
w = 64 if noise == 0 else max(64, int((noise / 3) ** 0.5))
h = 32 if noise == 0 else w
rows = []
for y in range(h):
    if noise:
        row = os.urandom(w * 3)
    else:
        row = bytes(v for x in range(w) for v in ((x * 4) % 256, (y * 8) % 256, 128))
    rows.append(b"\x00" + row)
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
with open(path, "wb") as handle:
    handle.write(png)
PY
}

# write_fake_mp4 <path> <bytes>: MP4 signature padded to a size, for checks
# that refuse before any decoding.
write_fake_mp4() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import sys
head = b"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2"
with open(sys.argv[1], "wb") as handle:
    handle.write(head + b"\x00" * (int(sys.argv[2]) - len(head)))
PY
}

screen() {
  local home=$1 file=$2
  home_env "$home" "$MEDIA" screen "$file" --verdict clear --reason "checked: no client data, hosts, tokens, or internal URLs" >/dev/null \
    || fail "screening $file must succeed"
}

emit_media() {  # <home> <message> <generation> <text> <media>...
  local home=$1 message=$2 generation=$3 text=$4
  shift 4
  printf '%s' "$text" > "$home/reply.txt"
  local args=()
  local file
  for file in "$@"; do args+=(--media "$file"); done
  home_env "$home" "$EMIT" --request-id "$(request_id "$message")" --kind answer \
    --generation "$generation" --text-file "$home/reply.txt" "${args[@]}"
}

slug_of() {
  printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}' \
    || printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

# A fake Discord REST edge that parses multipart bodies, then the real poster.
cat > "$TMP_ROOT/drive.py" <<'PY'
import json, os, sys, threading
from email.parser import BytesParser
from email.policy import default
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
sys.path.insert(0, os.environ["PLUGIN"])
import outbox_poster

home, mode, raw_dir = sys.argv[1], sys.argv[2], Path(sys.argv[3])
raw_dir.mkdir(parents=True, exist_ok=True)
requests = []
messages = []
lookups = []
multipart_seen = [0]

class Edge(BaseHTTPRequestHandler):
    def do_GET(self):
        lookups.append(self.path)
        reply = {"id": "777777777777777777"} if self.path.endswith("/users/@me") else ([] if mode.endswith("unmatched") else messages)
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        ctype = self.headers.get("Content-Type", "")
        (raw_dir / ("request-%d.bin" % len(requests))).write_bytes(body)
        record = {"path": self.path, "content_type": ctype.split(";")[0], "files": []}
        if ctype.startswith("multipart/form-data"):
            multipart_seen[0] += 1
            message = BytesParser(policy=default).parsebytes(
                b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + body)
            for part in message.iter_parts():
                name = part.get_param("name", header="content-disposition")
                data = part.get_payload(decode=True)
                if name == "payload_json":
                    record["json"] = json.loads(data)
                else:
                    record["files"].append({"field": name, "filename": part.get_filename(),
                                            "content_type": part.get_content_type(),
                                            "sha256": sha256(data).hexdigest(), "bytes": len(data)})
        else:
            record["json"] = json.loads(body or b"{}")
        requests.append(record)
        # fail-always-text-503: every upload is refused and the text-only
        # fallback then hits a transient 503, leaving nothing posted.
        refuse = record["files"] and (mode in ("fail-always", "fail-always-text-503")
                                      or (mode == "fail-once" and multipart_seen[0] == 1))
        if refuse:
            code, reply = (500, {"message": "upstream"}) if mode == "fail-once" else (413, {"code": 40005, "message": "Request entity too large"})
        elif mode == "fail-always-text-503":
            code, reply = 503, {"message": "upstream"}
        else:
            code = 200
            existing = next((m for m in messages if m.get("nonce") == record["json"].get("nonce")), None)
            reply = {"id": "90000000000000000%d" % len(requests), "channel_id": self.path.split("/")[-2],
                     "attachments": [{"id": str(i), "filename": f["filename"]} for i, f in enumerate(record["files"])]}
            if existing and record["json"].get("enforce_nonce"):
                reply = existing
            else:
                reply.update(content=record["json"]["content"], nonce=record["json"].get("nonce"),
                             author={"id": "777777777777777777"})
                messages.append(reply)
            if mode in ("accepted-timeout", "accepted-timeout-no-nonce", "accepted-timeout-unmatched"):
                if mode.endswith("no-nonce"):
                    reply.pop("nonce", None)
                    import time
                    reply["id"] = str((int(time.time() * 1000) - 1420070400000) << 22)
                self.close_connection = True
                return
        data = json.dumps(reply).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *_args):
        pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Edge)
threading.Thread(target=server.serve_forever, daemon=True).start()
outbox_poster.DISCORD_API_BASE = "http://127.0.0.1:%d/api/v10" % server.server_address[1]
outbox_poster.MEDIA_RETRY_DELAY_SECS = 0
result = outbox_poster.drain_outbox(home=Path(home))
if mode.startswith("accepted-timeout"):
    payload = next(Path(home, "state/ext-outbox").glob("*.answer.1.json"))
    identity = json.loads(payload.read_text())
    import time
    outbox_poster.release_inflight(identity, Path(home))
    os.environ["FM_EXT_NOW_OVERRIDE"] = str(int(time.time()) + 600)
    result += outbox_poster.drain_outbox(home=Path(home))
server.shutdown()
print(json.dumps({"result": result, "requests": requests, "messages": messages, "lookups": lookups}))
PY

drive() {  # <home> <mode> -> JSON {result, requests}
  home_env "$1" env DISCORD_BOT_TOKEN=test-bot-token PLUGIN="$PLUGIN" \
    "$PYTHON_BIN" "$TMP_ROOT/drive.py" "$1" "$2" "$1/raw-requests" 2>/dev/null
}

# --- 1. workers and homes without the bridge cannot screen or post ----------

test_1_worker_and_inactive_home_refused() {
  local home out rc
  home="$TMP_ROOT/c1"
  setup_home "$home"
  intake "$home" 410000000000000001 >/dev/null
  mkdir -p "$home/data/shots"
  write_png "$home/data/shots/screen.png"
  out=$(env FM_TASK_ID=some-task PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$MEDIA" screen "$home/data/shots/screen.png" --verdict clear --reason "looked" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a task worker must not record a screening attestation"
  assert_contains "$out" "only Firstmate screens and posts media" "worker refusal must say why"
  screen "$home" "$home/data/shots/screen.png"
  printf 'Here it is.' > "$home/reply.txt"
  out=$(env FM_TASK_ID=some-task PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$EMIT" --request-id "$(request_id 410000000000000001)" --kind answer --generation 1 \
    --text-file "$home/reply.txt" --media "$home/data/shots/screen.png" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a task worker must not post media"
  [ -z "$(find "$home/state/ext-outbox" -name '*.answer.1.json' 2>/dev/null)" ] \
    || fail "a refused worker emit must publish nothing"

  home="$TMP_ROOT/c1-off"
  mkdir -p "$home/data" "$home/state" "$home/config"
  write_png "$home/data/screen.png"
  home_env "$home" "$MEDIA" screen "$home/data/screen.png" --verdict clear --reason looked >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "screening in a home without the bridge"
  [ -z "$(find "$home/state" -mindepth 1 2>/dev/null)" ] \
    || fail "a home that never opted in must gain no media state"
  pass "1 task workers and homes without the bridge cannot screen or post media"
}

# --- 2. unscreened files never post; screened ones stage privately ---------

test_2_unscreened_refused_screened_staged() {
  local home slug out rc payload dir staged src
  home="$TMP_ROOT/c2"
  setup_home "$home"
  slug=$(intake "$home" 420000000000000001)
  mkdir -p "$home/data/acme-task-42/artifacts"
  src="$home/data/acme-task-42/artifacts/fm-acme-42-branch-after.png"
  write_png "$src"
  out=$(emit_media "$home" 420000000000000001 1 "The new screen is up." "$src" 2>&1)
  rc=$?
  expect_code 2 "$rc" "emitting an unscreened file"
  assert_contains "$out" "not screened" "the refusal must name the missing screening"
  [ ! -e "$home/state/ext-outbox/$slug.answer.1.json" ] || fail "an unscreened file must publish no payload"
  [ -z "$(find "$home/state/ext-media/staged" -mindepth 1 2>/dev/null)" ] \
    || fail "an unscreened file must leave nothing staged"

  screen "$home" "$src"
  out=$(emit_media "$home" 420000000000000001 1 "See fm-acme-42-branch-after.png for it." "$src" 2>&1)
  rc=$?
  expect_code 2 "$rc" "text that names the media file"
  assert_contains "$out" "names a media file" "the text must not name the file"

  emit_media "$home" 420000000000000001 1 "The new screen is up." "$src" >/dev/null \
    || fail "a screened file must emit"
  payload="$home/state/ext-outbox/$slug.answer.1.json"
  jq -e '.media.files | length == 1 and .[0].name == "image-1.png" and .[0].media == "image"' "$payload" >/dev/null \
    || fail "the payload must carry one generic image name: $(jq -c .media "$payload")"
  if grep -q 'acme' "$payload"; then fail "the payload must not carry the source path or filename"; fi
  dir=$(jq -r '.media.dir' "$payload")
  staged="$home/state/ext-media/staged/$dir"
  [ "$(file_mode "$staged")" = 700 ] || fail "the staged folder must be mode 0700"
  [ "$(file_mode "$staged/image-1.png")" = 600 ] || fail "the staged copy must be mode 0600"
  cmp -s "$src" "$staged/image-1.png" || fail "an in-limit image must stage byte for byte"
  pass "2 unscreened media is refused and screened media stages privately under a generic name"
}

# --- 3. out-of-tree, symlinked, unsupported, over-count, refused, oversized -

test_3_refusals() {
  local home message=430000000000000001 out rc i shots
  home="$TMP_ROOT/c3"
  setup_home "$home"
  intake "$home" "$message" >/dev/null
  shots="$home/data/shots"
  mkdir -p "$shots" "$TMP_ROOT/outside"
  write_png "$TMP_ROOT/outside/screen.png"
  write_png "$shots/real.png"
  screen "$home" "$shots/real.png"

  expect_refusal() {  # <needle> <label> <media>...
    local needle=$1 label=$2
    shift 2
    out=$(emit_media "$home" "$message" 1 "Screens." "$@" 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "$label must be refused"
    assert_contains "$out" "$needle" "$label refusal must be clear (got: $out)"
  }

  expect_refusal "must come from this home's data/ or state/" "an out-of-tree file" "$TMP_ROOT/outside/screen.png"
  ln -s "$shots/real.png" "$shots/link.png"
  expect_refusal "symlinked" "a symlinked file" "$shots/link.png"
  ln -s "$shots" "$home/data/linked-dir"
  expect_refusal "symlinked" "a file under a symlinked folder" "$home/data/linked-dir/real.png"
  expect_refusal "must not contain" "a path with .. components" "$home/data/shots/../shots/real.png"
  printf 'not an image\n' > "$shots/notes.png"
  expect_refusal "unsupported media type" "a non-media file" "$shots/notes.png"
  for i in 1 2 3 4 5; do cp "$shots/real.png" "$shots/copy-$i.png"; done
  expect_refusal "at most 4 images and 1 video" "six files" \
    "$shots/copy-1.png" "$shots/copy-2.png" "$shots/copy-3.png" "$shots/copy-4.png" "$shots/copy-5.png" "$shots/real.png"
  expect_refusal "at most 4 images" "five images" \
    "$shots/copy-1.png" "$shots/copy-2.png" "$shots/copy-3.png" "$shots/copy-4.png" "$shots/copy-5.png"
  write_fake_mp4 "$shots/one.mp4" 4096
  write_fake_mp4 "$shots/two.mp4" 4097
  expect_refusal "at most 1 video" "two videos" "$shots/one.mp4" "$shots/two.mp4"
  write_fake_mp4 "$shots/big.mp4" 12000000
  expect_refusal "over the 10000000-byte limit; videos are never re-encoded" "an oversized video" "$shots/big.mp4"
  write_png "$shots/private.png" 3000
  home_env "$home" "$MEDIA" screen "$shots/private.png" --verdict refused \
    --reason "shows a customer's name" >/dev/null || fail "recording a refused verdict must work"
  expect_refusal "screened and refused" "a screened-and-refused file" "$shots/private.png"
  printf 'Screens.' > "$home/reply.txt"
  out=$(home_env "$home" "$EMIT" --request-id "$(request_id "$message")" --kind ack --generation 1 \
    --text-file "$home/reply.txt" --media "$shots/real.png" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "media on an ack must be refused"
  assert_contains "$out" "answer, followup, or final" "the ack refusal must be clear"
  [ -z "$(find "$home/state/ext-outbox" -name '*.json' 2>/dev/null)" ] \
    || fail "refused emits must publish nothing"
  [ -z "$(find "$home/state/ext-media/staged" -mindepth 1 2>/dev/null)" ] \
    || fail "refused emits must leave nothing staged"
  mkdir -p "$home/data/real-shots"
  write_png "$home/data/real-shots/a.png"
  ln -s real-shots "$home/data/linked-shots"
  if home_env "$home" "$MEDIA" screen "$home/data/linked-shots/a.png" --verdict clear --reason looked >/dev/null 2>&1; then
    fail "a symlinked source parent must be refused"
  fi
  mv "$home/data" "$home/data-real"
  ln -s data-real "$home/data"
  if home_env "$home" "$MEDIA" screen "$home/data/real-shots/a.png" --verdict clear --reason looked >/dev/null 2>&1; then
    fail "a symlinked data root must be refused"
  fi
  rm "$home/data"
  mv "$home/data-real" "$home/data"
  write_png "$home/state/a.png"
  mv "$home/state" "$home/state-real"
  ln -s state-real "$home/state"
  if home_env "$home" "$MEDIA" screen "$home/state/a.png" --verdict clear --reason looked >/dev/null 2>&1; then
    fail "a symlinked state root must be refused"
  fi
  rm "$home/state"
  mv "$home/state-real" "$home/state"
  pass "3 out-of-tree, symlinked, unsupported, over-count, refused, and oversized-video media are refused"
}

# --- 4. an oversized image is downscaled under the limit --------------------

test_4_oversized_image_downscaled() {
  local home slug payload staged bytes
  if [ -z "$MAGICK_DIR" ]; then
    pass "4 skip: ImageMagick not installed, oversized-image downscale not exercised"
    return 0
  fi
  home="$TMP_ROOT/c4"
  setup_home "$home"
  slug=$(intake "$home" 440000000000000001)
  mkdir -p "$home/data/shots"
  write_png "$home/data/shots/large.png" 40000000
  [ "$(wc -c < "$home/data/shots/large.png" | tr -d ' ')" -gt 33554432 ] || fail "the fixture must be large"
  screen "$home" "$home/data/shots/large.png"
  printf 'Big screen.' > "$home/reply.txt"
  env -u FM_TASK_ID PATH="$BASE_PATH:$MAGICK_DIR" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$EMIT" --request-id "$(request_id 440000000000000001)" \
    --kind answer --generation 1 --text-file "$home/reply.txt" --media "$home/data/shots/large.png" >/dev/null \
    || fail "an oversized image must be downscaled, not refused"
  payload="$home/state/ext-outbox/$slug.answer.1.json"
  staged="$home/state/ext-media/staged/$(jq -r '.media.dir' "$payload")/image-1.png"
  bytes=$(wc -c < "$staged" | tr -d ' ')
  [ "$bytes" -le 10000000 ] || fail "the downscaled image must fit the limit (got $bytes)"
  head -c 8 "$staged" | od -An -c | grep -q 'P   N   G' || fail "the downscaled image must stay a PNG"
  jq -e '.media.files[0] | .sha256 != .screened_sha256' "$payload" >/dev/null \
    || fail "a downscaled copy must record both its own digest and the screened digest"
  pass "4 an oversized image is downscaled under the limit and stays the same type"
}

# --- 5. the real poster uploads multipart with the text ---------------------

test_5_poster_multipart_upload() {
  local home slug out receipt raw png_sha
  home="$TMP_ROOT/c5"
  setup_home "$home"
  slug=$(intake "$home" 450000000000000001)
  mkdir -p "$home/data/fm-acme-77/artifacts"
  write_png "$home/data/fm-acme-77/artifacts/before-login.png"
  write_png "$home/data/fm-acme-77/artifacts/after-login.png" 2000
  screen "$home" "$home/data/fm-acme-77/artifacts/before-login.png"
  screen "$home" "$home/data/fm-acme-77/artifacts/after-login.png"
  emit_media "$home" 450000000000000001 1 "Login screen: before and after." \
    "$home/data/fm-acme-77/artifacts/before-login.png" "$home/data/fm-acme-77/artifacts/after-login.png" >/dev/null \
    || fail "emit with two screened images must succeed"
  out=$(drive "$home" ok)
  printf '%s' "$out" | jq -e '.result == ["sent"] and (.requests | length) == 1' >/dev/null \
    || fail "one post must carry the text and both images (got: $out)"
  printf '%s' "$out" | jq -e --arg thread "$THREAD" '.requests[0]
    | .path == "/api/v10/channels/\($thread)/messages"
    and .content_type == "multipart/form-data"
    and .json.content == "Login screen: before and after."
    and ([.json.attachments[].filename] == ["image-1.png", "image-2.png"])
    and ([.files[].field] == ["files[0]", "files[1]"])
    and ([.files[].filename] == ["image-1.png", "image-2.png"])
    and ([.files[].content_type] == ["image/png", "image/png"])' >/dev/null \
    || fail "the upload must be one Discord multipart message with generic names (got: $out)"
  png_sha=$(sha256sum "$home/data/fm-acme-77/artifacts/before-login.png" 2>/dev/null | awk '{print $1}')
  printf '%s' "$out" | jq -e --arg sha "$png_sha" '.requests[0].files[0].sha256 == $sha' >/dev/null \
    || fail "the uploaded bytes must be the screened bytes"
  for raw in "$home"/raw-requests/request-*.bin; do
    if grep -a -q -e 'acme' -e 'login' -e "$home" "$raw"; then
      fail "no source path or filename may reach Discord"
    fi
  done
  receipt="$home/state/ext-outbox/$slug.answer.1.receipt.json"
  jq -e '(.attachments | map(.name)) == ["image-1.png", "image-2.png"]
    and .attachments_dropped == [] and .media_note == false and .media_upload_attempts == 1' "$receipt" >/dev/null \
    || fail "the receipt must record the posted attachments (got: $(cat "$receipt"))"
  out=$(drive "$home" ok)
  printf '%s' "$out" | jq -e '(.requests | length) == 0' >/dev/null \
    || fail "a delivered post must never post again (got: $out)"
  pass "5 the real poster uploads screened media as one multipart post and records it in the receipt"
}

# --- 6. one retry, never a duplicate; failure posts the text with a note ----

test_6_retry_once_then_note() {
  local home slug out receipt mode
  home="$TMP_ROOT/c6"
  setup_home "$home"
  slug=$(intake "$home" 460000000000000001)
  mkdir -p "$home/data/shots"
  write_png "$home/data/shots/a.png"
  screen "$home" "$home/data/shots/a.png"
  emit_media "$home" 460000000000000001 1 "Retry case." "$home/data/shots/a.png" >/dev/null || fail "emit must succeed"
  out=$(drive "$home" fail-once)
  printf '%s' "$out" | jq -e '.result == ["sent"] and (.requests | length) == 2
    and ([.requests[].content_type] == ["multipart/form-data", "multipart/form-data"])
    and .requests[1].json.content == "Retry case."' >/dev/null \
    || fail "a refused upload must be retried exactly once with the same post (got: $out)"
  receipt="$home/state/ext-outbox/$slug.answer.1.receipt.json"
  jq -e '(.attachments | map(.name)) == ["image-1.png"] and .media_upload_attempts == 2 and .media_note == false
    and (.discord_message_ids | length) == 1' "$receipt" >/dev/null \
    || fail "the retried upload must post once (got: $(cat "$receipt"))"

  home="$TMP_ROOT/c6b"
  setup_home "$home"
  slug=$(intake "$home" 460000000000000002)
  mkdir -p "$home/data/shots"
  write_png "$home/data/shots/a.png"
  screen "$home" "$home/data/shots/a.png"
  emit_media "$home" 460000000000000002 1 "Upload keeps failing." "$home/data/shots/a.png" >/dev/null || fail "emit must succeed"
  out=$(drive "$home" fail-always)
  printf '%s' "$out" | jq -e '.result == ["sent"] and (.requests | length) == 3
    and ([.requests[].content_type] == ["multipart/form-data", "multipart/form-data", "application/json"])
    and .requests[2].json.content == "Upload keeps failing.\n\n_(screenshot couldn'"'"'t be posted)_"' >/dev/null \
    || fail "after one retry the text must post alone with the note (got: $out)"
  receipt="$home/state/ext-outbox/$slug.answer.1.receipt.json"
  jq -e '.attachments == [] and .attachments_dropped == ["image-1.png"] and .media_note == true
    and .media_upload_attempts == 2 and (.discord_message_ids | length) == 1' "$receipt" >/dev/null \
    || fail "the receipt must record the dropped upload (got: $(cat "$receipt"))"
  out=$(drive "$home" ok)
  printf '%s' "$out" | jq -e '(.requests | length) == 0' >/dev/null \
    || fail "a delivered post must never post again (got: $out)"

  # The one retry is per post, not per delivery attempt: when both uploads are
  # refused and the text-only fallback then fails transiently with nothing
  # posted, the next drain posts the text with the note and uploads nothing.
  home="$TMP_ROOT/c6c"
  setup_home "$home"
  slug=$(intake "$home" 460000000000000003)
  mkdir -p "$home/data/shots"
  write_png "$home/data/shots/a.png"
  screen "$home" "$home/data/shots/a.png"
  emit_media "$home" 460000000000000003 1 "Upload and text both fail." "$home/data/shots/a.png" >/dev/null \
    || fail "emit must succeed"
  out=$(drive "$home" fail-always-text-503)
  printf '%s' "$out" | jq -e '.result == ["failed"]
    and ([.requests[].content_type] == ["multipart/form-data", "multipart/form-data", "application/json"])' >/dev/null \
    || fail "two refused uploads and a refused text must leave the post pending (got: $out)"
  out=$(drive "$home" ok)
  printf '%s' "$out" | jq -e '.result == ["sent"] and (.requests | length) == 1
    and .requests[0].content_type == "application/json"
    and .requests[0].json.content == "Upload and text both fail.\n\n_(screenshot couldn'"'"'t be posted)_"' >/dev/null \
    || fail "a later drain must post the text with the note and never upload a third time (got: $out)"
  receipt="$home/state/ext-outbox/$slug.answer.1.receipt.json"
  jq -e '.attachments == [] and .attachments_dropped == ["image-1.png"] and .media_note == true
    and .media_upload_attempts == 2 and (.discord_message_ids | length) == 1' "$receipt" >/dev/null \
    || fail "the receipt must count both uploads across drains (got: $(cat "$receipt"))"
  for mode in accepted-timeout accepted-timeout-no-nonce accepted-timeout-unmatched; do
    home="$TMP_ROOT/c6-$mode"
    setup_home "$home"
    slug=$(intake "$home" 460000000000000004)
    mkdir -p "$home/data/shots"
    write_png "$home/data/shots/a.png"
    screen "$home" "$home/data/shots/a.png"
    emit_media "$home" 460000000000000004 1 "Accepted then timeout." "$home/data/shots/a.png" >/dev/null
    out=$(drive "$home" "$mode")
    if [ "$mode" = accepted-timeout-unmatched ]; then
      printf '%s' "$out" | jq -e '.result == ["mid-delivery", "mid-delivery"]
        and (.requests | length) == 1 and (.messages | length) == 1' >/dev/null \
        || fail "an inconclusive lookup must never resend or post fallback text (got: $out)"
      [ ! -e "$home/state/ext-outbox/$slug.answer.1.receipt.json" ] \
        || fail "unresolved delivery must not fabricate a receipt"
      continue
    fi
    printf '%s' "$out" | jq -e '.result == ["mid-delivery", "sent"]
      and (.requests | length) == 1 and (.messages | length) == 1
      and (.lookups | length) == 2
      and .requests[0].json.enforce_nonce == true
      and (.requests[0].json.nonce | length) <= 25' >/dev/null \
      || fail "an accepted upload with a lost response must recover without another send (got: $out)"
    jq -e '.media_upload_attempts == 1 and (.attachments | length) == 1
      and (.discord_message_ids | length) == 1 and .media_note == false' \
      "$home/state/ext-outbox/$slug.answer.1.receipt.json" >/dev/null \
      || fail "recovery must record the accepted media receipt"
  done
  pass "6 a refused upload is retried once per post, even across drains, then the text posts alone with a note, never twice"
}

# --- 7. a file whose verdict turned refused after emit does not upload ------

test_7_revoked_screening_not_uploaded() {
  local home slug out
  home="$TMP_ROOT/c7"
  setup_home "$home"
  slug=$(intake "$home" 470000000000000001)
  mkdir -p "$home/data/shots"
  write_png "$home/data/shots/a.png"
  screen "$home" "$home/data/shots/a.png"
  emit_media "$home" 470000000000000001 1 "Revoked." "$home/data/shots/a.png" >/dev/null || fail "emit must succeed"
  home_env "$home" "$MEDIA" screen "$home/data/shots/a.png" --verdict refused --reason "second look found a hostname" >/dev/null \
    || fail "a new verdict must replace the old one"
  out=$(drive "$home" ok)
  printf '%s' "$out" | jq -e '(.requests | length) == 1 and .requests[0].content_type == "application/json"
    and (.requests[0].json.content | endswith("couldn'"'"'t be posted)_"))' >/dev/null \
    || fail "a file refused after emit must not upload (got: $out)"
  jq -e '.attachments_dropped == ["image-1.png"]' "$home/state/ext-outbox/$slug.answer.1.receipt.json" >/dev/null \
    || fail "the receipt must name the dropped file"
  pass "7 a file whose screening turned refused after emit is never uploaded"
}

# --- 8. staged media is kept while pending and deleted 14 days after posting

test_8_retention() {
  local home slug pending_slug dir pending_dir now attestation
  home="$TMP_ROOT/c8"
  setup_home "$home"
  slug=$(intake "$home" 480000000000000001)
  pending_slug=$(intake "$home" 480000000000000002)
  mkdir -p "$home/data/shots"
  write_png "$home/data/shots/a.png"
  screen "$home" "$home/data/shots/a.png"
  emit_media "$home" 480000000000000001 1 "Posted." "$home/data/shots/a.png" >/dev/null || fail "emit must succeed"
  dir=$(find "$home/state/ext-media/staged" -maxdepth 1 -name "$slug.answer.1.*")
  [ -d "$dir" ] || fail "the first post must stage its media"
  # Staged long ago: the window counts from posting, not staging.
  touch -d '@1000000000' "$dir" 2>/dev/null || touch -t 200109090146 "$dir"
  drive "$home" ok >/dev/null
  [ -e "$home/state/ext-outbox/$slug.answer.1.receipt.json" ] || fail "the first post must have a receipt"
  # A second post stays queued: no poster runs after it.
  emit_media "$home" 480000000000000002 1 "Waiting." "$home/data/shots/a.png" >/dev/null || fail "emit must succeed"
  pending_dir=$(find "$home/state/ext-media/staged" -maxdepth 1 -name "$pending_slug.answer.1.*")
  [ -d "$pending_dir" ] || fail "the queued post must stage its media"
  attestation=$(find "$home/state/ext-media/screened" -name '*.json')
  now=$(date +%s)
  home_env "$home" env FM_EXT_PRUNE_INTERVAL_SECS=0 FM_EXT_NOW_OVERRIDE=$((now + 13 * 86400)) "$POLL" >/dev/null 2>&1
  [ -d "$dir" ] || fail "staged media must survive 13 days after posting"
  [ -e "$attestation" ] || fail "an attestation must survive 13 days"
  home_env "$home" env FM_EXT_PRUNE_INTERVAL_SECS=0 FM_EXT_NOW_OVERRIDE=$((now + 15 * 86400)) "$POLL" >/dev/null 2>&1
  [ ! -e "$dir" ] || fail "staged media must be deleted 14 days after posting"
  [ ! -e "$attestation" ] || fail "an attestation must be deleted after 14 days"
  [ -d "$pending_dir" ] || fail "staged media of a still-pending post must never be deleted"
  pass "8 staged media is kept while its post is pending and deleted 14 days after posting"
}

# --- 9. video: frames are sampled before screening; length is enforced -----

test_9_video_frames_and_length() {
  local home slug out rc frames payload
  if [ -z "$FFMPEG_DIR" ]; then
    pass "9 skip: ffmpeg not installed, video sampling not exercised"
    return 0
  fi
  home="$TMP_ROOT/c9"
  setup_home "$home"
  slug=$(intake "$home" 490000000000000001)
  mkdir -p "$home/data/rec"
  ffmpeg -nostdin -v error -f lavfi -i testsrc=duration=2:size=160x120:rate=10 -pix_fmt yuv420p "$home/data/rec/clip.mp4" \
    || fail "ffmpeg must make the fixture"
  out=$(home_env "$home" "$MEDIA" screen "$home/data/rec/clip.mp4" --verdict clear --reason looked 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a video must not be screened before its frames are sampled"
  assert_contains "$out" "sample this video's frames first" "the refusal must point at frame sampling"
  frames=$(home_env "$home" "$MEDIA" frames "$home/data/rec/clip.mp4") || fail "frame sampling must work"
  [ "$(printf '%s\n' "$frames" | grep -c 'frame-.*\.png$')" -ge 4 ] || fail "at least 4 frames must be sampled (got: $frames)"
  while IFS= read -r frame; do
    head -c 8 "$frame" | od -An -c | grep -q 'P   N   G' || fail "each sampled frame must be a PNG"
  done <<EOF
$frames
EOF
  screen "$home" "$home/data/rec/clip.mp4"
  emit_media "$home" 490000000000000001 1 "Short recording." "$home/data/rec/clip.mp4" >/dev/null \
    || fail "a screened short video must emit"
  payload="$home/state/ext-outbox/$slug.answer.1.json"
  jq -e '.media.files[0] | .name == "video-1.mp4" and .media_type == "video/mp4"' "$payload" >/dev/null \
    || fail "the video must stage as video-1.mp4"
  ffmpeg -nostdin -v error -f lavfi -i testsrc=duration=31:size=64x48:rate=2 -pix_fmt yuv420p "$home/data/rec/long.mp4" \
    || fail "ffmpeg must make the long fixture"
  out=$(home_env "$home" "$MEDIA" frames "$home/data/rec/long.mp4" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a video longer than 30 seconds must be refused"
  assert_contains "$out" "at most 30s" "the length refusal must be clear"
  pass "9 video frames are sampled before screening and videos over 30 seconds are refused"
}

# --- 10. screenshots copy back from a remote second mate in bounded pieces --

test_10_remote_pull() {
  local home remote out rc pulled log operation
  local -a args=()
  home="$TMP_ROOT/c10"
  remote="$TMP_ROOT/c10-remote"
  setup_home "$home"
  mkdir -p "$remote/data/ios-task/artifacts" "$TMP_ROOT/c10-bin"
  "$PYTHON_BIN" - "$remote/data/ios-task/artifacts/after.png" <<'PY'
import os, sys
with open(sys.argv[1], "wb") as handle:
    handle.write(b"\x89PNG\r\n\x1a\n" + os.urandom(2 * 1024 * 1024))
PY
  printf -- '- macmate - Mac delivery (host: remote-mac; root: /opt/firstmate; home: %s; scope: iOS work; projects: alpha; added 2026-10-22)\n' \
    "$remote" > "$home/data/secondmates.md"
  log="$TMP_ROOT/c10-ssh.log"
  cat > "$TMP_ROOT/c10-bin/fake-ssh" <<'PY'
#!/usr/bin/env python3
import base64, os, sys
args = sys.argv[1:]
while args and args[0] == "-o":
    args = args[2:]
if args[:1] == ["--"]:
    args = args[1:]
host, entry, _protocol, _root, home_b64, argv_b64 = args
if host != "remote-mac" or entry != "fm-remote-entrypoint.sh":
    sys.exit(91)
argv = [part.decode() for part in base64.b64decode(argv_b64).split(b"\0")[:-1]]
with open(os.environ["FM_FAKE_SSH_LOG"], "a") as log:
    log.write(" ".join(argv) + "\n")
command = os.path.join(os.environ["FM_FAKE_REMOTE_BIN"], argv[0])
os.execve(command, [command] + argv[1:],
          {"FM_HOME": base64.b64decode(home_b64).decode(), "PATH": os.environ["PATH"]})
PY
  chmod +x "$TMP_ROOT/c10-bin/fake-ssh"
  pull() {
    home_env "$home" env FM_SSH_BIN="$TMP_ROOT/c10-bin/fake-ssh" FM_FAKE_SSH_LOG="$log" \
      FM_FAKE_REMOTE_BIN="$ROOT/bin" "$MEDIA" pull "$@"
  }
  pulled=$(pull macmate data/ios-task/artifacts/after.png) || fail "pulling a screenshot must work"
  case "$pulled" in
    "$home/state/ext-media/pulled/macmate/"*.png) ;;
    *) fail "the copy must land in this home's state tree (got: $pulled)" ;;
  esac
  cmp -s "$pulled" "$remote/data/ios-task/artifacts/after.png" || fail "the copy must match the remote file byte for byte"
  [ "$(file_mode "$pulled")" = 600 ] || fail "the copy must be mode 0600"
  [ "$(grep -c '^fm-remote-file.sh sum ' "$log")" = 1 ] || fail "the pull must size and hash the file once"
  [ "$(grep -c '^fm-remote-file.sh get ' "$log")" = 3 ] || fail "a 2 MiB file must come back in three bounded pieces"
  for bad in config/ext-secret data/notes.md data/../config/x.png /etc/passwd.png; do
    out=$(pull macmate "$bad" 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "pulling $bad must be refused"
  done
  ln -s ios-task "$remote/data/linked"
  for operation in sum get; do
    args=(sum data/linked/artifacts/after.png 0)
    [ "$operation" = sum ] || args=(get data/linked/artifacts/after.png 0 0 1024)
    if FM_HOME="$remote" "$ROOT/bin/fm-remote-file.sh" "${args[@]}" >/dev/null 2>&1; then
      fail "remote $operation must reject a symlinked parent"
    fi
  done
  mv "$remote/data" "$remote/data-real"
  ln -s data-real "$remote/data"
  for operation in sum get; do
    args=(sum data/ios-task/artifacts/after.png 0)
    [ "$operation" = sum ] || args=(get data/ios-task/artifacts/after.png 0 0 1024)
    if FM_HOME="$remote" "$ROOT/bin/fm-remote-file.sh" "${args[@]}" >/dev/null 2>&1; then
      fail "remote $operation must reject a symlinked data root"
    fi
  done
  rm "$remote/data"
  mv "$remote/data-real" "$remote/data"
  cp "$remote/data/ios-task/artifacts/after.png" "$remote/data/large.png"
  "$PYTHON_BIN" - "$remote/data/large.png" <<'PY_SIZE'
import sys
with open(sys.argv[1], "r+b") as stream:
    stream.truncate(40000000)
PY_SIZE
  out=$(FM_HOME="$remote" "$ROOT/bin/fm-remote-file.sh" sum data/large.png 0) \
    || fail "remote image checksums must have no source byte cap"
  [ "${out%% *}" = 40000000 ] || fail "the remote checksum must cover the entire large image"
  FM_HOME="$remote" "$ROOT/bin/fm-remote-file.sh" get data/large.png 0 33554432 1024 > "$home/range"
  [ "$(wc -c < "$home/range" | tr -d ' ')" = 1024 ] || fail "large images must support bounded reads beyond 32 MiB"
  intake "$home" 500000000000000001 >/dev/null
  screen "$home" "$pulled"
  emit_media "$home" 500000000000000001 1 "From the Mac." "$pulled" >/dev/null \
    || fail "a pulled and screened screenshot must post like a local one"
  pass "10 a remote second mate's screenshot copies back in bounded pieces and posts like local media"
}

# --- 11. a new review thread opens with its screenshots attached ------------

test_11_open_review_thread_with_media() {
  local home rid slug out rc
  home="$TMP_ROOT/c11"
  setup_home "$home"
  printf '%s\n' "$CHANNEL" > "$home/config/ext-channel"
  mkdir -p "$home/data/shots"
  write_png "$home/data/shots/after.png"
  printf 'Alpha login screen, ready for review.' > "$home/open.txt"
  out=$(home_env "$home" "$OPEN" --key review-alpha-login --thread-title "Alpha · login review" \
    --text-file "$home/open.txt" --media "$home/data/shots/after.png" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "opening a thread with unscreened media must be refused"
  assert_contains "$out" "not screened" "the open refusal must name the missing screening"
  screen "$home" "$home/data/shots/after.png"
  rid=$(home_env "$home" "$OPEN" --key review-alpha-login --thread-title "Alpha · login review" \
    --text-file "$home/open.txt" --media "$home/data/shots/after.png") || fail "a screened review thread must open"
  slug=$(slug_of "$rid")
  jq -e '.origin == "open" and .thread_title == "Alpha · login review"
    and (.media.files | map(.name)) == ["image-1.png"]' "$home/state/ext-outbox/$slug.answer.1.json" >/dev/null \
    || fail "the opened thread's first message must carry the screenshot"
  pass "11 a new review thread opens with its screened screenshots attached"
}

test_1_worker_and_inactive_home_refused
test_2_unscreened_refused_screened_staged
test_3_refusals
test_4_oversized_image_downscaled
test_5_poster_multipart_upload
test_6_retry_once_then_note
test_7_revoked_screening_not_uploaded
test_8_retention
test_9_video_frames_and_length
test_10_remote_pull
test_11_open_review_thread_with_media
