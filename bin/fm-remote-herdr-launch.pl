#!/usr/bin/perl
# bin/fm-remote-herdr-launch.pl - run a herdr server as its own session leader
# under the macOS launch agent dev.firstmate.herdr.fm-remote.
#
# Usage: fm-remote-herdr-launch.pl <herdr> server --session <name>
#
# launchd makes the job's top process a process-group leader but not a session
# leader. Herdr reports detached_server_daemon only when getsid(0) == getpid(),
# and saved machines refuse a server that reports false. setsid() fails in a
# process-group leader, so the top process forks: the child calls setsid() and
# execs herdr, which keeps its pid, so the server is its own session leader.
#
# The top process stays as the job's supervisor. It forwards TERM, INT, and HUP
# to the server, sends KILL after 10 seconds if the server ignores them, and
# exits non-zero once the server exits. KeepAlive then restarts the job, and the
# launch agent's ThrottleInterval bounds the restart rate. The top process never
# exits early, so there is no fork-and-exit respawn loop.
#
# Residual: a SIGKILL of the top process cannot be forwarded, so the server
# would outlive it. Stop the job with launchctl bootout, which sends TERM.
use strict;
use warnings;
use POSIX ();
use Errno qw(EINTR);

@ARGV or die "usage: $0 <herdr> [args...]\n";
my @cmd = @ARGV;
my $child = fork();
defined $child or die "fork: $!\n";

if ($child == 0) {
    $SIG{$_} = 'DEFAULT' for qw(TERM INT HUP ALRM);
    POSIX::setsid() or do { print STDERR "setsid: $!\n"; POSIX::_exit(126) };
    exec { $cmd[0] } @cmd or do { print STDERR "exec $cmd[0]: $!\n"; POSIX::_exit(127) };
}

my $forward = sub {
    my ($sig) = @_;
    kill $sig, $child;
    alarm 10;
};
$SIG{TERM} = sub { $forward->('TERM') };
$SIG{INT}  = sub { $forward->('INT') };
$SIG{HUP}  = sub { $forward->('HUP') };
$SIG{ALRM} = sub { kill 'KILL', $child };

my $status;
while (1) {
    my $reaped = waitpid($child, 0);
    if ($reaped == $child) {
        $status = $?;
        last;
    }
    next if $reaped == -1 && $! == EINTR;
    last;
}
alarm 0;

defined $status or exit 1;
if ($status & 127) {
    exit 128 + ($status & 127);
}
my $code = $status >> 8;
exit($code ? $code : 1);
