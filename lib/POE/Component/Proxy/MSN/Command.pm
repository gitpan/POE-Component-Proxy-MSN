package POE::Component::Proxy::MSN::Command;
use strict;
use URI::Escape;
use Mail::Internet;

my %errors = (
	200 => 'INVALID_SYNTAX',
	201 => 'INVALID_PARAMETER',
	205 => 'INVALID_USER',
	206 => 'FQDN_MISSING',
	207 => 'ALREADY_LOGGED_IN',
	208 => 'INVALID_USERNAME',
	209 => 'INVALID_FRIENDLY_NAME',
	210 => 'USER_LIST_FULL',
	215 => 'USER_ALREADY_THERE',
	216 => 'USER_NOT_ON_LIST',
	217 => 'USER_NOT_ONLINE',
	218 => 'ALREADY_IN_MODE',
	219 => 'ALREADY_IN_OPPOSITE_LIST',
	224 => 'INVALID_GROUP',
	225 => 'USER_NOT_IN_GROUP',
	229 => 'GROUP_NAME_TOO_LONG',
	230 => 'CANNOT_REMOVE_GROUP_0',
	231 => 'INVALID_GROUP',
	280 => 'SWITCHBOARD_FAILED',
	281 => 'XFR_SWITCHBOARD_FAILED',
	300 => 'REQUIRED_FIELDS_MISSING',
	301 => 'TOO_MANY_RESULTS',
	302 => 'NOT_LOGGED_IN',
	500 => 'INTERNAL_SERVER',
	501 => 'DB_ERROR',
	502 => 'COMMAND_DISABLED',
	510 => 'FILE_OPERATION_FAILED',
	520 => 'MEMORY_ALLOC_FAILED',
	540 => 'CHL_RESPONSE_FAILED',
	600 => 'SERVER_BUSY',
	601 => 'SERVER_UNAVAILABLE',
	602 => 'PEER_NS_DOWN',
	603 => 'DB_CONNECT_FAILED',
	604 => 'SERVER_GOING_DOWN',
	707 => 'CREATE_CONNECTION',
	710 => 'BAD_CVR_LCID',
	711 => 'BLOCKING_WRITE',
	712 => 'SESSION_OVERLOAD',
	713 => 'TOO_MANY_ACTIVE_USERS',
	714 => 'TOO_MANY_SESSIONS',
	715 => 'NOT_EXPECTED',
	717 => 'BAD_FRIEND_FILE',
	731 => 'BAD_CVR_NOT_EXPECTED',
	800 => 'TOO_RAPID_NAME_CHANGE',
	910 => 'SERVER_TOO_BUSY',
	911 => 'AUTHENTICATION_FAILED',
	912 => 'SERVER_TOO_BUSY',
	913 => 'NOT_ALLOWED_WHEN_OFFLINE',
	914 => 'SERVER_UNAVAILABLE',
	915 => 'SERVER_UNAVAILABLE',
	916 => 'SERVER_UNAVAILABLE',
	917 => 'AUTHENTICATION_FAILED',
	918 => 'SERVER_TOO_BUSY',
	919 => 'SERVER_TOO_BUSY',
	920 => 'NOT_ACCEPTING_NEW_USERS',
	921 => 'SERVER_TOO_BUSY',
	922 => 'SERVER_TOO_BUSY',
	923 => 'NO_PARENTAL_CONSENT',
	924 => 'ACCOUNT_NOT_VERIFIED',
);

sub new {
	my($class, $name, $data, $stuff, $no_newline) = @_;
	my ($errcode, $errname, $transaction);
	
	if (ref($name)) {
		# send type of command
		my $no_trid = 0;
		if (exists($name->{transaction})) {
			$transaction = $name->{transaction};
		} else {
			$no_trid = 1;
		}
		if (ref($stuff)) {
			if (exists($stuff->{no_trid})) {
				$no_trid = 1;
			}
			if (exists($stuff->{no_newline})) {
				$no_newline = 1;
			}
		}
		if ($no_trid == 0) {
			unless ($data =~ s/ \^ / $transaction /) {
				$data .= " $transaction";
			}
		}
		if ($data =~ m/^(\d{3})/) {
			$errcode = $1;
			if (exists($errors{$errcode})) {
				$errname = $errors{$errcode};
			} else {
				$errname = 'UNKNOWN';
			}
		}
		if ($data =~ s/^(\S{3})\s//) {
			$name = $1;
		}
	} else {
		# recieve type of command
		$transaction = ref($stuff) eq 'HASH' ? $stuff->{transaction}++ : $stuff;

		# error is in \d\d\d
		if ($name =~ /^\d{3}$/) {
			$errcode = $name;
			if (exists($errors{$errcode})) {
				$errname = $errors{$errcode};
			} else {
				$errname = 'UNKNOWN';
			}
		}
	}
	
	my $t = bless {
		name        => $name,
		data        => $data,
		errcode     => $errcode,
		errname		=> $errname,
		transaction => $transaction,
		message     => undef,
		_args       => undef,
		no_newline  => $no_newline,
	}, $class;
	
	if ($name eq 'QRY' && defined $data) {
		$t->{qry} = $data;
	}

	return $t;
}

sub name { shift->{name} }
sub data { shift->{data} }
sub errcode { shift->{errcode} }
sub errname { shift->{errname} }
sub transaction { shift->{transaction} }
sub no_newline { shift->{no_newline} }

sub message {
	my $self = shift;
	if (@_) {
		#$self->{message} = Mail::Internet->new([ split /\r\n/, shift ]);
		$self->{message} = shift;
	}
	return $self->{message};
}

sub body {
	my $self = shift;
	my $message = Mail::Internet->new([ split /\r\n/, $self->message ]);
	return join '', map "$_\n", @{$message->body};
}

sub header {
	my($self, $key) = @_;
#	my $value = $self->message->head->get($key);
	my $value = Mail::Internet->new([ split /\r\n/, $self->message ])->head->get($key);
	chomp($value);
	return $value;
}

sub args {
	my $self = shift;
	$self->{_args} ||= [ map URI::Escape::uri_unescape($_), split / /, $self->data ];
	return wantarray ? @{$self->{_args}} : $self->{_args};
}

1;
