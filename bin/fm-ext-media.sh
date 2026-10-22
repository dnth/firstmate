#!/usr/bin/env bash
# Screen, stage, verify, and pull outbound Discord media for the local
# Communication Officer bridge.
#
# Usage:
#   fm-ext-media.sh frames <video>
#   fm-ext-media.sh screen <file> --verdict clear|refused --reason <text>
#   fm-ext-media.sh pull <secondmate-id> <remote-relative-path>
#   fm-ext-media.sh stage --slug <slug> --kind answer|followup|final
#     --generation <n> <file>...
#   fm-ext-media.sh verify --payload <outbox-payload>
#
# Only Firstmate posts media, by attaching files to its own outbox posts with
# bin/fm-ext-emit.sh --media (or bin/fm-ext-open.sh --media). Every subcommand
# refuses inside an fm-spawn task worker's environment (FM_TASK_ID) and while
# the local bridge is inactive; workers save screenshots as evidence instead.
#
# Accepted sources. A media path must name a regular file inside this home's
# data/ or state/ tree, or inside the .qa/evidence/ folder of a ship or scout
# task worktree this home records (worktree= in state/<id>.meta). Paths with
# "." or ".." components, a symlink at any component of the source path, and
# anything outside those roots are refused. A source is read once through a
# no-follow copy, and every check runs on that private copy. Videos have a
# 32 MiB source cap; images are bounded by ImageMagick resources when decoded.
#
# Types come from file contents, never the name: PNG, JPEG, GIF, and WebP
# images, and MP4 (ISO base media) or WebM video. A video must be at most 30
# seconds long by ffprobe.
#
# Size. A fixed 10000000-byte limit caps every posted file. An
# oversized image is downscaled with ImageMagick, which also strips its
# metadata, until it fits; one that cannot be brought under the cap is
# refused. An oversized video is refused and never re-encoded.
#
# Screening. Firstmate itself looks at every image and at the sampled frames
# of every video before it can post them; the ext-respond skill owns that
# procedure. frames <video> samples 4 to 10 evenly spaced frames into
# state/ext-media/frames/<sha256>/ and prints their paths. screen <file>
# records Firstmate's verdict as an attestation bound to the content digest at
# state/ext-media/screened/<sha256>.json (mode 0600) and prints
# "screened <sha256> <verdict>"; a video needs its frames sampled first.
# Screening the same content again replaces its verdict. The reason stays
# private and never reaches Discord.
#
# stage is what bin/fm-ext-emit.sh runs. It takes at most 4 images and 1
# video, refuses any file whose content digest lacks a clear attestation, and
# copies the files into state/ext-media/staged/<slug>.<kind>.<generation>.<nonce>/
# (mode 0700, files 0600) under generic names (image-1.png ... image-4.webp,
# video-1.mp4) that never carry a source path or filename. It prints
# {"dir", "files":[{name, media, media_type, bytes, sha256, screened_sha256}]}:
# sha256 is the staged bytes and screened_sha256 the attested content, which
# differ only for a downscaled image.
#
# verify is what the gateway poster runs before an upload. It re-checks every
# staged file of one outbox payload (generic name, private regular file,
# digest, and a still-clear attestation) and prints
# {"files":[{name, path, media_type, bytes, sha256}], "dropped":[names]};
# the poster posts a short note in place of a dropped file.
#
# pull copies one screenshot or recording from a remote second mate's home
# over the existing link (bin/fm-on.sh running bin/fm-remote-file.sh sum, then
# ranged gets of at most 768 KiB each) into
# state/ext-media/pulled/<secondmate-id>/<sha256>.<ext> and prints that local
# path, which is then screened and posted like any local file. The remote path
# is relative to the remote home, must sit under data/ or state/, and must end
# in a media extension; the copy must match the remote size and digest and
# still be a supported type. The second mate's Firstmate checkout needs the
# sum and ranged get subcommands, so update it first if the pull is refused.
#
# Everything under state/ext-media follows the 14-day media retention owned by
# fm_ext_media_prune in bin/fm-ext-lib.sh, which the bridge poll runs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-ext-media.sh frames <video>
       fm-ext-media.sh screen <file> --verdict clear|refused --reason <text>
       fm-ext-media.sh pull <secondmate-id> <remote-relative-path>
       fm-ext-media.sh stage --slug <slug> --kind answer|followup|final --generation <n> <file>...
       fm-ext-media.sh verify --payload <outbox-payload>
