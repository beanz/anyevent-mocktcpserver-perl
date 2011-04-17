use strict;
use warnings;
package AnyEvent::MockTCPServer;

# ABSTRACT: Mock TCP Server using AnyEvent

=head1 SYNOPSIS

  use AnyEvent::MockTCPServer qw/:all/;
  my $cv = AnyEvent->condvar;
  my $server =
    AnyEvent::MockTCPServer->new(connections =>
                                 [
                                  [ # first connection
                                   [ recv => 'HELLO', 'wait for "HELLO"' ],
                                   [ sleep => 0.1, 'wait 0.1s' ],
                                   [ code => sub { $cv->send('done') },
                                     'send "done" with condvar' ],
                                   [ send => 'BYE', 'send "BYE"' ],
                                   # ...
                                  ],
                                  [ # second connection
                                   # ...
                                  ]],
                                 # ...
                                );

=head1 DESCRIPTION

This module is intended to provide a mechanism to define a server that
will perform actions necessary to test a TCP client.  It is intended to
be use when testing AnyEvent TCP client interfaces.

=cut

1;

use constant {
  DEBUG => $ENV{ANYEVENT_MOCK_TCP_SERVER_DEBUG}
};
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Test::More;
use Sub::Name;

=method C<new(%parameters)>

Constructs a new L<AnyEvent::MockTCPServer> object.  The parameter hash
can contain values for the following keys:

=over

=item C<connections>

A list reference containing elements for each expected connection.
Each element is another list reference contain action elements.
Each action element is a list with an action method name and any
arguments to the action method.  By convention, the final argument
to the action method should be a description.  See the action
method descriptions for the other arguments.

=item C<host>

The host IP that the server should listen on.  Default is the IPv4
loopback address, C<127.0.0.1>.

=item C<port>

The port that the server should listen on.  Default is to pick a
free port.

=item C<timeout>

The timeout for IO operations in seconds.  Default is 2 seconds.

=item C<on_timeout>

The callback to call when a timeout occurs.  Default is to die
with message C<"server timeout\n">.

=back

=cut

sub new {
  my $pkg = shift;
  my $self =
    {
     connections => [],
     listening => AnyEvent->condvar,
     host => '127.0.0.1',
     port => undef,
     timeout => 2,
     on_timeout => subname('default_client_on_timeout_cb' =>
                           sub { die "server timeout\n"; }),
     @_
    };
  bless $self, $pkg;
  $self->{server} =
    tcp_server $self->{host}, $self->{port}, subname('accept_cb' =>
      sub {
        my ($fh) = @_;
        print STDERR "In server: $fh ", fileno($fh), "\n" if DEBUG;
        my $handle;
        $handle =
          AnyEvent::Handle->new(fh => $fh,
                                on_error => subname('client_on_error_cb_'.$fh =>
                                  sub {
                                    my ($hdl, $fatal, $msg) = @_;
                                    warn "error $msg\n";
                                    $self->{on_error}->(@_)
                                      if ($self->{on_error});
                                    $hdl->destroy;
                                  }),
                                timeout => $self->{timeout},
                                on_timeout => $self->{on_timeout},
                               );
      print STDERR "Connection handle: $handle\n" if DEBUG;
      $self->{handles}->{$handle} = $handle;
      my $con = $self->{connections};
      unless (@$con) {
        die "Server received unexpected connection\n";
      }
      my $actions = shift @$con;
      print STDERR "Actions: ", (scalar @$actions), "\n" if DEBUG;
      unless (@$con) {
        delete $self->{server};
      }
      $self->next_action($handle, $actions);
    }), subname('prepare_cb' => sub {
      my ($fh, $host, $port) = @_;
      die "tcp_server setup failed: $!\n" unless ($fh);
      $self->{listening}->send([$host, $port]);
      0;
    });
  return $self;
}

sub DESTROY {
  my $self = shift;
  delete $self->{listening};
  delete $self->{server};
  foreach (values %{$self->{handles}}) {
    next unless (defined $_);
    $_->destroy;
    delete $self->{handles}->{$_};
  }
}

=method C<listening()>

Condvar that is notified when the mock server is ready.  The value
received is an array reference containing the address and port that
the server is listening on.

=cut

sub listening {
  shift->{listening};
}

=method C<connect_address()>

An array reference containing the address and port that the server is
listening on.  This method blocks on the L</listening()> condvar until
the server is listening.

=cut

sub connect_address {
  @{shift->listening->recv};
}

=method C<connect_host()>

The address that the server is listening on.  This method blocks on
the L</listening()> condvar until the server is listening.

=cut

sub connect_host {
  shift->listening->recv->[0];
}

=method C<connect_port()>

The port that the server is listening on.  This method blocks on
the L</listening()> condvar until the server is listening.

=cut

sub connect_port {
  shift->listening->recv->[1];
}

=method C<connect_string()>

