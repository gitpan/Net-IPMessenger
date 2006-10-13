#!/usr/bin/perl

use strict;
use warnings;
use Encode qw /encode decode from_to/;
use Encode::Guess;
use IO::Select;
use IO::Handle;
use IO::Interface qw/:flags/;
use Sys::Hostname;
use Term::Encoding qw(term_encoding);
use Net::IPMessenger::CommandLine;
use Net::IPMessenger::ToStdoutEventHandler;

use constant TIMEOUT => 3;
use constant {
    NICKNAME  => 'ipmsg',
    GROUPNAME => 'ipmsg',
    USERNAME  => 'ipmsg',
    HOSTNAME  => hostname,
};

$SIG{INT} = 'ignore';
STDOUT->autoflush(1);

my $version  = "0.06";
my $encoding = term_encoding;

my $ipmsg = Net::IPMessenger::CommandLine->new(
    NickName  => to_sjis(NICKNAME),
    GroupName => to_sjis(GROUPNAME),
    UserName  => USERNAME,
    HostName  => HOSTNAME,
    Debug     => 1,
) or die "cannot new Net::IPMessenger::CommandLine : $!\n";

my( $serveraddr, $broadcast ) = get_if($ipmsg);
die "get serveraddr failed\n" unless $serveraddr;

$ipmsg->always_secret(1);
$ipmsg->serveraddr($serveraddr);
$ipmsg->add_broadcast($broadcast);
$ipmsg->add_event_handler( new Net::IPMessenger::ToStdoutEventHandler );

my $socket = $ipmsg->get_connection;
my $select = IO::Select->new( $socket, \*STDIN );

local $SIG{ALRM} = sub {
    $ipmsg->flush_sendings;
    alarm( TIMEOUT + 1 );
};
alarm( TIMEOUT + 1 );

prompt();
while (1) {
    my @ready = $select->can_read(TIMEOUT);

    for my $handle (@ready) {
        # stdin
        if ( $handle eq \*STDIN ) {
            my $msg = $handle->getline or next;
            chomp $msg;
            unless ( length $msg > 0 ) {
                $msg = 'read';
            }

            my( $cmd, @options ) = split /\s+/, to_sjis($msg);
            if ( $ipmsg->is_writing ) {
                $ipmsg->writing($cmd);
                next;
            }
            if ( $ipmsg->can($cmd) ) {
                if ( $cmd eq 'can' or $cmd eq 'isa' or $cmd eq 'VERSION' ) {
                    prompt("command not supported");
                    next;
                }
                $msg = $ipmsg->$cmd(@options);
            }
            else {
                prompt("command unknown");
                next;
            }
            from_to( $msg, 'shiftjis', $encoding );
            if ( defined $msg ) {
                print $msg, "\n";
                exit if $msg eq 'exiting';
            }
            prompt( "", $ipmsg );
        }
        # socket
        elsif ( $handle eq $socket ) {
            $ipmsg->recv;
            alarm( TIMEOUT + 1 );
        }
    }
}

######################################################################
# Sub Routine
######################################################################

sub get_if {
    my $socket = shift->socket;

    for my $if ( $socket->if_list ) {
        my $flags = $socket->if_flags($if);
        next if $flags & IFF_LOOPBACK;
        next unless $flags & IFF_BROADCAST;

        my $serveraddr = $socket->if_addr($if);
        my $broadcast  = $socket->if_broadcast($if);

        if ( $serveraddr and $broadcast ) {
            return ( $serveraddr, $broadcast );
        }
    }
    return;
}

sub to_sjis {
    my $str = shift;
    my $enc = guess_encoding( $str, qw/euc-jp shiftjis 7bit-jis/ );

    my $name;
    if ( ref($enc) ) {
        $name = $enc->name;
        if ( $name ne 'shiftjis' and $name ne 'ascii' ) {
            from_to( $str, $name, 'shiftjis' );
        }
    }
    else {
        from_to( $str, $encoding, 'shiftjis' );
    }

    return $str;
}

sub prompt {
    my $msg = shift;
    printf "%s\n", $msg if $msg;
    printf "ipmsg> ";
}
