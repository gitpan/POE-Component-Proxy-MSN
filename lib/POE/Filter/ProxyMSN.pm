package POE::Filter::ProxyMSN;
use strict;

use POE qw(Component::Proxy::MSN::Command);

use vars qw($Debug);
$Debug = 1;

sub Dumper { require Data::Dumper; local $Data::Dumper::Indent = 1; Data::Dumper::Dumper(@_) }

sub new {
    my $class = shift;
	my %opts = @_;
	my $o = {
		buffer => '',
		get_state => 'line',
		put_state => 'line',
		body_info => {},
		get_color => '36',
		put_color => '37',
		log => 'proto.log',
    };
	foreach (keys %opts) {
		$o->{$_} = $opts{$_};
	}
	bless($o, $class);
}

sub get {
	my ($self, $stream) = @_;

	# Accumulate data in a framing buffer.
	$self->{buffer} .= join('', @$stream);
	$Debug && do {
		open(FH,">>/tmp/$self->{log}");
		print FH "\e[$self->{get_color}m".join('', @$stream)."\e[0m";
		close(FH);
	};

	my $many = [];
	while (1) {
		my $input = $self->get_one([]);
		if ($input) {
			push(@$many,@$input);
		} else {
			last;
		}
	}

	return $many;
}

sub get_one_start {
	my ($self, $stream) = @_;

	$Debug && do {
		open(FH,">>/tmp/$self->{log}");
		print FH "\e[$self->{get_color}m".join('', @$stream)."\e[0m";
		close(FH);
	};
	# Accumulate data in a framing buffer.
	$self->{buffer} .= join('', @$stream);
}

sub get_one {
    my($self, $stream) = @_;
	
    return [] if ($self->{finish});
	
    my @commands;
    if ($self->{get_state} eq 'line') {
		return [] unless($self->{buffer} =~ m/\r\n/s);

		while (1) {
#			warn "buffer length is".length($self->{buffer})."\n";
#			#QRY 172 32
#			11322e15d877b1ac5df24c1f62bdc268
			if ($self->{buffer} =~ s/^(QRY) (\d+)\r\n//) {
				push @commands, POE::Component::Proxy::MSN::Command->new($1, undef, $2);
				last;
			}
			if ($self->{buffer} =~ s/^(QRY) (\d+) (?:([^\s]+) )?(\d+)\r\n//) {
				my $cmd = $1;
				my $seq = $2;
				my $extra = $3;
				my $len = $extra;
				if ($4) {
					#$extra .= " $4";
					$len = $4;
				}
				#QRY 56 PROD0061VRRZH@4F 32
				my $command = POE::Component::Proxy::MSN::Command->new($cmd, $extra, $seq, 1);
				$self->{get_state} = 'body';
				$self->{body_info} = {
				    command => $command,
				    length  => $len,
				};
				last;
			}
			if ($self->{buffer} =~ s/^(.{3})\r\n//) {
				push @commands, POE::Component::Proxy::MSN::Command->new($1);
				last;
			}
			if ($self->{buffer} =~ s/^(.{3}) (?:(\d+) )?(.*?)\r\n//) {
				#print STDERR "<[$1] [$2] [$3]\n";
				my $cmd = $1;
				my $seq = $2;
				my $extra = $3;
				if ($cmd eq 'INF') {
					$seq = $extra;
					$extra = undef;
				}
				my $command = POE::Component::Proxy::MSN::Command->new($cmd, $extra, $seq);
		    	if ($command->name eq 'MSG') {
					# switch to body
					#print STDERR "MSG_args:$extra:".join(',',@{$command->args})."\n";
					$self->{get_state} = 'body';
					$command->{extra_data} = $extra;
					$self->{body_info} = {
					    command => $command,
					    length  => (split(/ /,$command->data))[-1],
					};
					last;
				} else {
					push @commands, $command;
			    }
			} else {
				#warn "buffer length is".length($self->{buffer})." data:".$self->{buffer}."\n";
								#return [];
				last;
			}
		}
    }

	BODY: {
	    last unless ($self->{get_state} eq 'body');
			
		if (length($self->{buffer}) < $self->{body_info}->{length}) {
		    # not enough bytes
			last BODY;
		}
		my $message = substr($self->{buffer}, 0, $self->{body_info}->{length}, '');
		my $command = $self->{body_info}->{command};
		$command->{data} = $self->{body_info}->{length}."\r\n".$message;
		$command->message($message);
		push @commands, $command;
		
		# switch to line by line
		$self->{get_state} = 'line';
	}

#    $Debug and warn "<", Dumper \@commands;
    return \@commands;
}

sub put {
    my($self, $commands) = @_;
    my $put = [ map $self->_put($_), @$commands ];
#	my $tmp = ($self->{server}) ? 'S' : 'C';
#	$Debug and warn "$tmp>", @$put;
	return $put;
}

sub _put {
    my($self, $command) = @_;
#    $Debug and warn "PUT: ", Dumper $command."\r\n";
#	$Debug and warn "PUT: ".sprintf "%s %d %s%s",$command->name, $command->transaction, $command->data, ($command->no_newline ? '' : "\r\n");
#	return sprintf "%s %d %s%s",$command->name, $command->transaction, $command->data, ($command->no_newline ? '' : "\r\n");
#	print STDERR sprintf "%s%s",$command->data, ($command->no_newline ? '' : "\r\n");
	my $out = $command->name;
	if ($command->{transaction} ne '') {
		$out .= " ".$command->transaction;
	}
	if ($command->name eq 'MSG') {
		#print STDERR "msg:::::".join(',',(split(/ /,$command->data)))."\n";
		if ($command->{extra_data}) {
			$command->{extra_data} =~ s/ \d+$//;
			$out .= " ".$command->{extra_data};
		}
		#if ($#{$command->args} == 1) {
		#	$out .= " ".(split(/ /,$command->data))[0,1]." ";
		#} else {
		#	$out .= " ".(split(/ /,$command->data))[0];
		#}	
	} elsif ($command->name eq 'QRY' && exists($command->{qry})) {
		$out .= " ".$command->{qry};
	}
	$out .= sprintf "%s%s",($command->data eq '' ? '' : ' '.$command->data), ($command->no_newline ? '' : "\r\n");
	
	$Debug && do {
		open(FH,">>/tmp/$self->{log}");
		print FH "\e[$self->{put_color}m$out\e[0m";
		close(FH);
	};
	return $out;
}

sub get_pending {
	my $self = shift;
	return [ $self->{buffer} ] if length $self->{buffer};
	return undef;
}

1;

