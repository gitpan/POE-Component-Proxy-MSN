package POE::Component::Proxy::MSN;

# vim:set ts=4

use strict;
use vars qw($VERSION);
$VERSION = 0.01;

use vars qw(%users);

use Time::HiRes;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW 
	Filter::ProxyMSN Component::Proxy::MSN::Command);
use Socket qw(INADDR_ANY inet_ntoa AF_INET SOCK_STREAM AF_UNIX PF_UNIX);
use Errno qw(ECONNABORTED ECONNRESET EADDRINUSE);
use URI::Escape;

sub spawn {
    my($class, %args) = @_;
    $args{alias} ||= 'msn';

    # session for myself
    POE::Session->create(
		heap => { config => \%args },
		inline_states => {
		    _start => sub {
				my ($kernel, $heap) = @_[KERNEL, HEAP];
			    if (!defined($heap->{config}->{alias})) {
					$heap->{config}->{alias} = 'msnproxy';
				}
				$kernel->alias_set($heap->{config}->{alias});
			    $heap->{transaction} = 0;
			
				if (!defined($heap->{config}->{ip}) || lc($heap->{config}->{ip}) eq 'any') {
					$heap->{config}->{ip} = INADDR_ANY;
				}
				if (!defined($heap->{config}->{port})) {
					$heap->{config}->{port} = 1863;
				}
				
				# setup the listening socket
				$heap->{listener} = POE::Wheel::SocketFactory->new(
				    BindAddress    => $heap->{config}->{ip},	# Sets the bind() address
				    BindPort       => $heap->{config}->{port},	# Sets the bind() port
				    SuccessEvent   => '_client_connection',		# Event to emit upon accept()
				    FailureEvent   => '_sock_down',				# Event to emit upon error
				    SocketDomain   => AF_INET,					# Sets the socket() domain
				    SocketType     => SOCK_STREAM,				# Sets the socket() type
				    SocketProtocol => 'tcp',					# Sets the socket() protocol
			#		ListenQueue    => SOMAXCONN,       		    # The listen() queue length
				    Reuse          => 'on',						# Lets the port be reused
				);
				if ($! == EADDRINUSE) {
					# bind error!
					print STDERR "bind error: $!\n";
					$kernel->yield("shutdown");
				}
			},
		    _stop  => sub {},

			_child => sub {},

		    # internals
		    _client_connection => \&_client_connection,
			_sock_down => sub {
				my($kernel, $heap) = @_[KERNEL, HEAP];
				warn "sock is down, probably can't bind to ip/port\n";
				$kernel->yield(notify => 'sock_down');
			},
			
		    _unregister => sub {
				my ($kernel, $heap, $session) = @_[KERNEL, HEAP, ARG0];
				$kernel->refcount_decrement($session, __PACKAGE__);
				delete $heap->{listeners}->{$session};
			},
			
			_default => sub {
				my $arg = $_[ARG0];
#				print STDERR "unhandled event $_[ARG0] in ".__PACKAGE__." (main session)\n";
				return undef;
			},
		    
		    notify => sub {
				my ($kernel, $heap, $name, $data) = @_[KERNEL, HEAP, ARG0, ARG1];
				$kernel->post($_ => "msn_$name" => $data) for keys %{$heap->{listeners}};
			},
			
		    register   => sub {
				my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
				$kernel->refcount_increment($sender->ID, __PACKAGE__);
				$heap->{listeners}->{$sender->ID} = 1;
			},
			
		    unregister => sub {
				my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
				$kernel->yield(_unregister => $sender->ID);
			},

			shutdown => sub {
				my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
				$kernel->call($_ => 'shutdown') for keys %users;
				$kernel->refcount_increment($_, __PACKAGE__) for keys %{$heap->{listeners}};
				$kernel->alias_remove($heap->{config}->{args});
			},
			
			_toast => sub {
				my ($kernel, $heap, $session, $o) = @_[KERNEL, HEAP, SESSION, ARG0];	
				my $sid = $session->ID;
				my $kid = $kernel->ID;
				
				my $text = $o->{text};
				my $icon = ($o->{icon}) ? " icon=\"$o->{icon}\"" : '';
				my $action = ($o->{action_url}) ? "<ACTION url=\"$o->{action_url}\" />\r\n" : '';
				my $options = ($o->{options_url}) ? "<SUBSCR url=\"$o->{options_url}\" />\r\n" : '';
				my $siteurl = ($o->{site_url}) ? " siteurl=\"$o->{site_url}\"" : '';
				
				return qq|<NOTIFICATION ver="1" id="$kid" sessionid="$sid" siteid="12345"$siteurl>
<TO pid="0x00011C17:0x4C35719E" />
<MSG pri="1" id="1234">
$action$options<CAT id="123456" />
<BODY$icon>
<TEXT>$text</TEXT>
</BODY>
</MSG>
</NOTIFICATION>\r\n|;
#				return qq|<NOTIFICATION ver="1" id="$kid.$sid" siteid="12345" location_id="100" siteurl="http://teknikill.net">
#<TO pid="0x00011C17:0x4C35719E" />
#<MSG pri="1" id="1233">
#<ACTION url="/" />
#<SUBSCR url="/cgi-bin/msn.pl?subscribe=1" />
#<CAT id="123456" />
#<BODY>
#<TEXT>$text</TEXT>
#</BODY>
#</MSG>
#</NOTIFICATION>\r\n|;
			},
			toast => sub {
				my ($kernel, $heap, $session, $o) = @_[KERNEL, HEAP, SESSION, ARG0];	

				my $notification = $kernel->call($session->ID => _toast => $o);

				foreach my $sid (keys %users) {
					next unless ($users{$sid}{email});
					if ($o->{email}) {
						if (lc($users{$sid}{email}) eq $o->{email}) {
							$kernel->post($sid => send => POE::Component::Proxy::MSN::Command->new({},"NOT ".length($notification)."\r\n".$notification));
							last;
						}
						next;
					}
					$kernel->post($sid => send => POE::Component::Proxy::MSN::Command->new({},"NOT ".length($notification)."\r\n".$notification));
				}
			},
		},
    );
	
}

