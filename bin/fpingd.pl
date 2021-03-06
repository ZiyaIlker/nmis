#!/usr/bin/perl
#
#  Copyright 1999-2014 Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************
our $VERSION = "8.6.4G";

use FindBin qw($Bin);
use lib "$FindBin::Bin/../lib";
use strict;
use POSIX qw(setsid);
use Time::HiRes;
use Socket;
use Data::Dumper;
use Fcntl qw(:DEFAULT :flock);
use File::Basename;
use Test::Deep::NoTest;
use Statistics::Lite;

use NMIS;
use func;

my $me = basename($0);

my %nvp = getArguements(@ARGV);
my $restartwanted = getbool($nvp{restart});
my $killwanted = getbool($nvp{kill});

if (!($restartwanted xor $killwanted) # want one or the other, not both and not none
		or (@ARGV == 1 and $ARGV[0] =~ /^-{1,2}(h(elp)?|\?)$/ ))
{
	die( "$me Version $VERSION

Usage: $me <restart|kill]=[true|false]> [debug=true|false] [logging=true|false] [conf=alt.config]

Command line options are:
 restart=true   - kill any running daemon(s) and restarts
 debug=true     - print diagnostics to console
 kill=true      - kill any running daemon(s) and exit. Does not launch a new daemon!
 logging=true   - creates a log file 'fpingd.log' in the standard nmis log directory

a new daemon is started ONLY with restart=true.\n");
}

# load configuration table
my $C = loadConfTable(debug => $nvp{debug});

# check if nmis is locked, if so shut down immediately.
my $lockoutfile = $C->{'<nmis_conf>'}."/NMIS_IS_LOCKED";
if (-f $lockoutfile or getbool($C->{global_collect},"invert"))
{
	die ("Attention: NMIS is currently disabled, fpingd.pl is terminating!\n"
			 .(-f $lockoutfile? "Remove the file $lockoutfile to re-enable.\n\n" :
				 "Set the configuration variable \"global_collect\" to \"true\" to re-enable.\n\n"))
}

# fixme: logging logic is horribly bad, logmsg goes to nmis.log but is not used for much,
# logging and debug are horribly intermixed in the local debug function;
# debug=0 but logging=1 implies debug level 1.
my $debug =  setDebug($nvp{debug});
my $logfile = $C->{'fpingd_log'};
my $pidfile = $C->{'<nmis_var>'}."/nmis-fpingd.pid";

# check for any running fpingd instance
my $alreadyrunning;
if ( -f $pidfile )
{
	open(F, "<$pidfile") or die "failed to read $pidfile: $!\n";
	$alreadyrunning = <F>;
	chomp $alreadyrunning;
	close(F);
}

if ( int($alreadyrunning)				# it's a number
		 and $alreadyrunning != $$	# and it's not me (should be impossible)
		 and kill(0, $alreadyrunning) # and it's really alive
		 and ( $killwanted or $restartwanted )) # and we're to get rid of it
{
	kill('TERM', $alreadyrunning);				# polite then firm
	sleep(1);
	kill('KILL', $alreadyrunning);
	unlink($pidfile);

	debug("Killed process $alreadyrunning");
}
exit(0) if ($killwanted);

# check that fping is available!
my $fpingver = `fping -v`;
if ($? >> 8)
{
	debug("fping executable not found, please install fping!");
	logMsg("ERROR fping executable not found, please install fping!");
	exit(1);
}
else
{
	$fpingver =~ s/^.*Version (\d+\.\d+).*$/$1/s;
	debug("found fping version $fpingver");
}

my $cachetimeout =  900;				# remember ip addresses for 15 minutes
my $timeout = $C->{fastping_timeout} || 300 ;
my $length  = $C->{fastping_packet}  ||  56 ;
$length = 24 if ( $length < 24 ); # minimum packet size is 20 + 4 bytes
my $retries = $C->{fastping_retries} || 3;
my $count   = $C->{fastping_count} || 3;

# we want fping to do the work, no need to avg/min/max ourselves
# -c X produces: 'somenode : xmt/rcv/%loss = 5/5/0%, min/avg/max = 0.73/0.86/0.97'
my @fpingcmd = 	("fping", "-t", $timeout, "-c", $count, "-q",
								 "-r", $retries, "-b", $length) ;