EOF
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-ext-media: %s\n' "$1" >&2; exit "${2:-2}"; }

MEDIA_MAX_IMAGES=4
MEDIA_MAX_VIDEOS=1
MEDIA_VIDEO_MAX_SECS=30
MEDIA_REASON_MAX=200
# One ranged read from a remote second mate, safely under its 1 MiB job
# output bound.
MEDIA_PULL_PIECE=786432

case "${1:-}" in
  --help|-h) help; exit 0 ;;
  '') usage; exit 2 ;;
esac
CMD=$1
shift

fm_env_is_task_worker \
  && die "refusing inside a task worker (FM_TASK_ID=$FM_TASK_ID): only Firstmate screens and posts media; save screenshots as evidence instead"
fm_ext_active "$FM_HOME" || die "local ext-bridge is not active" 1
command -v jq >/dev/null 2>&1 || die "jq is required" 1
command -v python3 >/dev/null 2>&1 || die "python3 is required" 1

MEDIA=$(fm_ext_media_dir)
WORK=
cleanup() {
  [ -z "$WORK" ] || rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Private scratch inside the staged tree, so leftovers from a killed run are
# pruned with the rest of the media and copies never leave this home.
work_dir() {
  fm_ext_private_artifact_dir_prepare "$MEDIA" >/dev/null || die "could not prepare $MEDIA" 1
  fm_ext_private_artifact_dir_prepare "$MEDIA/staged" >/dev/null || die "could not prepare the staging folder" 1
  WORK=$(umask 077; mktemp -d "$MEDIA/staged/.work-XXXXXXXX" 2>/dev/null) || die "could not create a private work folder" 1
}

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

# Accepted source roots, one "<root>\t<required-prefix>" per line, each root
# as given.
media_roots() {
  local data state meta kind worktree root
  data=$(absolute_path "${FM_DATA_OVERRIDE:-$FM_HOME/data}")
  state=$(absolute_path "$(fm_ext_state_dir)")
  for root in "$data" "$state"; do
    [ -d "$root" ] && [ ! -L "$root" ] || continue
    printf '%s\t\n' "$root"
  done
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    kind=$(fm_ext_meta_get "$meta" kind)
    case "$kind" in
      ship|scout) ;;
      *) continue ;;
    esac
    worktree=$(fm_ext_meta_get "$meta" worktree)
    case "$worktree" in
      /*) ;;
      *) continue ;;
    esac
    [ -d "$worktree" ] && [ ! -L "$worktree" ] || continue
    printf '%s\t.qa/evidence/\n' "$worktree"
  done
}

# media_source_copy <path> <dest>: refuse anything outside the accepted roots
# or symlinked below them, then copy it without following symlinks.
media_source_copy() {
  local path=$1 dest=$2 root prefix rel cur part rest found=0 rc
  path=$(absolute_path "$path")
  case "$path" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "media path contains control characters" ;;
  esac
  case "$path/" in
    */./*|*/../*|*//*) die "media path must not contain '.', '..', or empty components: $path" ;;
  esac
  while IFS=$'\t' read -r root prefix; do
    [ -n "$root" ] || continue
    rel=
    case "$path" in
      "$root"/*) rel=${path#"$root"/} ;;
      *) continue ;;
    esac
    if [ -n "$prefix" ]; then
      case "$rel" in
        "$prefix"?*) ;;
        *) continue ;;
      esac
    fi
    found=1
    break
  done < <(media_roots)
  [ "$found" = 1 ] \
    || die "media must come from this home's data/ or state/ tree or a task worktree's .qa/evidence/ folder: $path"
  cur=$root
  rest=$rel
  while :; do
    part=${rest%%/*}
    cur="$cur/$part"
    [ ! -L "$cur" ] || die "refusing a symlinked media path: $path"
    [ "$rest" != "$part" ] || break
    rest=${rest#*/}
  done
  [ -f "$cur" ] || die "media file not found or not a regular file: $path"
  fm_ext_attachment_copy_nofollow "$root" "$rel" "$dest" media >/dev/null
  rc=$?
  case "$rc" in
    0) ;;
    11) die "media file is larger than the 33554432-byte video read limit: $path" ;;
    *) die "could not read the media file without following a symlink: $path" ;;
  esac
}