sub _client_connection {
    my ($kernel, $heap, $socket, $remote_addr, $remote_port) = @_[KERNEL, HEAP, ARG0, ARG1, ARG2];

	# Stolen and mangled from Server::TCP :) thanks
	POE::Session->create(
		heap => { config => $heap->{config} },
		inline_states => {
			_start => sub {
				my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];

				my $sid = $session->ID;
				$users{$sid}{connected} = time();
				
				$heap->{shutdown} = 0;
				# TODO keep this?
				$heap->{shutdown_on_error} = 1;

				if (defined $heap->{config}->{domain} and ($heap->{config}->{domain} == AF_UNIX or $heap->{config}->{domain} == PF_UNIX)) {
					$heap->{remote_ip} = "LOCAL";
				} elsif (length($remote_addr) == 4) {
					$heap->{remote_ip} = inet_ntoa($remote_addr);
				} else {
					$heap->{remote_ip} = Socket6::inet_ntop($heap->{config}->{domain}, $remote_addr);
				}

				$heap->{remote_port} = $remote_port;

				$heap->{client} = POE::Wheel::ReadWrite->new(
					Handle			=> $socket,
					Driver			=> POE::Driver::SysRW->new(),
					Filter			=> POE::Filter::ProxyMSN->new(),
					InputEvent		=> '_client_command',
					ErrorEvent		=> '_client_error',
					FlushedEvent	=> '_client_flush',
				);

				$kernel->sig(INT => 'sigint');

				# set a timer here and drop the connection
				# if they haven't logged in by then
				#$kernel->delay_set(_check_connection => $heap->{config}->{timeout});
			},
			_server_connection => sub {
			    my ($kernel, $heap, $session, $socket, $remote_addr, $remote_port) = @_[KERNEL, HEAP, SESSION, ARG0, ARG1, ARG2];
				my $sid = $session->ID;	
				
				$heap->{server} = POE::Wheel::ReadWrite->new(
					Handle			=> $socket,
					Driver			=> POE::Driver::SysRW->new(),
					Filter			=> POE::Filter::ProxyMSN->new(),
					InputEvent		=> '_server_command',
					ErrorEvent		=> '_server_error',
					FlushedEvent	=> '_server_flush',
				);
				delete $heap->{server_socket};
			},
			_server_sock_down => sub {
				my ($kernel, $heap) = @_[KERNEL, HEAP];
				# TODO shutdown on flush?
				$kernel->yield("shutdown");
			},
			_check_connection => sub {
				my ($kernel, $heap) = @_[KERNEL, HEAP];
				unless ($heap->{logged_in}) {
					$heap->{shutdown} = 1;
					$kernel->yield("shutdown");
				}
			},
			_child  => sub {},
			_server_command => \&server_command,
			_server_error => sub {
				unless ($_[ARG0] eq 'accept' and $_[ARG1] == ECONNABORTED) {
					if ($_[HEAP]->{shutdown_on_error}) {
						$_[HEAP]->{got_an_error} = 1;
						$_[KERNEL]->yield("shutdown");
					}
				}
			},
			_server_flush => sub {
				my ($kernel, $heap) = @_[KERNEL, HEAP];
				if (defined $heap->{shutdown_after_flush}) {
					$heap->{shutdown} = 1;
					$kernel->yield("shutdown");
				}
			},
			_client_command => \&client_command,
			_client_error => sub {
				unless ($_[ARG0] eq 'accept' and $_[ARG1] == ECONNABORTED) {
					if ($_[HEAP]->{shutdown_on_error}) {
						$_[HEAP]->{got_an_error} = 1;
						$_[KERNEL]->yield("shutdown");
					}
				}
			},
			_client_flush => sub {
				my ($kernel, $heap) = @_[KERNEL, HEAP];
				if (defined $heap->{shutdown_after_flush}) {
					$heap->{shutdown} = 1;
					$kernel->yield("shutdown");
				}
			},
			shutdown => sub {
				my $heap = $_[HEAP];
				$heap->{shutdown} = 1;
				if (defined $heap->{client}) {
					if ($heap->{got_an_error} or not $heap->{client}->get_driver_out_octets()) {
						if ($heap->{sb_session}) {
							$kernel->call($_[SESSION]->ID, "chat_client_disconnected");
						} else {
							$kernel->call($_[SESSION]->ID, "client_disconnected");
						}
					}
					delete $heap->{client};
				}
				if (defined $heap->{server}) {
					delete $heap->{server};
				}
			},
			_stop => sub {},
			_default => sub {
				my ($kernel, $heap, $name) = @_[KERNEL, HEAP, ARG0];
#				print STDERR "unhandled event $name in ".__PACKAGE__." (sub-session ".$_[SESSION]->ID.")\n";
#				unless (defined $heap->{logged_in}) {
#					$heap->{shutdown} = 1;
#					$kernel->yield("shutdown");
#				}
				return undef;
			},
			send => sub {
				# TODO keep this?
				return 0 if (defined($_[HEAP]->{shutdown_no_output}));
				
				if ($_[HEAP]->{client}) {
#					print STDERR "[to client] sending command\n";
					my $sid = $_[SESSION]->ID;
					eval {
						if ($_[HEAP]->{sb_session}) {
#							print STDERR "$sid - $users{$chat{$sid}{parent_session}}{email}>".$_[ARG0]->{name}." ".$_[ARG0]->{transaction}." ".$_[ARG0]->{data}."\n";
						} else {
#							print STDERR "$sid - $users{$sid}{email}>".$_[ARG0]->{name}." ".$_[ARG0]->{transaction}." ".$_[ARG0]->{data}."\n";
						}
						$_[HEAP]->{client}->put($_[ARG0]);
					};
					if ($@) {
#						print STDERR "error: $@\n";
						$_[HEAP]->{shutdown} = 1;
						$_[KERNEL]->yield("shutdown");
					}
				} else {
					$kernel->yield(send => splice(@_,ARG0));
				}
			},
			s_send => sub {
				# TODO keep this?
				return 0 if (defined($_[HEAP]->{shutdown_no_output}));
				
				if ($_[HEAP]->{server}) {
#					print STDERR "[to server] sending command\n";
					my $sid = $_[SESSION]->ID;
#					print STDERR "$sid + $users{$sid}{email}>".$_[ARG0]->{name}." ".$_[ARG0]->{transaction}." ".$_[ARG0]->{data}."\n";
					eval {
						$_[HEAP]->{server}->put($_[ARG0]);
					};
					if ($@) {
#						print STDERR "error: $@\n";
						$_[HEAP]->{shutdown} = 1;
						$_[KERNEL]->yield("shutdown");
					}
				} else {
					# que it
					$kernel->yield(s_send => splice(@_,ARG0));
				}
			},
			sigint => sub {
				my ($kernel, $heap, $session, $cmd) = @_[ KERNEL, HEAP, SESSION, ARG0 ];
				my $sid = $session->ID;
				$heap->{shutdown_after_flush} = 1;
				# Server Going Down!!
				#$kernel->call($sid => "send_OUT");
				return undef;
			},
			send_OUT => sub {
				my ($kernel, $heap, $session) = @_[ KERNEL, HEAP, SESSION ];
				my $sid = $session->ID;
				$heap->{shutdown_after_flush} = 1;
				# Signed in from another location
				my $subcmd = (defined($_[ARG0])) ? " $_[ARG0]" : ' SSD';
				if ($heap->{server}) {
					$subcmd = '';
				}
				$kernel->call($sid => send => POE::Component::Proxy::MSN::Command->new("OUT","$subcmd",{ no_trid => 1 }));
				return 1;
			},
			client_disconnected => \&client_disconnected,
			client_status_change => \&client_status_change,

			notify => sub {
				my ($kernel, $heap) = @_[KERNEL, HEAP];
				$kernel->call($heap->{config}->{alias} => notify => splice(@_,ARG0));
			},
		}
	);

	$kernel->yield(notify => got_connection => $socket);
}

