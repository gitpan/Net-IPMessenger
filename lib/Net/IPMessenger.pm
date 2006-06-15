package Net::IPMessenger;

use warnings;
use strict;
use Carp;
use IO::Socket::INET;
use Net::IPMessenger::ClientData;
use Net::IPMessenger::RecvEventHandler;
use Net::IPMessenger::MessageCommand;

use base qw /Class::Accessor::Fast/;

__PACKAGE__->mk_accessors(
    qw/
        packet_count    user        message         nickname    groupname
        username        hostname    socket          serveraddr  broadcast
        event_handler   debug
        /
);

our $VERSION = '0.01';

our $PROTO      = 'udp';
our $PORT       = 2425;
our $MSG_LENGTH = 5000;

sub new {
    my $class = shift;
    my %args  = @_;

    my $self = {};
    bless $self, $class;

    $self->packet_count(0);
    $self->user( {} );
    $self->message(       [] );
    $self->event_handler( [] );

    $self->nickname( $args{NickName} )     if $args{NickName};
    $self->groupname( $args{GroupName} )   if $args{GroupName};
    $self->username( $args{UserName} )     if $args{UserName};
    $self->hostname( $args{HostName} )     if $args{HostName};
    $self->serveraddr( $args{ServerAddr} ) if $args{ServerAddr};
    $self->debug( $args{Debug} )           if $args{Debug};
    $self->broadcast( $args{BroadCast} || '255.255.255.255' );

    my $sock = IO::Socket::INET->new(
        Proto     => $PROTO,
        LocalPort => $args{Port} || $PORT,
        )
        or return;

    $self->socket($sock);
    $self->add_event_handler( new Net::IPMessenger::RecvEventHandler );

    return $self;
}

sub get_connection {
    shift->socket;
}

sub add_event_handler {
    my $self = shift;
    push @{ $self->event_handler }, shift;
}

sub recv {
    my $self = shift;
    my $sock = $self->socket;

    my $msg;
    $sock->recv( $msg, $MSG_LENGTH ) or croak "recv: $!\n";
    my $peeraddr = inet_ntoa( $sock->peeraddr );
    my $peerport = $sock->peerport;
    # ignore yourself
    if ( $self->serveraddr ) {
        return if ( $peeraddr eq $self->serveraddr );
    }

    my $user = Net::IPMessenger::ClientData->new(
        Message  => $msg,
        PeerAddr => $peeraddr,
        PeerPort => $peerport,
    );
    my $key = $user->key;

    # exists user
    if ( exists $self->user->{$key} ) {
        $self->user->{$key}->parse($msg);
    }
    # new user
    else {
        $self->user->{$key} = $user;
    }

    # invoke event handler
    my $ev_handler = $self->event_handler;
    if ( ref $ev_handler and ref $ev_handler eq 'ARRAY' ) {
        for my $handler ( @{$ev_handler} ) {
            if ( $self->debug and $handler->can('debug') ) {
                $handler->debug( $self, $user );
            }

            my $command  = $self->messagecommand( $user->cmd );
            my $modename = $command->modename;
            $handler->$modename( $self, $user ) if $handler->can($modename);
        }
    }

    return $user;
}

sub parse_anslist {
    my $self     = shift;
    my $user     = shift;
    my $listaddr = shift;

    my @list  = split( /\a/, $user->option );
    my $title = shift(@list);
    my $count = shift(@list);

    my %present;
    my %new;
    for my $key ( keys %{ $self->user } ) {
        if ( defined $self->user->{$key}->listaddr
            and $listaddr eq $self->user->{$key}->listaddr )
        {
            $present{$key} = 1;
        }
    }

    while (1) {
        my $uname = shift @list or last;
        my $host  = shift @list or last;
        my $pnum  = shift @list or last;
        my $addr  = shift @list or last;
        my $com   = shift @list or last;
        my $nick  = shift @list or last;
        my $group = shift @list or last;

        if ( $self->serveraddr ) {
            next if ( $addr eq $self->serveraddr );
        }

        my $newuser = Net::IPMessenger::ClientData->new(
            Ver       => 1,
            PacketNum => $pnum,
            User      => $uname,
            Host      => $host,
            Command   => $com,
            Nick      => $nick,
            Group     => $group,
            PeerAddr  => $addr,
            PeerPort  => $PORT,
            ListAddr  => $listaddr,
        );
        my $newkey = $newuser->key;
        $self->user->{$newkey} = $newuser;
        $new{$newkey} = 1;
    }

    my @deleted;
    foreach my $pkey ( keys %present ) {
        unless ( exists $new{$pkey} ) {
            push @deleted, $self->user->{$pkey}->nickname;
            delete $self->user->{$pkey};
        }
    }
    return (@deleted);
}