push @fpingcmd, ($< == 0?
								 # use this command for fping if script run as user root
								 ("-i", 1, "-p", 1)
								 : 	# non-root requires i >= 10, p >= 20, r < 20, and t >= 50
								 ("-i", 10, "-p", 20));

# how many nodes per fping invocation
my $maxnodes = $C->{fastping_node_poll} || 200;

# should we write a raw event log without stateful deduplication?
my $raweventlog = $C->{fastping_stateless_log};

my $ext = getExtension(dir=>'var');

debug( "logfile = $FindBin::Bin/../logs/fpingd.log") if defined $nvp{logging};
debug( "logging not enabled - set cmdline option \'logging=true\' if logging required") if !defined $nvp{logging};
debug( "pidfile = $pidfile");
debug( "ping result file = $FindBin::Bin/../var/fping.$ext");
debug( "fping cmd: ".join(" ",@fpingcmd));
#---------------------------------------
# process control

# for debugging, undocumented: argument foreground=true
if (!getbool($nvp{"foreground"}))
{
	if (!defined(my $pid = fork))
	{
		die "cannot fork: $!\n";
	}
	elsif ($pid)
	{
		# parent: exits
		debug("daemon $pid was started.");
		exit (0);
	}

	# child continues with the actual work
	POSIX::setsid() or die "Can't start new session: $!";
	chdir('/') or die "Can't chdir to /: $!";

	# handler sets a flag to indicate we need to exit.
	$SIG{INT} = $SIG{TERM} = $SIG{HUP} = \&catch_zap;

	# Reopen stdout, stdin with /dev/null; stderr to the fpingd logfile
	# if we dont reopen, the calling terminal will wait, and nmis.pl daemon control will hang
	open(STDIN, "<", "/dev/null") or die "cannot reopen stdin: $!\n";
 	open(STDOUT, ">", "/dev/null") or die "cannot reopen stdout: $!\n";
 	open(STDERR, ">>", $logfile) or die "cannot open stdout to $logfile: $!\n";
	setFileProtDiag(file => $logfile);
}

# Announce our presence via a PID file
open(PID, ">$pidfile") or die "Could not create $pidfile: $!\n";
print PID $$;
close PID;
setFileProtDiag(file => $pidfile);

debug("daemon started");
logMsg("INFO daemon fpingd started, pidfile $pidfile created with pid: $$");

logMsg( !getbool($C->{daemon_fping_dns_cache},"invert")?
				"INFO daemon fpingd will use and cache DNS for improved name resolution"
				: "WARNING daemon fpingd will not use DNS, use under adult supervision!" );


# remember the original script location plus the parameter that we want to push through for restart
# old path might have been relative and doesn't work past chdir
my $origscript = $FindBin::RealBin."/".$FindBin::Script;
# we want to keep any params, except kill
my @restartparams = map { "$_=".$nvp{$_}; } (grep($_ ne "kill", keys %nvp));
$0 = $me;

my (%state,											# nodename -> ip, lastping, nextping, nextdns, avg, loss
		$preveventcfg,							# change detection
		$prevmaincfg,								# change detection - loadconftable is not mtime-aware...
		$mustexit);