#sub _sock_failed {
#    my($kernel, $heap) = @_[KERNEL, HEAP];
#    $kernel->yield(notify => socket_error => ());
#    for my $session (keys %{$heap->{listeners}}) {
#		$kernel->yield(_unregister => $session);
#    }
#}

# Command received from the MSN server

sub server_command {
	my($kernel, $heap, $session, $cmd) = @_[KERNEL, HEAP, SESSION, ARG0];
	my $sid = $session->ID;
	
	return 0 if ($heap->{shutdown});
   
	return 0 unless (ref($cmd) eq __PACKAGE__."::Command");
	
	# modify certain commands to suit us
	# XFR
#	if ($cmd->name eq 'XFR') {
#		if ($cmd->{data} =~ s/SB (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d+) CKI (.*)/SB $heap->{config}->{ip}:$heap->{config}->{port} CKI $3/) {
#			($users{$sid}{xfr_ip}, $users{$sid}{xfr_port}, $users{$sid}{xfr_cookie}) = ($1,$2,$3);
#		} else {
#			print STDERR "failed to alter XFR command, chat NOT proxied\n";
#		}
#	} elsif ($cmd->name eq 'RNG' && !$heap->{sb_session}) {
#		if ($cmd->{data} =~ s/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d+) CKI (\S+)/$heap->{config}->{ip}:$heap->{config}->{port} CKI $3/) {
#			($users{$sid}{xfr_ip}, $users{$sid}{xfr_port}, $users{$sid}{xfr_cookie}) = ($1,$2,$3);
#		} else {
#			print STDERR "failed to alter RNG command, chat NOT proxied [$cmd->{data}]\n";
#		}
#	} elsif ($cmd->name eq 'USR') {
	if ($cmd->name eq 'USR') {
#		print STDERR "debug:[".$cmd->{data}."]\n";
		#OK alice@passport.com Alice 1 0
		if ($cmd->{data} =~ m/OK (\S+\@\S+)/) {
#			print STDERR "ok\n";
			$users{$sid}{email} = $1;
			$users{$sid}{e_handle} = $2;
			$users{$sid}{handle} = URI::Escape::uri_unescape($2);
			$kernel->call($heap->{config}->{alias} => notify => logged_in => $cmd);
		}
	}
	
	if ($cmd->errcode) {
#		if ($heap->{sb_session}) {
#			print STDERR "$sid - $users{$chat{$sid}{parent_session}}{email} got error: ".$cmd->errcode;
#		} else {
#			print STDERR "$sid - $users{$sid}{email} got error: ".$cmd->errcode;
#		}
    } else {
		if ($heap->{sb_session}) {
#			print STDERR "$sid - $users{$chat{$sid}{parent_session}}{email}\<".$cmd->name." ".$cmd->transaction." ".join(' ',$cmd->args)."\n";
		} else {
#			print STDERR "$sid - $users{$sid}{email}\<".$cmd->name." ".$cmd->transaction." ".join(' ',$cmd->args)."\n";
			$users{$sid}{last_cmd} = $cmd;
		}
    }
	
	$kernel->call($heap->{config}->{alias} => notify => server_cmd => $cmd);
	$kernel->yield(send => $cmd);
}

