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
# exits non-zero once the server exits. KeepAlive then restarts the job, and
# launchd's default throttle bounds the restart rate. The top process never
# exits early, so there is no fork-and-exit respawn loop.
#
# A SIGKILL of the top process cannot be forwarded, so the server outlives it.
# When the job restarts, the top process adopts a running detached server for
# the same command (its own process-group leader, same herdr name and
# arguments) instead of starting a second one that could not bind the session
# socket. It supervises the adopted pid the same way until it exits.
use strict;
use warnings;
use POSIX ();
use Errno qw(EINTR);
use File::Basename qw(basename);

@ARGV or die "usage: $0 <herdr> [args...]\n";
my @cmd = @ARGV;

sub find_detached_server {
    my $want = basename($cmd[0]);
    my $tail = join "\0", @cmd[1 .. $#cmd];
    open(my $ps, '-|', 'ps', '-A', '-o', 'pid=,pgid=,command=') or return;
    my $found;
    while (my $line = <$ps>) {
        my ($pid, $pgid, @argv) = split ' ', $line;
        next unless defined $pgid && $pid =~ /^\d+$/ && $pid == $pgid && $pid != $$;
        next unless @argv == @cmd && basename($argv[0]) eq $want;
        next unless join("\0", @argv[1 .. $#argv]) eq $tail;
        $found = $pid;
        last;
    }
    close $ps;
    return $found;
}

my $signals = POSIX::SigSet->new(POSIX::SIGTERM(), POSIX::SIGINT(), POSIX::SIGHUP());
POSIX::sigprocmask(POSIX::SIG_BLOCK(), $signals);

my $server = find_detached_server();
my $adopted = defined $server;
unless ($adopted) {
    $server = fork();
    defined $server or die "fork: $!\n";
    if ($server == 0) {
        $SIG{$_} = 'DEFAULT' for qw(TERM INT HUP ALRM);
        POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), $signals);
        POSIX::setsid() or do { print STDERR "setsid: $!\n"; POSIX::_exit(126) };
        exec { $cmd[0] } @cmd or do { print STDERR "exec $cmd[0]: $!\n"; POSIX::_exit(127) };
    }
}

my $forward = sub {
    my ($sig) = @_;
    kill $sig, $server;
    alarm 10;
};
$SIG{TERM} = sub { $forward->('TERM') };
$SIG{INT}  = sub { $forward->('INT') };
$SIG{HUP}  = sub { $forward->('HUP') };
$SIG{ALRM} = sub { kill 'KILL', $server };
POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), $signals);

if ($adopted) {
    sleep 1 while kill 0, $server;
    exit 1;
}

my $status;
while (1) {
    my $reaped = waitpid($server, 0);
    if ($reaped == $server) {
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