while (!$mustexit)
{
	my $now = Time::HiRes::time;
	my $escalatables;

	# nmis locked? nothing for this daemon to do
	my $lockoutfile = $C->{'<nmis_conf>'}."/NMIS_IS_LOCKED";
	if (-f $lockoutfile or getbool($C->{global_collect},"invert"))
	{
		logMsg("WARN fping is terminating because NMIS is disabled!");
		die ("Attention: fping is terminating because NMIS is disabled!\n");
	}

	# react to actual changes to events config by restarting, as that'd affect the notify/checkEvent code
	my $eventconfig = loadTable(dir => 'conf', name => 'Events');
	my $mainconfig = loadTable(dir => 'conf', name => 'Config');

	my $whichchanged = (defined($preveventcfg) && !eq_deeply($preveventcfg, $eventconfig) ?
											"Events List" :
											(defined($prevmaincfg) && !eq_deeply($prevmaincfg,$mainconfig) ? 
											 "Config" : undef));
	if ($whichchanged)
	{
		logMsg("INFO fpingd will restart, $whichchanged has changed");
		exec($origscript,@restartparams);
		die "$0 couldn't restart itself: $!\n"; # shouldn't be reached
	}
	$preveventcfg = $eventconfig;
	$prevmaincfg = $mainconfig;

	# nodes, polling-policy: reread every cycle, cached
	my $policies = loadTable(dir => 'conf', name => "Polling-Policy") || {};
	my $lnt = loadLocalNodeTable() || {};

	# first: find the candidate nodes (and ditch deleted/disabled ones)
	for my $maybegoner (keys %state)
	{
		delete $state{$maybegoner}
		if (ref($lnt->{$maybegoner}) ne "HASH"
				or  !getbool($lnt->{$maybegoner}->{active})
				or !getbool($lnt->{$maybegoner}->{ping}));
	}

	my @todos;
	for my $noderec (values %$lnt)
	{
		next if (!getbool($noderec->{active}) or !getbool($noderec->{ping}));

		my $thisstate = $state{ $noderec->{name} } ||= {
			name => $noderec->{name},
			# dynamically managed: ip, lastping,nextping, policy , nextdns, avg min max loss
		};
		# what needs filling in, what could change between poll cycles?
		$thisstate->{host} = $noderec->{host};
		$thisstate->{policy} = $noderec->{polling_policy} || 'default';

		# honor fixed ip address given
		# fixme: fping doesn't do ipv6, we would have to use fping6 for that.
		if ($thisstate->{host} =~ /^\d+\.\d+\.\d+\.\d+$/)
		{
			$thisstate->{ip} = $thisstate->{host};
		}
		# allowed to resolve name and cache address?
		elsif (!getbool($C->{daemon_fping_dns_cache},"invert"))
		{
			if (!$thisstate->{ip} or $now >= $thisstate->{nextdns})
			{
				# fixme: this returns only v4 addresses, see fping6 comment above
				$thisstate->{ip} = NMIS::resolveDNStoAddr($thisstate->{host}) # may be undef
						||  $thisstate->{host}; # again falling back to leaving this to fping
				debug("refreshed dns for $thisstate->{host} to $thisstate->{ip}"
							.($thisstate->{nextdns}? sprintf(", was due %.2fs ago", $now - $thisstate->{nextdns}):""))
						if ($debug > 1);
				$thisstate->{nextdns} = $now + $cachetimeout;
			}
		}
		# otherwise leave it to fping to Do Something with the host (name or whatever)
		else
		{
				$thisstate->{ip} = $thisstate->{host};
		}

		# second: find out which ones are due for pinging this cycle
		if (!$thisstate->{nextping} or $thisstate->{nextping} <= $now)
		{
			debug("will ping node $thisstate->{name} this cycle"
						. ($thisstate->{nextping}? sprintf(", was due %.2fs ago", $now - $thisstate->{nextping}): "" ))
						if ($debug > 1);
			push @todos, $thisstate->{name};
		}
	}

	my @thistime = @todos;				# todos is consumed
	# third: ping the ones in need, in chunks if necessary
	while (my @chunk = splice(@todos, 0, $maxnodes))
	{
		my %ip2node;
		my @cmd = @fpingcmd;
		for my $nodename (@chunk)
		{
			my $thisip = $state{$nodename}->{ip};

			push @cmd, $thisip;
			$ip2node{$thisip} = $nodename; # for associating the results
		}
		debug("about to run: ".join(" ",@cmd));

		# pity that fping reports on stderr, NOT stdout; we need the shell redirection (or a child and replumb)
		if (!open(FROMFPING, "-|", join(" ", @cmd, "2>&1")))
		{
			logMsg("ERROR failed to run fping: $!");
			die "Failed to run fping: $!\n";
		}

		while (my $line = <FROMFPING>)
		{
			chomp $line;
			# goodnode : xmt/rcv/%loss = 5/5/0%, min/avg/max = 0.89/0.96/1.05
			# badnode : xmt/rcv/%loss = 5/0/100%
			# or nothing for unresolvable.
			debug("fping returned: $line") if ($debug > 2);

			my ($hostname,$loss,$min,$avg,$max) = ($1,$2,$3,$4,$5,$6)
					if ($line =~ m!^\s*(\S+)\s*:\s*xmt/rcv/%loss\s*=\s*\d+/\d+/(\d+)%(?:,\s*min/avg/max\s*=\s*(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?))?$!);

			if ($hostname								# parseable?
					&& $ip2node{$hostname}  # known?
					&& $loss =~ /^\d+$/ )		  # structure good enough for the reachability at least?
			{
				my $thisstate = $state{ $ip2node{$hostname} };
				# what does the policy say about the interval?
				# policy present, use that; fall back to 60 seconds otherwise
				my $interval = ref($policies->{ $thisstate->{policy} }) eq "HASH"?
						$policies->{ $thisstate->{policy} }->{ping} : 60; # seconds

				# supports NNN (seconds) or MMMU with U being s, m, h or d, fractional NNN or MMM also ok
				if ($interval =~ /^\s*(\d+(\.\d+)?)([smhd])$/)
				{
					my ($rawvalue, $unit) = ($1, $3);
					$interval = $rawvalue * ($unit eq 'm'? 60 : $unit eq 'h'? 3600 : $unit eq 'd'? 86400 : 1);
				}

				# the regex extraction sets missing to blank string, would prefer undef or number
				$thisstate->{loss} = int($loss);
				$thisstate->{avg} = $avg ne ""? 0+$avg : undef;
				$thisstate->{min} = $min ne ""? 0+$min : undef;
				$thisstate->{max} = $max ne ""? 0+$max : undef;

				$thisstate->{lastping} = $now;
				$thisstate->{nextping} = $now + $interval;

				debug("parsed result for node $ip2node{$hostname}: ".Dumper($thisstate)) if ($debug > 2);
			}
			else
			{
				debug("ERROR fping result \"$line\" was not parseable!");
				logMsg("ERROR result \"$line\" was not parseable!");
			}
		}
		close FROMFPING;
	}
	# all pinging done, let's dump the state onto disk as soon as we can
	writeTable(dir => 'var', name => "nmis-fping", data => \%state);

	# fourth: analyse the results we've got this time, trigger nmis operations as needed
	for my $nodename (@thistime)
	{
		my $thisstate = $state{$nodename};

		# write raw events if requested - regardless of state change or not!
		# note that this is a debugging aid only.
		if ($raweventlog)
		{
			my @problems;
			if (!open(RF,">>$raweventlog"))
			{
				push @problems, "ERROR could not open $raweventlog: $!";
			}
			else
			{
				if (!flock(RF, LOCK_EX))
				{
					push @problems, "ERROR could not lock $raweventlog: $!";
				}
				else
				{
					my $down = ($thisstate->{loss} == 100);
					my $event = "Node ".($down? "Down":"Up");
					my $level = $down? "Critical":"Normal";
					my $details = $down? "Ping failed" : "Ping succeeded, loss=$thisstate->{loss}%";

					print RF join(",", time, $nodename, $event, $level, '', $details),"\n";
					close RF or push(@problems,"ERROR could now write to or close $raweventlog: $!");
				}
			}
			map { logMsg($_) } (@problems); # DO NOT run logMsg inside a critical section or while holding a lock!
		}

		# submit changes in status to the nmis event system
		if ( $thisstate->{loss} == 100 )
		{
			debug("Node $nodename is NOT REACHABLE, fping reported loss=$thisstate->{loss}%");
			# for unreachable nodes where we're caching the dns-ip assocition, we mark it as 'recheck dns'
			# for fixed-ip nodes this is not relevant
			undef $thisstate->{nextdns};

			if (!eventExist($nodename, "Node Down", undef))
			{
				# Device is DOWN, was up, as no entry in event database
				debug("$nodename is now DOWN, was UP, updating event database");
				fpingNotify($nodename);
				++$escalatables;
			}
		}
		else # node somewhat pingable, not 100% loss
		{
			debug("$nodename is pingable: returned min/avg/max = $thisstate->{min}/$thisstate->{avg}/$thisstate->{max}ms loss=$thisstate->{loss}%");

			# check the event existence AND its currency!
			my $event_exists = eventExist($nodename, "Node Down", undef);
			my $erec = eventLoad(filename => $event_exists) if ($event_exists);

			if ($event_exists and $erec and getbool($erec->{current}))
			{
				# Device was down is now UP!
				# Only post the status if the event database records as currently down
				debug("$nodename is now UP, was DOWN, updating event database");
				fpingCheckEvent($nodename);
				++$escalatables;
			}
		}
	}

	# if desired and useful, run the NMIS escalation process here
	# for faster outage notifications; also runs as part of collect,
	# or can be run via cron.
	if ($escalatables && getbool($C->{daemon_fping_run_escalation}))
	{
		# but we certainly don't wait for it to finish
		fork || exec("$C->{'<nmis_bin>'}/nmis.pl","type=escalate");
	}

	# we're done for this cycle, so how long should we sleep?
	# who's next? don't show gazillions of nodes unless debug level is really high
	if ($debug > 5)
	{
		my @soontonever = sort { $state{$a}->{nextping} <=> $state{$b}->{nextping} } (keys %state);
		debug("next ping ordering:\n\t"
					. join("\n\t", map { sprintf("%s in %.2fs", $_, $state{$_}->{nextping}-$now) } (@soontonever)));
	}
	my $nextone = Statistics::Lite::min( map { $_->{nextping} } (values %state));

	# if we don't know anything we'll just sleep for 10 seconds
	my $naptime = ($nextone && $nextone - $now > 0)? int(0.5 + $nextone - $now) : 10;
	if ($naptime > 0)
	{
		debug("sleeping $naptime seconds");
		reaper();											# unlikely that the escalate is done already but bsts, reaping costs nothing
		sleep($naptime);
	}
	reaper();
}
exit 0;


