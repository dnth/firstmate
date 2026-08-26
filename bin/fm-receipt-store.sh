#!/usr/bin/env bash
# Own the portable pinned task, state metadata, brief, and evidence-ledger descriptor boundary.
#
# Usage:
#   fm-receipt-store.sh <task-id> hold <brief-out> <ledger-out> <ready-file> <release-fifo>
#   fm-receipt-store.sh <task-id> append <criterion> <criterion-parser>
#   fm-receipt-store.sh <task-id> promote <transaction-command> [<arg> ...]
#
# hold snapshots the pinned brief and ledger under a shared ledger lock, writes
# 0 (ready), 1 (refused), or 3 (ledger missing) to ready-file, and on ready or
# missing retains the lock until release-fifo receives one line before exiting
# with the same status.
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
  promote:0) usage >&2; exit 2 ;;
  promote:*) ;;
  *) usage >&2; exit 2 ;;
esac

command -v perl >/dev/null 2>&1 || { echo "error: perl is required" >&2; exit 1; }

FM_RECEIPT_STORE_DATA="$DATA" FM_RECEIPT_STORE_ID="$ID" FM_RECEIPT_STORE_MODE="$MODE" \
  perl - "$@" <<'PERL'
use strict;
use warnings;
use Cwd qw(getcwd);
use Errno qw(EEXIST ENOENT EINTR);
use Fcntl qw(:DEFAULT :flock :mode);
use IO::Handle;

my ($arg1, $arg2, $arg3, $arg4) = @ARGV;
my $ready = $ENV{FM_RECEIPT_STORE_MODE} eq "hold" ? $arg3 : undef;
my $append_tmp;
END { unlink($append_tmp) if defined($append_tmp) && -e $append_tmp; }
$SIG{HUP} = $SIG{INT} = $SIG{TERM} = sub {
  unlink($append_tmp) if defined($append_tmp) && -e $append_tmp;
  $append_tmp = undef;
  exit 1;
};

sub publish_ready {
  my ($code) = @_;
  return 1 unless defined($ready);
  open(my $output, ">", $ready) or return 0;
  print {$output} "$code\n" or return 0;
  close($output) or return 0;
  return 1;
}