sub send {
    my $self      = shift;
    my $cmd       = shift;
    my $option    = shift || '';
    my $broadcast = shift;
    my $peeraddr  = shift;
    my $peerport  = shift;
    my $sock      = $self->socket;

    my $msg = sprintf "1:%s:%s:%s:%s:%s", $self->packet_num, $self->username,
        $self->hostname, $cmd, $option;

    if ($broadcast) {
        $peeraddr = $self->broadcast;
        $sock->sockopt( SO_BROADCAST() => 1 )
            or croak "failed sockopt : $!\n";
    }
    elsif ( !defined $peeraddr ) {
        $peeraddr = inet_ntoa( $sock->peeraddr );
    }

    if ( !defined $peerport ) {
        $peerport = $sock->peerport || $PORT;
    }

    my $dest = sockaddr_in( $peerport, inet_aton($peeraddr) );
    $sock->send( $msg, 0, $dest )
        or croak "send() failed : $!\n";

    if ($broadcast) {
        $sock->sockopt( SO_BROADCAST() => 0 )
            or croak "failed sockopt : $!\n";
    }
}

sub messagecommand {
    my $self = shift;
    return Net::IPMessenger::MessageCommand->new(shift);
}

sub packet_num {
    my $self  = shift;
    my $count = $self->packet_count;
    $self->packet_count( ++$count );
    return ( time + $count );
}

sub my_info {
    my $self = shift;
    return sprintf "%s\0%s\0", $self->nickname, $self->groupname;
}

1;
__END__

=head1 NAME

Net::IPMessenger - Interface to the IP Messenger Protocol


=head1 VERSION

This document describes Net::IPMessenger version 0.0.1


=head1 SYNOPSIS

    use Net::IPMessenger;

    my $ipmsg = Net::IPMessenger->new(
        NickName  => 'myname',
        GroupName => 'mygroup',
        UserName  => 'myuser',
        HostName  => 'myhost',
    ) or die;

    $ipmsg->serveraddr($addr);
    $ipmsg->broadcast($broadcast);

    $ipmsg->send(...);

    ...

    $ipmsg->recv(...);

    ...


=head1 DESCRIPTION

This is a client class of the IP Messenger (L<http://www.ipmsg.org/>)
Protocol. Sending and Receiving the IP Messenger messages.


=head1 METHODS

=head2 new

    my $ipmsg = Net::IPMessenger->new(
        NickName   => $name,
        GroupName  => $group,
        UserName   => $user,
        HostName   => $host,
        ServerAddr => $server,
        Port       => $port,
        BroadCast  => $broadcast,
    ) or die;

Creates object, sets initial variables and create socket. When this returns
undef, it means you failed to create socket (i.e. port already in use).
Check $! to see the error reason.

=head2 get_connection

    my $socket = $ipmsg->get_connection;

Returns socket object.

=head2 add_event_handler

    $ipmsg->add_event_handler( new MyEventHandler );

Adds event handler. Handler method will be invoked when you $ipmsg->recv().

=head2 recv

    $ipmsg->recv;

Receives a message.

=head2 parse_anslist

    $ipmsg->parse_anslist( $message, $peeraddr );

Parses an ANSLIST to the list and stores it into the user list.

=head2 send

    $ipmsg->send( $cmd, $option, $broadcast, $peeraddr, $peerport );

Creates message from $cmd, $option. Then sends it to the $peeraddr:$peerport
(or gets the destination from the socket).

When $broadcast is defined, sends broadcast packet.

=head2 messagecommand

    my $command = $ipmsg->messagecommand('SENDMSG')->set_secret;

Creates Net::IPMessenger::MessageCommand object and returns it.

=head2 packet_num

    my $msg = sprintf "1:%s:%s:%s:%s:%s", $self->packet_num, $self->username,
        $self->hostname, $cmd, $option;

Increments packet count and returns it with current time.

=head2 my_info

    my $my_info = $self->my_info;

Returns information of yourself.

=head1 CONFIGURATION AND ENVIRONMENT

Net::IPMessenger requires no configuration files or environment variables.


=head1 DEPENDENCIES

None.


=head1 INCOMPATIBILITIES

None reported.


=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to
C<bug-net-ipmessenger@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

Masanori Hara  C<< <massa.hara@gmail.com> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2006, Masanori Hara C<< <massa.hara@gmail.com> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.