# check-and-remove existing node down event
# args: node name
# returns: nothing
sub fpingCheckEvent
{
	my $node = shift;
	debug("\tUpdating event database via sub checkEvent() host: $node event: Node Up");

	my $S = Sys::->new;
	$S->init(name => $node, snmp => 'false');
	my $NI = $S->ndinfo; # pointer to node info table

	checkEvent( sys		=> $S,
							event   => "Node Down",
							element => "",
							level   => "Normal",
							details => "Ping failed" );
}

# create a new node down event
# args: node name
# returns: nothing
sub fpingNotify
{
	my $node = shift;

	debug("\tUpdating event database via sub notify() host: $node event: Node Down");

	my $S = Sys::->new;
	$S->init(name=>$node, snmp=>'false');

	notify(	sys		=> $S,
					event   => "Node Down",
					element => "",
					details => "Ping failed",
					context => { type => "node" });
}

sub debug
{
	my (@msgs) = @_;

	print STDOUT returnDateStamp(), " $me\[$$] ", @msgs, "\n"
			if ($debug);

	if ( $nvp{logging} )
	{
		open LOG, ">>$logfile"
				or warn "Can't write to $logfile: $!";
		print LOG returnDateStamp(), " $me\[$$] ", @msgs, "\n";
		close LOG;
		setFileProtDiag(file => $logfile);
	}
}

sub catch_zap
{
	my ($sig) = @_;

	$mustexit++;

	debug("I was killed by $sig");
	logMsg("INFO daemon fpingd killed by $sig",
				 do_not_lock => 1);
	unlink $pidfile;
}

# this is a general-purpose reaper of zombies
# args: none, returns: hash of process ids -> statuses that were reaped
#
# you can use this to just periodically collect zombies,
# or as a signal handler, but:
#
# PLEASE NOTE: if you attach it to $SIG{CHLD}, then
# this CAN AND WILL interfere with getting exit codes from
# backticks, system, and open-with-pipe, because the child handler
# can run before the perl standard wait() for these ipc ops,
# hence $? becomes -1 because the wait() was preempted.
#
sub reaper
{
	my %exparrots;

	while ((my $pid = waitpid(-1, POSIX::WNOHANG)) > 0)
	{
		$exparrots{$pid} = $?;
	}
	return %exparrots;
}
