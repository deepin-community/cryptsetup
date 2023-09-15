# Mock terminal interaction on a guest system
#
# Copyright © 2021-2022 Guilhem Moulin <guilhem@debian.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use v5.14.2;
use warnings;
use strict;

our ($SERIAL, $CONSOLE, $MONITOR);
our $PS1 = qr/root\@[\-\.0-9A-Z_a-z]+ : [~\/][\-\.\/0-9A-Z_a-z]* [\#\$]\ /aax;

package CryptrootTest::Utils;

use Socket qw/PF_UNIX SOCK_STREAM SOCK_CLOEXEC SOCK_NONBLOCK SHUT_RD SHUT_WR/;
use Errno qw/EINTR ENOENT ECONNREFUSED/;
use Time::HiRes ();

my (%SOCKET, %BUFFER, $WBITS, $RBITS);

BEGIN {
    ($SERIAL, $CONSOLE, $MONITOR) = qw/ttyS0 hvc0 mon0/;
    my $dir = $ARGV[1] =~ m#\A(/\p{Print}+)\z# ? $1 : die "Invalid base directory\n"; # untaint
    my $epoch = Time::HiRes::time();
    foreach my $id ($SERIAL, $CONSOLE, $MONITOR) {
        my $path = $dir . "/" . $id;
        my $sockaddr = Socket::pack_sockaddr_un($path) // die;
        socket(my $socket, PF_UNIX, SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK, 0) or die "socket: $!";

        until (connect($socket, $sockaddr)) {
            if ($! == EINTR) {
                # try again immediatly if connect(2) was interrupted by a signal
            } elsif (($! == ENOENT or $! == ECONNREFUSED) and Time::HiRes::time() - $epoch < 30) {
                # wait a bit to give QEMU time to create the socket and mark it at listening
                Time::HiRes::usleep(100_000);
            } else {
                die "connect($path): $!";
            }
        }

        my $fd = fileno($socket) // die;
        vec($WBITS, $fd, 1) = 1;
        vec($RBITS, $fd, 1) = 1;
        $SOCKET{$id} = $socket;
        $BUFFER{$id} = "";
    }
}

sub read_data($) {
    my $bits = shift;
    while (my ($chan, $fh) = each %SOCKET) {
        next unless vec($bits, fileno($fh), 1); # nothing to read here
        my $n = sysread($fh, my $buf, 4096) // die "read: $!";
        if ($n > 0) {
            STDOUT->printflush($buf);
            $BUFFER{$chan} .= $buf;
        } else {
            #print STDERR "INFO done reading from $chan\n";
            shutdown($fh, SHUT_RD) or die "shutdown: $!";
            vec($RBITS, fileno($fh), 1) = 0;
        }
    }
}

sub expect(;$$) {
    my ($chan, $prompt) = @_;

    my $buffer = defined $chan ? \$BUFFER{$chan} : undef;
    if (defined $buffer and $$buffer =~ $prompt) {
        $$buffer = $' // die;
        return %+;
    }

    while(unpack("b*", $RBITS) != 0) {
        my $rout = $RBITS;
        while (select($rout, undef, undef, undef) == -1) {
            die "select: $!" unless $! == EINTR; # try again immediately if select(2) was interrupted
        }
        read_data($rout);
        if (defined $buffer and $$buffer =~ $prompt) {
            $$buffer = $' // die;
            return %+;
        }
    }
    #print STDERR "INFO done reading\n";
}

sub write_data($$%) {
    my $chan = shift;
    my $data = shift;

    my %options = @_;
    $options{echo} //= 1;
    $options{eol} //= "\r";
    $options{reol} //= "\r\n";
    my $wdata = $data . $options{eol};

    my $wfh = $SOCKET{$chan} // die;
    my $wfd = fileno($wfh) // die;
    vec(my $win, $wfd, 1) = 1;

    for (my $offset = 0, my $length = length($wdata); $offset < $length;) {
        my $wout = $win;
        while (select(undef, $wout, undef, undef) == -1) {
            die "select: $!" unless $! == EINTR; # try again immediately if select(2) was interrupted
        }
        if (vec($wout, $wfd, 1)) {
            my $n = syswrite($wfh, $wdata, $length - $offset, $offset) // die "write: $!";
            $offset += $n;
        }
    }

    my $rdata = $options{echo} ? $data : "";
    $rdata .= $options{reol};

    if ($rdata ne "") {
        my $buf = \$BUFFER{$chan};
        my $rfh = $SOCKET{$chan} // die;
        my $rfd = fileno($rfh) // die;
        vec(my $rin, $rfd, 1) = 1;

        my $rlen = length($rdata);
        while($rlen > 0) {
            my $rout = $rin;
            while (select($rout, undef, undef, undef) == -1) {
                die "select: $!" unless $! == EINTR; # try again immediately if select(2) was interrupted
            }
            read_data($rout);

            my $got = substr($$buf, 0, $rlen);
            my $n = length($got);
            if ($got eq substr($rdata, -$rlen, $n)) {
                $$buf = substr($$buf, $n); # consume the command
                $rlen -= $n;
            } else {
                my $a = substr($rdata, 0, -$rlen) . substr($rdata, -$rlen, $n);
                my $b = substr($rdata, 0, -$rlen) . $got;
                s/[^\p{Graph} ]/"\\x".unpack("H*",$&)/ge foreach ($a, $b);
                die "Wanted \"$a\", got \"$b\"";
            }
        }
    }
}

package CryptrootTest::Mock;

use Exporter qw/import/;
BEGIN {
    our @EXPORT = qw/
        unlock_disk
        login
        shell
        suspend
        wakeup
        hibernate
        poweroff
        expect
    /;
}

*expect     = \&CryptrootTest::Utils::expect;
*write_data = \&CryptrootTest::Utils::write_data;

sub unlock_disk($) {
    my $passphrase = shift;
    my %r = expect($SERIAL => qr/\A(?:.*(?:\r\n|\.\.\. ))?Please unlock disk (?<name>\p{Graph}+): \z/aams);
    if ((my $ref = ref($passphrase)) ne "") {
        my $name = $r{name};
        unless (defined $name) {
            undef $passphrase;
        } elsif ($ref eq "CODE") {
            $passphrase = $passphrase->($name);
        } elsif ($ref eq "HASH") {
            $passphrase = $passphrase->{$name};
        } else {
            die "Unsupported reference $ref";
        }
    }
    die "Unable to unlock, aborting.\n" unless defined $passphrase;
    write_data($SERIAL => $passphrase, echo => 0, reol => "\r");
}

sub login($;$) {
    my ($username, $password) = @_;
    expect($CONSOLE => qr/\r\ncryptroot-[[:alnum:]._-]+ login: \z/aams);
    write_data($CONSOLE => $username, reol => "\r");

    if (defined $password) {
        expect($CONSOLE => qr/\A[\r\n]*Password: \z/aams);
        write_data($CONSOLE => $username, echo => 0, reol => "\r");
    }

    # consume motd(5) or similar
    expect($CONSOLE => qr/\r\n $PS1 \z/aamsx);
}

sub shell($%);
sub shell($%) {
    my $command = shift;
    my %options = @_;

    write_data($CONSOLE => $command);
    my %r = expect($CONSOLE => qr/\A (?<out>.*) $PS1 \z/aamsx);
    my $out = $r{out};

    if (exists $options{rv}) {
        my $rv = shell(q{echo $?});
        unless ($rv =~ s/\r?\n\z// and $rv =~ /\A[0-9]+\z/ and $rv == $options{rv}) {
            my @loc = caller;
            die "ERROR: Command \`$command\` exited with status $rv != $options{rv}",
                " at line $loc[2] in $loc[1]\n";
        }
    }
    return $out;
}

# enter S3 sleep state (suspend to ram aka standby)
sub suspend() {
    write_data($CONSOLE => q{systemctl suspend});
    # while the command is asynchronous the system might suspend before
    # we have a chance to read the next $PS1

    # wait for the SUSPEND event
    QMP::wait_for_event("SUSPEND");

    # double check that the guest is indeed suspended
    my $resp = QMP::command(q{query-status});
    die unless defined $resp->{status} and  $resp->{status} eq "suspended" and
        defined $resp->{running} and $resp->{running} == JSON::false();
}

sub wakeup() {
    my $r = QMP::command(q{system_wakeup});
    die if %$r;

    # wait for the WAKEUP event
    QMP::wait_for_event("WAKEUP");

    # double check that the guest is indeed running
    my $resp = QMP::command(q{query-status});
    die unless defined $resp->{status} and  $resp->{status} eq "running" and
        defined $resp->{running} and $resp->{running} == JSON::true();
}

# enter S4 sleep state (suspend to disk aka hibernate)
sub hibernate() {
    # an alternative is to send {"execute":"guest-suspend-disk"} on the
    # guest agent socket, but we don't want to require qemu-guest-agent
    # on the guest so this will have to do
    write_data($CONSOLE => q{systemctl hibernate});
    # while the command is asynchronous the system might hibernate
    # before we have a chance to read the next $PS1
    QMP::wait_for_event("SUSPEND_DISK");
    expect();# wait for QEMU to terminate
}

sub poweroff() {
    # XXX would be nice to use the QEMU monitor here but the guest
    # doesn't seem to respond to system_powerdown QMP commands
    write_data($CONSOLE => q{poweroff});
    # while the command is asynchronous the system might shutdown
    # before we have a chance to read the next $PS1
    QMP::wait_for_event("SHUTDOWN");
    expect(); # wait for QEMU to terminate
}


package QMP;

# QMP protocol
# https://qemu.readthedocs.io/en/latest/interop/qemu-qmp-ref.html

use JSON ();

# read and decode a QMP server line
sub getline() {
    my %r = CryptrootTest::Utils::expect($MONITOR => qr/\A(?<str>.+?)\r\n/m);
    my $str = $r{str} // die;
    return JSON::->new->decode($str);
}

# send a QMP command and optional arguments
sub command($;$) {
    my ($command, $arguments) = @_;
    my $cmd = { execute => $command };
    $cmd->{arguments} = $arguments if defined $arguments;

    $cmd = JSON::->new->encode($cmd);
    STDOUT->printflush($cmd . "\n");
    CryptrootTest::Utils::write_data($MONITOR => $cmd, eol => "\r\n", echo => 0, reol => "");

    while(1) {
        my $resp = QMP::getline() // next;
        # ignore unsolicited server responses (such as events)
        return $resp->{return} if exists $resp->{return};
    }
}

# wait for the QMP greeting line
my @CAPABILITIES;
sub greeting() {
    my $greeting = QMP::getline() // die;
    $greeting = $greeting->{QMP} // die;
    @CAPABILITIES = @{$greeting->{capabilities}} if defined $greeting->{capabilities};
}

# negotiate QMP capabilities
sub capabilities(@) {
    my $r = QMP::command(qmp_capabilities => {enable => \@_});
    die if %$r;
}

BEGIN {
    # https://gitlab.com/qemu-project/qemu/-/blob/master/docs/interop/qmp-spec.txt sec 4
    QMP::greeting();
    QMP::capabilities();
}

sub wait_for_event($) {
    my $event_name = shift;
    while(1) {
        my $resp = QMP::getline() // next;
        return if exists $resp->{event} and $resp->{event} eq $event_name;
    }
}

sub quit() {
    # don't use QMP::command() here since we might never receive a response
    my $cmd = JSON::->new->encode({ execute => "quit" });
    STDOUT->printflush($cmd . "\n");
    CryptrootTest::Utils::write_data($MONITOR => $cmd, eol => "\r\n", echo => 0, reol => "");
    CryptrootTest::Utils::expect(); # wait for QEMU to terminate
}

1;