# Command received from the MSN client

sub client_command {
	my($kernel, $heap, $session, $cmd) = @_[KERNEL, HEAP, SESSION, ARG0];
	my $sid = $session->ID;
	
	return 0 if ($heap->{shutdown});
   
	return 0 unless (ref($cmd) eq __PACKAGE__."::Command");

	if ($cmd->name eq 'VER' && !exists($users{$sid}{last_cmd})) {
		# 1st command is a VER?
		# setup the listening socket
		$heap->{server_socket} = POE::Wheel::SocketFactory->new(
		    RemoteAddress	=> $heap->{config}->{msn_server},	# Sets the bind() address
		    RemotePort		=> $heap->{config}->{msn_port},		# Sets the bind() port
		    SuccessEvent	=> '_server_connection',			# Event to emit upon accept()
		    FailureEvent	=> '_server_sock_down',				# Event to emit upon error
		    SocketDomain	=> AF_INET,							# Sets the socket() domain
		    SocketType		=> SOCK_STREAM,						# Sets the socket() type
		    SocketProtocol	=> 'tcp',							# Sets the socket() protocol
		    Reuse			=> 'yes',							# Lets the port be reused
		);

#	} elsif (($cmd->name eq 'USR' || $cmd->name eq 'ANS') && !exists($users{$sid}{last_cmd})) {
#		# 1st command is a USR? Its a SwitchBoard session
#		# USR 1 example@passport.com 17262740.1050826919.32308
#		if ($cmd->{data} =~ m/(\S+\@\S+) (\S+)/) {
#			foreach my $id (keys %users) {
#				next unless ($users{$id}{xfr_cookie} eq $2);
#				#$users{$sid}{email} = $1=;
#				$chat{$sid}{email} = $1;
#				$heap->{sb_session} = 1;
#				$heap->{server_socket} = POE::Wheel::SocketFactory->new(
#				    RemoteAddress	=> $users{$id}{xfr_ip},				# Sets the bind() address
#				    RemotePort		=> $users{$id}{xfr_port},			# Sets the bind() port
#				    SuccessEvent	=> '_server_connection',			# Event to emit upon accept()
#				    FailureEvent	=> '_server_sock_down',				# Event to emit upon error
#				    SocketDomain	=> AF_INET,							# Sets the socket() domain
#				    SocketType		=> SOCK_STREAM,						# Sets the socket() type
#				    SocketProtocol	=> 'tcp',							# Sets the socket() protocol
#				    Reuse			=> 'yes',							# Lets the port be reused
#				);
#				delete $users{$id}{xfr_ip};
#				delete $users{$id}{xfr_port};
#				delete $users{$id}{xfr_cookie};
#				last;
#			}
#		}
#		unless ($heap->{server_socket}) {
#			print STDERR "unable to find switchboard session for [$cmd->{data}]\n";
#			$kernel->yield("shutdown");
#		}
	}
	
	if ($cmd->errcode) {
#		if ($heap->{sb_session}) {
#			print STDERR "$sid - $users{$chat{$sid}{parent_session}}{email} got error: ".$cmd->errcode;
#		} else {
#			print STDERR "$sid - $users{$sid}{email} got error: ".$cmd->errcode;
#		}
    } else {
		if ($heap->{sb_session}) {
#			print STDERR "$sid - $users{$chat{$sid}{parent_session}}{email}\<".$cmd->name." ".$cmd->transaction." ".join(' ',$cmd->args)."\n";
		} else {
#			print STDERR "$sid - $users{$sid}{email}\<".$cmd->name." ".$cmd->transaction." ".join(' ',$cmd->args)."\n";
			$users{$sid}{last_cmd} = $cmd;
		}
    }
	
	$kernel->call($heap->{config}->{alias} => notify => client_cmd => $cmd);
	$kernel->yield(s_send => $cmd);
}