sub refuse {
  print STDERR "error: $_[0]\n";
  unlink($append_tmp) if defined($append_tmp) && -e $append_tmp;
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

sub write_new_file {
  my ($name, $bytes) = @_;
  sysopen(my $output, $name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
    or refuse("promotion metadata artifact could not be created");
  my $offset = 0;
  while ($offset < length($bytes)) {
    my $written = syswrite($output, $bytes, length($bytes) - $offset, $offset);
    next if !defined($written) && $! == EINTR;
    refuse("promotion metadata artifact could not be written") unless defined($written) && $written > 0;
    $offset += $written;
  }
  $output->sync or refuse("promotion metadata artifact could not be synced");
  close($output) or refuse("promotion metadata artifact could not be closed");
}

my $data_path = $ENV{FM_RECEIPT_STORE_DATA};
$data_path = getcwd() . "/" . $data_path unless $data_path =~ m{^/};
my @components = grep { length($_) } split(m{/+}, $data_path);
refuse("data directory path is unsafe") if !@components || grep { $_ eq "." || $_ eq ".." } @components;
sysopen(my $root, "/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
  or refuse("absolute root could not be pinned");
chdir("/") or refuse("absolute root could not be entered");
my @pins = ($root);
for my $component (@components) {
  sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or refuse("data path component is missing or unsafe: $component");
  my @next_identity = stat($next);
  refuse("data path component is not a directory: $component") unless @next_identity && S_ISDIR($next_identity[2]);
  my @named_next_identity = lstat($component);
  refuse("data path component identity changed: $component") unless @named_next_identity
    && !S_ISLNK($named_next_identity[2])
    && $named_next_identity[0] == $next_identity[0]
    && $named_next_identity[1] == $next_identity[1];
  chdir($component) or refuse("data path component could not be entered safely: $component");
  my @cwd_identity = stat(".");
  refuse("data path component identity changed after entry: $component") unless @cwd_identity
    && $cwd_identity[0] == $next_identity[0]
    && $cwd_identity[1] == $next_identity[1];
  push @pins, $next;
}

my $task_name = $ENV{FM_RECEIPT_STORE_ID};
sysopen(my $task, $task_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
  or refuse("task directory is missing or unsafe: $task_name");
my @task_identity = stat($task);
refuse("task path is not a directory") unless @task_identity && S_ISDIR($task_identity[2]);
my @named_identity = lstat($task_name);
refuse("task directory identity changed") unless @named_identity
  && !S_ISLNK($named_identity[2])
  && $named_identity[0] == $task_identity[0]
  && $named_identity[1] == $task_identity[1];
chdir($task_name) or refuse("task directory could not be entered safely");
my @cwd_identity = stat(".");
refuse("task directory identity changed after entry") unless @cwd_identity
  && $cwd_identity[0] == $task_identity[0]
  && $cwd_identity[1] == $task_identity[1];

sysopen(my $brief, "brief.md", O_RDONLY | O_NOFOLLOW)
  or refuse("task brief is missing or unsafe");
my @brief_identity = stat($brief);
refuse("task brief is not a regular file") unless @brief_identity && S_ISREG($brief_identity[2]);
my $task_lock;
my $lock_created = 0;
if ($ENV{FM_RECEIPT_STORE_MODE} eq "promote") {
  if (!sysopen($task_lock, ".evidence.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)) {
    if ($! == EEXIST) {
      sysopen($task_lock, ".evidence.lock", O_RDWR | O_NOFOLLOW, 0600)
        or refuse("task evidence lock is missing or unsafe");
    } else {
      refuse("task evidence lock is missing or unsafe");
    }
  } else {
    $lock_created = 1;
  }
} else {
  sysopen($task_lock, ".evidence.lock", O_RDWR | O_NOFOLLOW, 0600)
    or refuse("task evidence lock is missing or unsafe");
}
my @lock_identity = stat($task_lock);
refuse("task evidence lock must be a single-link regular file") unless @lock_identity
  && S_ISREG($lock_identity[2]) && $lock_identity[3] == 1;

if ($ENV{FM_RECEIPT_STORE_MODE} eq "hold") {
  flock($task_lock, LOCK_SH) or refuse("task evidence lock could not be acquired");
  my $ledger_missing = 0;
  my $ledger;
  if (!sysopen($ledger, "evidence.jsonl", O_RDONLY | O_NOFOLLOW)) {
    $ledger_missing = 1 if $! == ENOENT;
    refuse("evidence ledger is missing or unsafe") unless $ledger_missing;
  }
  if (!$ledger_missing) {
    my @ledger_identity = stat($ledger);
    refuse("evidence ledger must be a single-link regular file") unless @ledger_identity
      && S_ISREG($ledger_identity[2]) && $ledger_identity[3] == 1;
  }
  sysopen(my $release, $arg4, O_RDWR | O_NOFOLLOW)
    or refuse("evidence ledger release channel is unsafe");
  copy_file($brief, $arg1);
  copy_file($ledger, $arg2) unless $ledger_missing;
  publish_ready($ledger_missing ? 3 : 0)
    or refuse("snapshot readiness could not be published");
  scalar(<$release>);
  exit($ledger_missing ? 3 : 0);
}

if ($ENV{FM_RECEIPT_STORE_MODE} eq "promote") {
  flock($task_lock, LOCK_EX) or refuse("task evidence lock could not be acquired");
  my @current_named_lock = lstat(".evidence.lock");
  refuse("task evidence lock identity changed") unless @current_named_lock
    && !S_ISLNK($current_named_lock[2])
    && $current_named_lock[0] == $lock_identity[0]
    && $current_named_lock[1] == $lock_identity[1];
  sysopen(my $random, "/dev/urandom", O_RDONLY | O_NOFOLLOW)
    or refuse("promotion nonce source is unavailable");
  my $nonce_bytes;
  my $nonce_read = sysread($random, $nonce_bytes, 16);
  refuse("promotion nonce could not be read") unless defined($nonce_read) && $nonce_read == 16;
  close($random) or refuse("promotion nonce source could not be closed");
  my $token = unpack("H*", $nonce_bytes);
  my ($command, @command_args) = @ARGV;
  my $state_path = $ENV{FM_STATE_OVERRIDE} // "";
  refuse("promotion state directory path is unsafe") unless $state_path =~ m{^/};
  my @state_components = grep { length($_) } split(m{/+}, $state_path);
  refuse("promotion state directory path is unsafe") if !@state_components
    || grep { $_ eq "." || $_ eq ".." } @state_components;
  chdir("/") or refuse("absolute root could not be entered for promotion state");
  my @state_pins;
  my $state;
  for my $component (@state_components) {
    sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      or refuse("state path component is missing or unsafe: $component");
    my @next_identity = stat($next);
    refuse("state path component is not a directory: $component") unless @next_identity && S_ISDIR($next_identity[2]);
    my @named_next_identity = lstat($component);
    refuse("state path component identity changed: $component") unless @named_next_identity
      && !S_ISLNK($named_next_identity[2])
      && $named_next_identity[0] == $next_identity[0]
      && $named_next_identity[1] == $next_identity[1];
    chdir($component) or refuse("state path component could not be entered safely: $component");
    my @entered_identity = stat(".");
    refuse("state path component identity changed after entry: $component") unless @entered_identity
      && $entered_identity[0] == $next_identity[0]
      && $entered_identity[1] == $next_identity[1];
    push @state_pins, $next;
    $state = $next;
  }
  my $meta_name = "$task_name.meta";
  sysopen(my $meta, $meta_name, O_RDONLY | O_NOFOLLOW)
    or refuse("promotion task metadata is missing or unsafe");
  my @meta_identity = stat($meta);
  refuse("promotion task metadata must be a single-link regular file") unless @meta_identity
    && S_ISREG($meta_identity[2]) && $meta_identity[3] == 1;
  local $/;
  my $meta_text = <$meta>;
  defined($meta_text) or refuse("promotion task metadata could not be read");
  my @kinds = ($meta_text =~ /^kind=(.*)$/mg);
  refuse("task is not a scout task") unless @kinds == 1 && $kinds[0] eq "scout";
  my $mode = $command_args[1] // "";
  my $yolo = $command_args[2] // "";
  my $new_meta = $meta_text;
  $new_meta =~ s/^(?:kind|mode|yolo)=.*\n?//mg;
  $new_meta .= "\n" if length($new_meta) && $new_meta !~ /\n\z/;
  $new_meta .= "kind=ship\nmode=$mode\nyolo=$yolo\n";
  my $meta_temp = ".$task_name.meta.promote.$token";
  my $meta_backup = ".$task_name.meta.original.$token";
  my $meta_restore = ".$task_name.meta.restore.$token";
  write_new_file($meta_backup, $meta_text);
  write_new_file($meta_temp, $new_meta);
  write_new_file($meta_restore, $meta_text);
  chdir($task) or refuse("pinned task directory could not be re-entered");
  my $status = system($command, "prepare", @command_args, $token);
  my $meta_replaced = 0;
  if ($status == 0) {
    chdir($state) or refuse("pinned state directory could not be re-entered");
    my @named_meta_identity = lstat($meta_name);
    if (@named_meta_identity
      && !S_ISLNK($named_meta_identity[2])
      && $named_meta_identity[0] == $meta_identity[0]
      && $named_meta_identity[1] == $meta_identity[1]
      && rename($meta_temp, $meta_name)) {
      $meta_replaced = 1;
    } else {
      $status = -1;
    }
    chdir($task) or refuse("pinned task directory could not be re-entered");
  }
  if ($status == 0 && $meta_replaced && $task->sync && $state->sync) {
    my $finalize_status = system($command, "finalize", @command_args, $token);
    if ($finalize_status == 0) {
      chdir($state) or refuse("pinned state directory could not be re-entered");
      unlink($meta_backup);
      unlink($meta_temp);
      unlink($meta_restore);
      $state->sync or refuse("promoted state directory could not be synced");
      exit 0;
    }
    $status = $finalize_status;
  }
  my $meta_rollback = 1;
  if ($meta_replaced) {
    chdir($state) or refuse("pinned state directory could not be re-entered");
    if (rename($meta_restore, $meta_name)) {
      $meta_rollback = 1;
    } else {
      $meta_rollback = 0;
    }
    chdir($task) or refuse("pinned task directory could not be re-entered");
  }
  my $rollback_status = system($command, "rollback", @command_args, $token);
  my $rollback_synced = $meta_rollback && $rollback_status == 0 && $task->sync && $state->sync;
  my $cleanup_status = $rollback_synced
    ? system($command, "cleanup", @command_args, $token)
    : -1;
  if ($rollback_synced && $cleanup_status == 0) {
    chdir($state) or refuse("pinned state directory could not be re-entered");
    unlink($meta_backup);
    unlink($meta_temp);
    unlink($meta_restore);
    $state->sync or refuse("rolled-back state directory could not be synced");
    chdir($task) or refuse("pinned task directory could not be re-entered");
  }
  if ($lock_created && $rollback_synced && $cleanup_status == 0) {
    my @owned_named_lock = lstat(".evidence.lock");
    unlink(".evidence.lock") if @owned_named_lock
      && !S_ISLNK($owned_named_lock[2])
      && $owned_named_lock[0] == $lock_identity[0]
      && $owned_named_lock[1] == $lock_identity[1];
    $task->sync;
  }
  exit 1 unless $rollback_synced && $cleanup_status == 0;
  exit 1 if $status == -1 || ($status & 127);
  my $exit_code = $status >> 8;
  exit($exit_code == 0 ? 1 : $exit_code);
}

my $criterion = $arg1;
my $parser = $arg2;
flock($task_lock, LOCK_EX) or refuse("task evidence lock could not be acquired");
sysopen(my $ledger, "evidence.jsonl", O_RDONLY | O_NOFOLLOW)
  or refuse("evidence ledger is missing or unsafe");
my @ledger_identity = stat($ledger);
refuse("evidence ledger must be a single-link regular file") unless @ledger_identity
  && S_ISREG($ledger_identity[2]) && $ledger_identity[3] == 1;

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
sysopen(my $random, "/dev/urandom", O_RDONLY | O_NOFOLLOW)
  or refuse("temporary evidence nonce source is unavailable");
my $nonce_bytes;
my $nonce_read = sysread($random, $nonce_bytes, 16);
refuse("temporary evidence nonce could not be read") unless defined($nonce_read) && $nonce_read == 16;
close($random) or refuse("temporary evidence nonce source could not be closed");
my $temp_name = ".evidence.tmp." . unpack("H*", $nonce_bytes);
$append_tmp = $temp_name;
sysopen(my $temp, $temp_name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
  or refuse("temporary evidence ledger could not be created");
my $buffer;
while (1) {
  my $read = sysread($ledger, $buffer, 65536);
  next if !defined($read) && $! == EINTR;
  refuse("evidence ledger could not be copied") unless defined($read);
  last if $read == 0;
  my $offset = 0;
  while ($offset < $read) {
    my $written = syswrite($temp, $buffer, $read - $offset, $offset);
    next if !defined($written) && $! == EINTR;
    refuse("evidence ledger copy failed") unless defined($written) && $written > 0;
    $offset += $written;
  }
}
my $record_offset = 0;
while ($record_offset < length($record)) {
  my $written = syswrite($temp, $record, length($record) - $record_offset, $record_offset);
  next if !defined($written) && $! == EINTR;
  refuse("evidence receipt write failed") unless defined($written) && $written > 0;
  $record_offset += $written;
}
$temp->sync or refuse("temporary evidence ledger could not be synced");
my @temp_identity = stat($temp);
refuse("temporary evidence ledger must be a single-link regular file") unless @temp_identity
  && S_ISREG($temp_identity[2]) && $temp_identity[3] == 1;
close($temp) or refuse("temporary evidence ledger close failed");
rename($temp_name, "evidence.jsonl") or refuse("evidence ledger replacement failed");
$append_tmp = undef;
$task->sync or refuse("task directory could not be synced");
PERL