# media_sniff <file>: print "<media> <media_type> <ext> <sha256> <bytes>",
# with media "unsupported" when the contents are none of the accepted types.
media_sniff() {
  python3 - "$1" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
size = 0
head = b""
with open(sys.argv[1], "rb") as handle:
    while True:
        chunk = handle.read(1 << 20)
        if not chunk:
            break
        if len(head) < 64:
            head += chunk[: 64 - len(head)]
        digest.update(chunk)
        size += len(chunk)
MP4_BRANDS = {b"isom", b"iso2", b"iso3", b"iso4", b"iso5", b"iso6", b"mp41",
              b"mp42", b"avc1", b"M4V ", b"dash", b"mmp4", b"msnv"}
if head.startswith(b"\x89PNG\r\n\x1a\n"):
    kind = ("image", "image/png", "png")
elif head.startswith(b"\xff\xd8\xff"):
    kind = ("image", "image/jpeg", "jpg")
elif head[:6] in (b"GIF87a", b"GIF89a"):
    kind = ("image", "image/gif", "gif")
elif head[:4] == b"RIFF" and head[8:12] == b"WEBP":
    kind = ("image", "image/webp", "webp")
elif head[4:8] == b"ftyp" and head[8:12] in MP4_BRANDS:
    kind = ("video", "video/mp4", "mp4")
elif head[:4] == b"\x1a\x45\xdf\xa3" and b"webm" in head:
    kind = ("video", "video/webm", "webm")
else:
    kind = ("unsupported", "application/octet-stream", "bin")
print(kind[0], kind[1], kind[2], digest.hexdigest(), size)
PY
}

# video_duration <file>: print the length in seconds, or fail when ffprobe
# finds no video stream.
video_duration() {
  local out
  command -v ffprobe >/dev/null 2>&1 || die "ffprobe is required to check a video's length" 1
  out=$(ffprobe -v error -show_entries format=duration:stream=codec_type -of json "$1" 2>/dev/null) || return 1
  printf '%s' "$out" \
    | jq -er 'select(any(.streams[]?; .codec_type == "video")) | .format.duration | tonumber | select(. > 0)' 2>/dev/null
}

video_length_ok() {
  awk -v d="$1" -v max="$MEDIA_VIDEO_MAX_SECS" 'BEGIN { exit !(d + 0 <= max + 0.05) }'
}

# attestation_verdict <sha256>: print clear or refused, or fail when this
# content has no valid attestation.
attestation_verdict() {
  local sha=$1
  fm_ext_private_artifact_file_valid "$MEDIA/screened" "$sha.json" 600 || return 1
  jq -er --arg sha "$sha" \
    'select(.schema == 1 and .sha256 == $sha) | .verdict | select(. == "clear" or . == "refused")' \
    "$MEDIA/screened/$sha.json" 2>/dev/null
}

frames_count() {
  local sha=$1
  fm_ext_private_artifact_file_valid "$MEDIA/frames/$sha" frames.json 600 || return 1
  jq -er --arg sha "$sha" \
    'select(.schema == 1 and .sha256 == $sha) | .count | select(type == "number" and . >= 1)' \
    "$MEDIA/frames/$sha/frames.json" 2>/dev/null
}

image_magick() {
  if command -v magick >/dev/null 2>&1; then
    printf '%s\n' magick
  elif command -v convert >/dev/null 2>&1; then
    printf '%s\n' convert
  else
    return 1
  fi
}

# image_downscale <source> <dest> <ext> <max-bytes>: shrink an oversized image
# in steps, keeping its format, until it fits.
image_downscale() {
  local src=$1 dest=$2 ext=$3 max=$4 im percent size
  im=$(image_magick) || die "an image is over the $max-byte limit and ImageMagick is not available to downscale it" 1
  for percent in 90 75 60 50 40 30 22 15 10; do
    rm -f -- "$dest"
    case "$ext" in
      gif)
        "$im" -limit memory 256MiB -limit map 512MiB -limit disk 1GiB -limit width 32768 -limit height 32768 -limit area 64MP -limit time 30 "$src" -coalesce -strip -resize "${percent}%" -layers Optimize "GIF:$dest" >/dev/null 2>&1 || continue
        ;;
      png)
        "$im" -limit memory 256MiB -limit map 512MiB -limit disk 1GiB -limit width 32768 -limit height 32768 -limit area 64MP -limit time 30 "$src" -auto-orient -strip -resize "${percent}%" "PNG:$dest" >/dev/null 2>&1 || continue
        ;;
      jpg)
        "$im" -limit memory 256MiB -limit map 512MiB -limit disk 1GiB -limit width 32768 -limit height 32768 -limit area 64MP -limit time 30 "$src" -auto-orient -strip -resize "${percent}%" -quality 85 "JPEG:$dest" >/dev/null 2>&1 || continue
        ;;
      webp)
        "$im" -limit memory 256MiB -limit map 512MiB -limit disk 1GiB -limit width 32768 -limit height 32768 -limit area 64MP -limit time 30 "$src" -auto-orient -strip -resize "${percent}%" -quality 85 "WEBP:$dest" >/dev/null 2>&1 || continue
        ;;
      *) return 1 ;;
    esac
    [ -f "$dest" ] || continue
    size=$(wc -c < "$dest" | tr -d ' ')
    [ "$size" -le "$max" ] 2>/dev/null && return 0
  done
  rm -f -- "$dest"
  die "image exceeds ImageMagick resource limits or cannot fit the upload limit"
}