sub client_connected {
	my ($kernel, $heap, $session) = @_[ KERNEL, HEAP, SESSION ];
	my $sid = $session->ID;
	$users{$sid}{logged_in} = 0;
	$users{$sid}{sb_session} = 0;
	# TODO timeout
#	$kernel->delay_add( "client_timeout", $heap->{config}->{timeout} );
}

sub client_disconnected {
	my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
	my $sid = $session->ID;

	$heap->{shutdown_no_output} = 1;
	
	delete $users{$sid};

	$kernel->yield("shutdown");
	return;

}

1;

__END__

=head1 NAME

POE::Component::Proxy::MSN - POE Component that is an MSN Messenger server

=head1 SYNOPSIS

  use POE qw(Component::Proxy::MSN);

  # spawn MSN session
  POE::Component::Proxy::MSN->spawn(
	alias => 'msnproxy',            # Optional, default
	ip => 'any',                    # Optional, ip to bind to or any (default)
	port => 1863,                   # Optional, default
	msn_server => '207.46.106.79',  # Server to connect to, not optional
	msn_port => 1863,               # Just leave this at 1863, not optional
  );
  
  # register your session as MSN proxy observer in _start of a new session
  POE::Session->create(
  	inline_states => {
		_start => sub {
			$_[KERNEL]->post(msnproxy => 'register');
		}
		msn_logged_in => sub {
			my ($kernel, $cmd) = @_[KERNEL, ARG0];
			# tell them they are on the proxy, this is called when they log in
			if ($cmd->{data} =~ m/(\S+\@\S+)/) {
				$kernel->post(msnproxy => toast => {
					text => "MSN Proxy Active",
					site_url => 'http://teknikill.net/?MSNProxy',
					action_url => '/',
					options_url => '/',
					# not speciying email will toast all users 
					email => $1, # email targets a specific user that is logged in
				});
			}
		},
	}
  );

  $poe_kernel->run;