A string containing the address and port that the server is listening
on separated by a colon, 'C<:>'.  This method blocks on the
L</listening()> condvar until the server is listening.

=cut

sub connect_string {
  join ':', shift->connect_address
}

=method C<next_action($handle, $actions)>

Internal method called by the action methods when the server should
proceed with the next action.  Must be called by any action methods
written in subclasses of this class.

=cut

sub next_action {
  my ($self, $handle, $actions) = @_;
  print STDERR 'In handle connection ', scalar @$actions, "\n" if DEBUG;
  my $action = shift @$actions;
  unless (defined $action) {
    print STDERR "closing connection\n" if DEBUG;
    $handle->push_shutdown;
    delete $self->{handles}->{$handle};
    return;
  }
  my $method = shift @$action;
  print STDERR "executing action: ", $method, "\n" if DEBUG;
  $self->$method($handle, $actions, @$action);
}

=head1 ACTION METHODS

These methods (and methods added by derived classes) can be used in
action lists passed via the constructor C<connections> parameter.  The
C<handle> and C<actions> arguments should be omitted from the action
lists as they are supplied by the framework.

=method C<send($handle, $actions, $send, $desc)>

Sends the payload, C<send>, to the client.

=cut

sub send {
  my ($self, $handle, $actions, $send, $desc) = @_;
  print STDERR 'Sending: ', $send, ' ', $desc, "\n" if DEBUG;
  print STDERR 'Sending ', length $send, " bytes\n" if DEBUG;
  $handle->push_write($send);
  $self->next_action($handle, $actions);
}

=method C<packsend($handle, $actions, $send, $desc)>

Sends the payload, C<send>, to the client after removing whitespace
and packing it with 'H*'.  This method is equivalent to the
L</send($handle, $actions, $send, $desc)> method when passed the
packed string but debug messages contain the unpacked strings are
easier to read.

=cut

sub packsend {
  my ($self, $handle, $actions, $data, $desc) = @_;
  my $send = $data;
  $send =~ s/\s+//g;
  print STDERR 'Sending: ', $send, ' ', $desc, "\n" if DEBUG;
  $send = pack 'H*', $send;
  print STDERR 'Sending ', length $send, " bytes\n" if DEBUG;
  $handle->push_write($send);
  $self->next_action($handle, $actions);
}

=method C<recv($handle, $actions, $expect, $desc)>

Waits for the data C<expect> from the client.

=cut

sub recv {
  my ($self, $handle, $actions, $recv, $desc) = @_;
  print STDERR 'Waiting for ', $recv, ' ', $desc, "\n" if DEBUG;
  my $len = length $recv;
  print STDERR 'Waiting for ', $len, " bytes\n" if DEBUG;
  $handle->push_read(chunk => $len,
                     sub {
                       my ($hdl, $data) = @_;
                       print STDERR "In receive handler\n" if DEBUG;
                       is($data, $recv,
                          '... correct message received by server - '.$desc);
                       $self->next_action($hdl, $actions);
                       1;
                     });
}

=method C<packrecv($handle, $actions, $expect, $desc)>

Removes whitespace and packs the string C<expect> with 'H*' and then
waits for the resulting data from the client.  This method is
equivalent to the L</recv($handle, $actions, $expect, $desc)> method
when passed the packed string but debug messages contain the unpacked
strings are easier to read.

=cut

sub packrecv {
  my ($self, $handle, $actions, $data, $desc) = @_;
  my $recv = $data;
  $recv =~ s/\s+//g;
  my $expect = $recv;
  print STDERR 'Waiting for ', $recv, ' ', $desc, "\n" if DEBUG;
  my $len = .5*length $recv;
  print STDERR 'Waiting for ', $len, " bytes\n" if DEBUG;
  $handle->push_read(chunk => $len,
                     sub {
                       my ($hdl, $data) = @_;
                       print STDERR "In receive handler\n" if DEBUG;
                       my $got = uc unpack 'H*', $data;
                       is($got, $expect,
                          '... correct message received by server - '.$desc);
                       $self->next_action($hdl, $actions);
                       1;
                     });
}

=method C<sleep($handle, $actions, $interval, $desc)>

Causes the server to sleep for C<$interval> seconds.

=cut

sub sleep {
  my ($self, $handle, $actions, $interval, $desc) = @_;
  print STDERR 'Sleeping for ', $interval, ' ', $desc, "\n" if DEBUG;
  my $w;
  $w = AnyEvent->timer(after => $interval,
                       cb => sub {
                         $self->next_action($handle, $actions);
                         undef $w;
                       });
}

=method C<code($handle, $actions, $code, $desc)>

Causes the server to execute the code reference with the client handle
as the first argument.

=cut

sub code {
  my ($self, $handle, $actions, $code, $desc) = @_;
  print STDERR 'Executing ', $code, ' for ', $desc, "\n" if DEBUG;
  $code->($self, $handle, $desc);
  $self->next_action($handle, $actions);
}

1;