cmd_frames() {
  local path media media_type ext sha bytes duration count i at out dir
  [ "$#" -eq 1 ] || { usage; exit 2; }
  path=$1
  command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is required to sample a video's frames" 1
  work_dir
  media_source_copy "$path" "$WORK/source"
  read -r media media_type ext sha bytes < <(media_sniff "$WORK/source") || die "could not read the media file" 1
  [ "$media" = video ] || die "frames samples a video; look at an image directly: $path"
  duration=$(video_duration "$WORK/source") || die "not a playable video: $path"
  video_length_ok "$duration" || die "video is ${duration}s long; at most ${MEDIA_VIDEO_MAX_SECS}s is allowed: $path"
  count=$(awk -v d="$duration" 'BEGIN { n = int((d + 2.999) / 3); if (n < 4) n = 4; if (n > 10) n = 10; print n }')
  mkdir -m 700 "$WORK/frames" || die "could not create the frame folder" 1
  i=1
  while [ "$i" -le "$count" ]; do
    at=$(awk -v d="$duration" -v i="$i" -v n="$count" 'BEGIN { printf "%.3f", d * (i - 0.5) / n }')
    out=$(printf '%s/frame-%02d.png' "$WORK/frames" "$i")
    ffmpeg -nostdin -v error -i "$WORK/source" -ss "$at" -frames:v 1 -y "$out" >/dev/null 2>&1 \
      && [ -s "$out" ] || die "could not sample the frame at ${at}s: $path" 1
    chmod 600 "$out"
    i=$((i + 1))
  done
  jq -cn --arg sha "$sha" --argjson count "$count" --argjson duration "$duration" \
    --argjson recorded_at "${FM_EXT_NOW_OVERRIDE:-$(date +%s)}" \
    '{schema:1, sha256:$sha, count:$count, duration:$duration, recorded_at:$recorded_at}' \
    > "$WORK/frames/frames.json" || die "could not record the frame sample" 1
  chmod 600 "$WORK/frames/frames.json"
  fm_ext_private_artifact_dir_prepare "$MEDIA/frames" >/dev/null || die "could not prepare the frames folder" 1
  dir="$MEDIA/frames/$sha"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || die "refusing an unsafe frames folder: $dir" 1
    rm -rf -- "$dir" || die "could not replace the earlier frame sample" 1
  fi
  mv -- "$WORK/frames" "$dir" || die "could not publish the frame sample" 1
  i=1
  while [ "$i" -le "$count" ]; do
    printf '%s/frame-%02d.png\n' "$dir" "$i"
    i=$((i + 1))
  done
}

