#!/usr/bin/env bash
# Own the portable pinned task, brief, and evidence-ledger descriptor boundary.
#
# Usage:
#   fm-receipt-store.sh <task-id> hold <brief-out> <ledger-out> <ready-file> <release-fifo>
#   fm-receipt-store.sh <task-id> append <criterion> <criterion-parser>
#
# hold snapshots the pinned brief and ledger under a shared ledger lock, writes
# 0 or 3 (ledger missing) to ready-file, and retains the lock until release-fifo
# receives one line.
# append validates the pinned ship brief and criterion, then appends the compact
# JSON payload from FM_RECEIPT_PAYLOAD under an exclusive ledger lock.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 2 ] || { usage >&2; exit 2; }
ID=$1
MODE=$2
shift 2
case "$ID" in
  ''|.|..|*[!A-Za-z0-9._-]*|[._-]*) echo "error: invalid task id: $ID" >&2; exit 2 ;;
esac
case "$MODE:$#" in
  hold:4|append:2) ;;
  *) usage >&2; exit 2 ;;
esac

command -v perl >/dev/null 2>&1 || { echo "error: perl is required" >&2; exit 1; }
[ -d "$DATA" ] || { echo "error: data directory is missing: $DATA" >&2; exit 1; }
DATA_REAL=$(CDPATH='' cd -- "$DATA" 2>/dev/null && pwd -P) \
  || { echo "error: data directory is unsafe: $DATA" >&2; exit 1; }

FM_RECEIPT_STORE_DATA="$DATA_REAL" FM_RECEIPT_STORE_ID="$ID" FM_RECEIPT_STORE_MODE="$MODE" \
  perl - "$@" <<'PERL'
use strict;
use warnings;
use Errno qw(ENOENT EINTR);
use Fcntl qw(:DEFAULT :flock :mode);

my ($arg1, $arg2, $arg3, $arg4) = @ARGV;
my $ready = $ENV{FM_RECEIPT_STORE_MODE} eq "hold" ? $arg3 : undef;

sub publish_ready {
  my ($code) = @_;
  return unless defined($ready);
  open(my $output, ">", $ready) or return;
  print {$output} "$code\n";
  close($output);
}

sub refuse {
  print STDERR "error: $_[0]\n";
  publish_ready(1);
  exit 1;
}

sub copy_file {
  my ($source, $destination) = @_;
  sysseek($source, 0, 0) or refuse("could not rewind pinned task artifact");
  sysopen(my $output, $destination, O_WRONLY | O_CREAT | O_TRUNC, 0600)
    or refuse("could not prepare pinned task snapshot");
  my $buffer;
  while (1) {
    my $read = sysread($source, $buffer, 65536);
    defined($read) or refuse("could not read pinned task artifact");
    last if $read == 0;
    print {$output} substr($buffer, 0, $read) or refuse("could not write pinned task snapshot");
  }
  close($output) or refuse("could not close pinned task snapshot");
}

my $task_path = "$ENV{FM_RECEIPT_STORE_DATA}/$ENV{FM_RECEIPT_STORE_ID}";
sysopen(my $task, $task_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
  or refuse("task directory is missing or unsafe: $task_path");
my @task_identity = stat($task);
refuse("task path is not a directory") unless @task_identity && S_ISDIR($task_identity[2]);
my @named_identity = lstat($task_path);
refuse("task directory identity changed") unless @named_identity
  && !S_ISLNK($named_identity[2])
  && $named_identity[0] == $task_identity[0]
  && $named_identity[1] == $task_identity[1];
my $task_fd_path = "/dev/fd/" . fileno($task);
my @descriptor_identity = stat($task_fd_path);
refuse("portable task descriptor path is unavailable") unless @descriptor_identity
  && $descriptor_identity[0] == $task_identity[0]
  && $descriptor_identity[1] == $task_identity[1];

sysopen(my $brief, "$task_fd_path/brief.md", O_RDONLY | O_NOFOLLOW)
  or refuse("task brief is missing or unsafe");
my @brief_identity = stat($brief);
refuse("task brief is not a regular file") unless @brief_identity && S_ISREG($brief_identity[2]);

if ($ENV{FM_RECEIPT_STORE_MODE} eq "hold") {
  my $ledger_missing = 0;
  my $ledger;
  if (!sysopen($ledger, "$task_fd_path/evidence.jsonl", O_RDONLY | O_NOFOLLOW)) {
    $ledger_missing = 1 if $! == ENOENT;
    refuse("evidence ledger is missing or unsafe") unless $ledger_missing;
  }
  if (!$ledger_missing) {
    my @ledger_identity = stat($ledger);
    refuse("evidence ledger must be a single-link regular file") unless @ledger_identity
      && S_ISREG($ledger_identity[2]) && $ledger_identity[3] == 1;
    flock($ledger, LOCK_SH) or refuse("evidence ledger could not be locked");
  }
  sysopen(my $release, $arg4, O_RDWR | O_NOFOLLOW)
    or refuse("evidence ledger release channel is unsafe");
  copy_file($brief, $arg1);
  copy_file($ledger, $arg2) unless $ledger_missing;
  publish_ready($ledger_missing ? 3 : 0);
  scalar(<$release>);
  exit($ledger_missing ? 3 : 0);
}

my $criterion = $arg1;
my $parser = $arg2;
sysopen(my $ledger, "$task_fd_path/evidence.jsonl", O_WRONLY | O_APPEND | O_NOFOLLOW)
  or refuse("evidence ledger is missing or unsafe");
my @ledger_identity = stat($ledger);
refuse("evidence ledger must be a single-link regular file") unless @ledger_identity
  && S_ISREG($ledger_identity[2]) && $ledger_identity[3] == 1;
flock($ledger, LOCK_EX) or refuse("evidence ledger could not be locked");

local $/;
my $brief_text = <$brief>;
defined($brief_text) or refuse("task brief could not be read");
my @delivery = ($brief_text =~ /^Delivery contract: mode=(no-mistakes|direct-PR|local-only)$/mg);
refuse("receipts apply only to ship tasks with one delivery contract") unless @delivery == 1;
open(my $criterion_parser, "|-", $parser, "--parse-criteria", "-", "--require", $criterion)
  or refuse("acceptance-criterion parser could not start");
print {$criterion_parser} $brief_text or refuse("task brief could not reach the acceptance-criterion parser");
close($criterion_parser) or refuse("criterion is not declared by a valid ship brief: $criterion");

my $record = "$ENV{FM_RECEIPT_PAYLOAD}\n";
my $offset = 0;
while ($offset < length($record)) {
  my $written = syswrite($ledger, $record, length($record) - $offset, $offset);
  next if !defined($written) && $! == EINTR;
  refuse("evidence receipt append failed") unless defined($written) && $written > 0;
  $offset += $written;
}
close($ledger) or refuse("evidence ledger close failed");
PERL
