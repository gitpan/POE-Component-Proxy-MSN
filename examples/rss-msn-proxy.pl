#!/usr/bin/perl

use warnings;
use strict;

use lib qw(./lib ../lib);

sub POE::Kernel::ASSERT_DEFAULT { $ENV{POE_ASSERT} || 0 }
sub POE::Kernel::TRACE_DEFAULT  { $ENV{POE_TRACE} || 0 }
sub POE::Kernel::TRACE_EVENTS   { $ENV{POE_EVENTS} || 0 }

use POE qw(Component::Proxy::MSN Component::TSTP Component::RSSAggregator);
use POSIX;

# for Ctrl-Z
POE::Component::TSTP->create();

my %config = (
	alias => 'msnproxy',
#	timeout => 30,
	pidfile => '/var/run/msn-proxy.pid',
	msn_server => '207.46.106.79',
	msn_port => 1863,
	debug => 1,
#	daemon => 1,
);

my @feeds = (
	{
		url	 => "http://lwn.net/headlines/rss",
		name  => "lwn",
		delay => 600,
	},
	{
		url => "http://slashdot.org/index.rss",
		name => "slashdot",
		delay => (60*60), # 1 hour, be nice to /.
	},
	{
		url => "http://www.wired.com/news_drop/netcenter/netcenter.rdf",
		name => "netcenter",
		delay => 560,
	},
	{
		url => "http://boingboing.net/rss.xml",
		name => "boingboing",
		delay => 620,
	},
	{
		url => "http://www.theregister.co.uk/tonys/slashdot.rdf",
		name => "theregister",
		delay => 590,
	},
	{
		url => "http://p.moreover.com/cgi-local/page?index_bookreviews+rss",
		name => "moreover",
		delay => 580,
	},
);

## Deal with arguments
foreach my $arg (@ARGV) {
	if (($arg eq '-r' || $arg eq '--restart') || ($arg eq '-x' || $arg eq '--exit')) {
		if (!-e $config{pidfile}) {
			die "Cannot exit, no pidfile";
		} else {
			open(FILE,"$config{pidfile}") || die "Can't open the file '$config{pidfile}'.Reason: $!\n";
			my $pid = (<FILE>)[0];
			close(FILE);
			if ($arg eq "-x" || $arg eq "--exit") {
				kill TERM => $pid;
				print "SIGTERM sent.\n";
			} else {
				kill HUP => $pid;
				print "SIGHUP sent.\n";
			}
			exit;
		}
	} elsif ($arg eq '-d' || $arg eq '--daemon') {
		$config{daemon} = 1;
	}
}

if (-e $config{pidfile}) {
	open(FILE,"$config{pidfile}") || die "Can't open the file '$config{pidfile}'.\nReason: $!\n";
	my $pid = (<FILE>)[0];
	close(FILE);
	if (kill(0,$pid)){
		print "Found existing server running with pid $pid, exiting. Hint, type '$0 --restart' to restart the server\n";
		exit;
	} else {
		print "Found existing pid file, but server not running under that pid, continuing...\n";
		unlink $config{pidfile};
	}
}

POE::Component::Proxy::MSN->spawn(%config);

POE::Session->create(
	inline_states =>  {
		_start => sub {
			my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
			
			# register this session as an MSN Proxy observer
			$kernel->call($config{alias} => 'register');

			$heap->{rssagg} = POE::Component::RSSAggregator->new(
				alias    => 'rssagg',
				debug    => $config{debug},
				callback => $session->postback("handle_feed"),
				tmpdir   => '/tmp', # optional caching
			);
			
		   $kernel->post(rssagg => add_feed => $_) for @feeds;
		},
		dotoast => sub {
			my ($kernel, $heap) = @_[KERNEL, HEAP];
				
				$kernel->post(msnproxy => toast => {
					text => "Test!",
				#	email => 'blah@domain.com', # target a specific user
					site_url => 'http://teknikill.net/',
					action_url => '/',
					options_url => '/options',
				#	icon => '',
				});
			#$kernel->delay_set(dotoast => 30);
		},
		_stop => sub { },
		msn_server_cmd => sub { }, # called with command obj as ARG0
		msn_client_cmd => sub { }, # called with command obj as ARG0
		msn_logged_in => sub {
			my ($kernel, $cmd) = @_[KERNEL, ARG0];
			
			if ($cmd->{data} =~ m/(\S+\@\S+)/) {
				$kernel->post(msnproxy => toast => {
					text => "MSN RSS Proxy Active",
					site_url => 'http://teknikill.net/',
					action_url => '/',
					options_url => '/',
					email => $1
				});
			}
		   # send a test message 30 seconds later
#		   $kernel->delay_set(dotoast => 30);
		},
		handle_feed => sub {
			my ($kernel, $arg) = @_[KERNEL, ARG1];
			
			my $feed = $arg->[0];
			
#			$config{debug} && do {
#				require Data::Dumper;
#				print STDERR Data::Dumper::Dumper(\$feed)."\n";
#			};
		
			for my $headline ($feed->late_breaking_news) {
				# do stuff with the XML::RSS::Headline object
				print "New headline: ".$headline->headline."\n" if $config{debug};
				
				$kernel->post(msnproxy => toast => {
					text => $feed->{title}." - ".$headline->headline,
					action_url => $headline->url,
					options_url => $feed->{link},
				#	email => 'blah@domain.com', # target a specific user
				#	site_url => '',
				#	icon => '',
				});
			}
			
		},
	},
);

print "Starting up proxy\n" if $config{debug};

if ($config{daemon}) {
	print "Daemonizing...\n" if $config{debug};
	POSIX::setsid();
	no strict 'refs';
	foreach my $f (qw( STDIN STDOUT STDERR )) {
		open $f, '/dev/null';
	}
}

$poe_kernel->run();

print "Shutting Down proxy.\n" if $config{debug};

exit 0;