cmd_screen() {
  local path verdict='' reason='' media media_type ext sha bytes frames=0 record
  [ "$#" -ge 1 ] || { usage; exit 2; }
  path=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verdict) shift; verdict=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      *) die "unknown argument '$1'" ;;
    esac
    shift || true
  done
  case "$verdict" in
    clear|refused) ;;
    *) die "--verdict must be clear or refused" ;;
  esac
  [ -n "$(printf '%s' "$reason" | tr -d '[:space:]')" ] || die "--reason must say what you checked or found"
  case "$reason" in
    *$'\n'*|*$'\r'*) die "--reason must be one line" ;;
  esac
  [ "${#reason}" -le "$MEDIA_REASON_MAX" ] || die "--reason must be at most $MEDIA_REASON_MAX characters"
  work_dir
  media_source_copy "$path" "$WORK/source"
  read -r media media_type ext sha bytes < <(media_sniff "$WORK/source") || die "could not read the media file" 1
  [ "$media" != unsupported ] \
    || die "unsupported media type (only PNG, JPEG, GIF, or WebP images and MP4 or WebM video): $path"
  if [ "$media" = video ]; then
    frames=$(frames_count "$sha") \
      || die "sample this video's frames first with 'fm-ext-media.sh frames <video>' and look at every frame: $path"
  fi
  record=$(jq -cn --arg sha "$sha" --arg media "$media" --arg media_type "$media_type" \
    --argjson bytes "$bytes" --arg verdict "$verdict" --arg reason "$reason" \
    --argjson frames "$frames" --argjson screened_at "${FM_EXT_NOW_OVERRIDE:-$(date +%s)}" \
    '{schema:1, sha256:$sha, media:$media, media_type:$media_type, bytes:$bytes,
      verdict:$verdict, reason:$reason, frames:$frames, screened_by:"firstmate",
      screened_at:$screened_at}') || die "could not build the attestation" 1
  printf '%s\n' "$record" | fm_ext_private_artifact_publish_stdin "$MEDIA/screened" "$sha.json" 600 \
    || die "could not record the attestation" 1
  printf 'screened %s %s\n' "$sha" "$verdict"
}

cmd_stage() {
  local slug='' kind='' generation='' max nonce stage final path media media_type ext sha bytes
  local verdict duration name images=0 videos=0 total index=0 lines out
  local staged_media staged_type staged_ext staged_sha staged_bytes
  local -a plan_media=() plan_type=() plan_ext=() plan_sha=() plan_bytes=() plan_name=() plan_path=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --slug) shift; slug=${1:-} ;;
      --kind) shift; kind=${1:-} ;;
      --generation) shift; generation=${1:-} ;;
      --) shift; break ;;
      -*) die "unknown argument '$1'" ;;
      *) break ;;
    esac
    shift || true
  done
  fm_ext_slug_valid "$slug" || die "unsafe slug"
  case "$kind" in
    answer|followup|final) ;;
    *) die "media attaches only to an answer, followup, or final" ;;
  esac
  fm_ext_generation_valid "$generation" || die "generation must be a positive integer"
  total=$#
  [ "$total" -ge 1 ] || die "stage needs at least one media file"
  [ "$total" -le $((MEDIA_MAX_IMAGES + MEDIA_MAX_VIDEOS)) ] \
    || die "a post carries at most $MEDIA_MAX_IMAGES images and $MEDIA_MAX_VIDEOS video; keep the rest in the work's report"
  max=10000000
  nonce=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ "${#nonce}" -eq 16 ] || die "could not create a staging identity" 1
  fm_ext_private_artifact_dir_prepare "$MEDIA" >/dev/null || die "could not prepare $MEDIA" 1
  fm_ext_private_artifact_dir_prepare "$MEDIA/staged" >/dev/null || die "could not prepare the staging folder" 1
  stage="$MEDIA/staged/.stage-$nonce"
  final="$MEDIA/staged/$slug.$kind.$generation.$nonce"
  (umask 077; mkdir "$stage") || die "could not create the staging folder" 1
  WORK=$stage
  lines="$stage/.files.jsonl"
  : > "$lines"
  # First pass: copy, type, count, and size every file, so a post that breaks
  # the per-post limits is refused before any screening verdict is consulted.
  for path in "$@"; do
    index=$((index + 1))
    media_source_copy "$path" "$stage/.source-$index"
    read -r media media_type ext sha bytes < <(media_sniff "$stage/.source-$index") \
      || die "could not read the media file" 1
    case "$media" in
      image)
        images=$((images + 1))
        [ "$images" -le "$MEDIA_MAX_IMAGES" ] \
          || die "a post carries at most $MEDIA_MAX_IMAGES images; keep the rest in the work's report"
        name="image-$images.$ext"
        ;;
      video)
        videos=$((videos + 1))
        [ "$videos" -le "$MEDIA_MAX_VIDEOS" ] \
          || die "a post carries at most $MEDIA_MAX_VIDEOS video; keep the rest in the work's report"
        [ "$bytes" -le "$max" ] \
          || die "video is $bytes bytes, over the $max-byte limit; videos are never re-encoded, so post without it and say so in the text: $path"
        name="video-$videos.$ext"
        ;;
      *) die "unsupported media type (only PNG, JPEG, GIF, or WebP images and MP4 or WebM video): $path" ;;
    esac
    plan_media[index]=$media
    plan_type[index]=$media_type
    plan_ext[index]=$ext
    plan_sha[index]=$sha
    plan_bytes[index]=$bytes
    plan_name[index]=$name
    plan_path[index]=$path
  done
  # Second pass: every file needs Firstmate's clear verdict on its exact
  # content, then a playable length for video, then its staged copy.
  index=0
  while [ "$index" -lt "$total" ]; do
    index=$((index + 1))
    media=${plan_media[index]}
    media_type=${plan_type[index]}
    ext=${plan_ext[index]}
    sha=${plan_sha[index]}
    bytes=${plan_bytes[index]}
    name=${plan_name[index]}
    path=${plan_path[index]}
    if ! verdict=$(attestation_verdict "$sha"); then
      die "not screened: $path - look at it yourself and record 'fm-ext-media.sh screen' before posting"
    fi
    [ "$verdict" = clear ] || die "screened and refused, so it cannot be posted: $path"
    if [ "$media" = video ]; then
      duration=$(video_duration "$stage/.source-$index") || die "not a playable video: $path"
      video_length_ok "$duration" || die "video is ${duration}s long; at most ${MEDIA_VIDEO_MAX_SECS}s is allowed: $path"
    fi
    if [ "$bytes" -gt "$max" ]; then
      image_downscale "$stage/.source-$index" "$stage/$name" "$ext" "$max"
      rm -f -- "$stage/.source-$index"
    else
      mv -- "$stage/.source-$index" "$stage/$name" || die "could not stage $name" 1
    fi
    chmod 600 "$stage/$name" || die "could not protect $name" 1
    read -r staged_media staged_type staged_ext staged_sha staged_bytes < <(media_sniff "$stage/$name") \
      || die "could not hash $name" 1
    [ "$staged_media:$staged_type:$staged_ext" = "$media:$media_type:$ext" ] \
      || die "the staged copy of $path changed type" 1
    jq -cn --arg name "$name" --arg media "$media" --arg media_type "$media_type" \
      --argjson bytes "$staged_bytes" --arg sha256 "$staged_sha" --arg screened "$sha" \
      '{name:$name, media:$media, media_type:$media_type, bytes:$bytes, sha256:$sha256, screened_sha256:$screened}' \
      >> "$lines" || die "could not record $name" 1
  done
  out=$(jq -cs --arg dir "${final##*/}" '{dir:$dir, files:.}' "$lines") || die "could not record the staged files" 1
  rm -f -- "$lines"
  mv -- "$stage" "$final" || die "could not publish the staged media" 1
  WORK=
  printf '%s\n' "$out"
}