=head1 DESCRIPTION

POE::Component::Proxy::MSN is a POE component that proxys the MSN Messenger
service and allows you to send your own notifications (toasts).

=head1 SETUP

Windows:
(Backup your registry beforehand, I'm not responible for your actions)
Edit the registry, the key is HKEY_CURRENT_USER\Software\Microsoft\MSNMessenger\Server
change the value using the ip of the server, like this:
192.168.0.4;192.168.0.4:1863

Linux:
(Various clients)
Find where messenger.hotmail.com is specified, and change it to the ip of the server

=head1 TODO

msn_server and msn_port WILL go away in a future release, it will be automatic
connection timeouts

There might are some bugs, please report them.

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.   Use at your own risk.

=head1 SEE ALSO

See the examples directory for more ways to use this module.

L<POE>

=cut

__DATA__

ERROR CODES

200 Syntax error

201 Invalid parameter

205 Invalid user

206 Domain name missing

207 Already logged in

208 Invalid username

209 Invalid fusername

210 User list full

215 User already there (in conversation)

216 User not on list (or user already on list?)

217 User not online

218 Already in mode

219 User is in the opposite list

280 Switchboard failed

281 Transfer to switchboard failed

300 Required field missing

302 Not logged in

500 Internal server error

501 Database server error

502 (got this when sending FND cmd)

510 File operation failed

520 Memory allocation failed

600 Proxy is busy

601 Proxy is unavaliable

602 Peer nameserver is down

603 Database connection failed

604 Proxy is going down

707 Could not create connection

710 No version information for this client

711 Write is blocking

712 Session is overloaded

713 Too many active users

714 Too many sessions

715 Not expected

717 Bad friend file

911 Authentication failed

913 Not allowed when offline

920 Not accepting new users

924 * Passport account not yet verified

