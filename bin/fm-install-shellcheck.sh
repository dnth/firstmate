#!/usr/bin/env bash
# fm-install-shellcheck.sh - install CI's pinned, verified ShellCheck build.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"
SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
ARCHIVE="shellcheck-v${VERSION}.linux.x86_64.tar.xz"
URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
IMAGE="koalaman/shellcheck@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d"
DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-shellcheck.XXXXXX")
CONTAINER=
cleanup() {
  [ -z "$CONTAINER" ] || docker rm -f "$CONTAINER" >/dev/null 2>&1 || :
  rm -rf "$TMP"
}
trap cleanup EXIT

DOWNLOAD_ATTEMPTS=5
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  rm -f "$TMP/$ARCHIVE"
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-shellcheck.sh: download failed after %s attempts; trying pinned Docker image\n' "$DOWNLOAD_ATTEMPTS" >&2
    break
  }
  printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << download_attempt))
  download_attempt=$((download_attempt + 1))
done

if [ -f "$TMP/$ARCHIVE" ]; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
  [ "$ACTUAL_SHA256" = "$SHA256" ] || {
    printf 'fm-install-shellcheck.sh: checksum mismatch for %s\n' "$ARCHIVE" >&2
    exit 1
  }
  tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
  SOURCE="$TMP/shellcheck-v${VERSION}/shellcheck"
else
  command -v docker >/dev/null 2>&1 || {
    printf 'fm-install-shellcheck.sh: docker is required after the release download fails\n' >&2
    exit 1
  }
  CONTAINER=$(docker create --platform linux/amd64 "$IMAGE") || {
    printf 'fm-install-shellcheck.sh: could not create the pinned ShellCheck container\n' >&2
    exit 1
  }
  docker cp "$CONTAINER:/bin/shellcheck" "$TMP/shellcheck" || {
    printf 'fm-install-shellcheck.sh: could not extract ShellCheck from the pinned container\n' >&2
    exit 1
  }
  docker rm "$CONTAINER" >/dev/null
  CONTAINER=
  SOURCE="$TMP/shellcheck"
fi

mkdir -p "$DESTINATION"
install -m 0755 "$SOURCE" "$DESTINATION/shellcheck"
"$DESTINATION/shellcheck" --version