cmd_verify() {
  local payload='' dir staged entry name expected screened path actual bytes media_type files dropped
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --payload) shift; payload=${1:-} ;;
      *) die "unknown argument '$1'" ;;
    esac
    shift || true
  done
  [ -n "$payload" ] || { usage; exit 2; }
  fm_ext_outbox_schema_valid "$payload" || die "outbox payload is missing or invalid" 1
  if ! jq -e 'has("media")' "$payload" >/dev/null 2>&1; then
    printf '{"files":[],"dropped":[]}\n'
    return 0
  fi
  dir=$(jq -r '.media.dir' "$payload")
  staged="$MEDIA/staged/$dir"
  files=$(mktemp "${TMPDIR:-/tmp}/fm-ext-media-files.XXXXXX") || die "could not create a temp file" 1
  dropped=$(mktemp "${TMPDIR:-/tmp}/fm-ext-media-dropped.XXXXXX") || die "could not create a temp file" 1
  while IFS= read -r entry; do
    name=$(printf '%s' "$entry" | jq -r '.name')
    expected=$(printf '%s' "$entry" | jq -r '.sha256')
    screened=$(printf '%s' "$entry" | jq -r '.screened_sha256')
    media_type=$(printf '%s' "$entry" | jq -r '.media_type')
    path="$staged/$name"
    actual=
    if printf '%s' "$name" | grep -Eq "$FM_EXT_MEDIA_NAME_RE" \
      && fm_ext_private_artifact_file_valid "$staged" "$name" 600; then
      actual=$(fm_ext_sha256 < "$path")
    fi
    if [ -n "$actual" ] && [ "$actual" = "$expected" ] \
      && [ "$(attestation_verdict "$screened" 2>/dev/null)" = clear ]; then
      bytes=$(wc -c < "$path" | tr -d ' ')
      jq -cn --arg name "$name" --arg path "$path" --arg media_type "$media_type" \
        --argjson bytes "$bytes" --arg sha256 "$actual" \
        '{name:$name, path:$path, media_type:$media_type, bytes:$bytes, sha256:$sha256}' >> "$files"
    else
      jq -cn --arg name "$name" '$name' >> "$dropped"
    fi
  done < <(jq -c '.media.files[]' "$payload")
  jq -cn --slurpfile files "$files" --slurpfile dropped "$dropped" '{files:$files, dropped:$dropped}'
  rm -f -- "$files" "$dropped"
}

cmd_pull() {
  local id rel ext lower media media_type sniff_ext sha bytes dest rc summary want_bytes want_sha offset got
  [ "$#" -eq 2 ] || { usage; exit 2; }
  id=$1
  rel=$2
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) die "unsafe second mate id: $id" ;;
  esac
  case "$rel" in
    data/?*|state/?*) ;;
    *) die "the remote path must be relative to the second mate's home and sit under data/ or state/: $rel" ;;
  esac
  case "/$rel/" in
    */./*|*/../*|*//*) die "the remote path must not contain '.', '..', or empty components: $rel" ;;
  esac
  case "$rel" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "the remote path contains control characters" ;;
  esac
  ext=${rel##*.}
  lower=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    png|jpg|jpeg|gif|webp|mp4|webm) ;;
    *) die "the remote path must name a PNG, JPEG, GIF, WebP, MP4, or WebM file: $rel" ;;
  esac
  work_dir
  # The remote job output bound is 1 MiB, so the file is sized and hashed
  # first, read in bounded pieces, and accepted only when the pieces add up
  # to exactly that file.
  summary=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-file.sh sum "$rel" 0 < /dev/null)
  rc=$?
  [ "$rc" -eq 0 ] \
    || die "could not read $rel on second mate $id (link exit $rc); its Firstmate checkout may need an update" 1
  read -r want_bytes want_sha <<EOF
$summary
EOF
  case "$want_bytes" in
    ''|*[!0-9]*) die "second mate $id gave an unreadable size for $rel" 1 ;;
  esac
  printf '%s' "$want_sha" | grep -Eq '^[0-9a-f]{64}$' || die "second mate $id gave an unreadable digest for $rel" 1
  [ "$want_bytes" -ge 1 ] || die "the remote file is empty: $rel"
  : > "$WORK/pulled"
  offset=0
  while [ "$offset" -lt "$want_bytes" ]; do
    "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-file.sh get "$rel" 0 "$offset" "$MEDIA_PULL_PIECE" \
      < /dev/null >> "$WORK/pulled"
    rc=$?
    [ "$rc" -eq 0 ] || die "could not copy $rel from second mate $id (link exit $rc)" 1
    got=$(wc -c < "$WORK/pulled" | tr -d ' ')
    [ "$got" -gt "$offset" ] || die "second mate $id returned no bytes for $rel at offset $offset" 1
    offset=$got
  done
  read -r media media_type sniff_ext sha bytes < <(media_sniff "$WORK/pulled") || die "could not read the copied file" 1
  [ "$bytes" = "$want_bytes" ] && [ "$sha" = "$want_sha" ] \
    || die "the copy of $rel does not match the second mate's file; it may have changed while copying, so try again" 1
  [ "$media" != unsupported ] \
    || die "the copied file is not a PNG, JPEG, GIF, or WebP image or an MP4 or WebM video: $rel"
  fm_ext_private_artifact_dir_prepare "$MEDIA/pulled" >/dev/null || die "could not prepare the pulled folder" 1
  fm_ext_private_artifact_dir_prepare "$MEDIA/pulled/$id" >/dev/null || die "could not prepare the pulled folder" 1
  dest="$MEDIA/pulled/$id/$sha.$sniff_ext"
  chmod 600 "$WORK/pulled" || die "could not protect the copied file" 1
  mv -f -- "$WORK/pulled" "$dest" || die "could not publish the copied file" 1
  printf '%s\n' "$dest"
}

case "$CMD" in
  frames) cmd_frames "$@" ;;
  screen) cmd_screen "$@" ;;
  stage) cmd_stage "$@" ;;
  verify) cmd_verify "$@" ;;
  pull) cmd_pull "$@" ;;
  *) usage; exit 2 ;;
esac
