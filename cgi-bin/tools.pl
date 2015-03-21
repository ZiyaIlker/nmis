#!/usr/bin/perl
#
## $Id: tools.pl,v 8.7 2012/01/06 07:09:38 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#  
#  This file is part of Network Management Information System (“NMIS”).
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
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
#****** Shouldn't be anything else to customise below here *******************

use strict;
use func;
use NMIS;
use Sys;

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);
#use CGI::Debug;

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

## Before going any further, check to see if we must handle
# an authentication login or logout request

# NMIS Authentication module
use Auth;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS::config

if ($AU->Require) {
	exit 0 unless $AU->loginout(type=>$Q->{auth_type},username=>$Q->{auth_username},
					password=>$Q->{auth_password},headeropts=>$headeropts) ;
}

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

# on unless explicitely set to false
my $widget = getbool($Q->{widget},"invert")? 'false' : "true";
my $wantwidget = $widget eq "true";

#======================================================================

# select function

if ($Q->{act} =~ /tool_system/) {	
	typeTool();
} 
else { 
	notfound(); 
}

sub notfound {
	print header($headeropts);
	print "Tools: ERROR, act=$Q->{act}, node=$Q->{node}<br>\n";
	print "Request not found\n";
}

exit;

#===================


sub typeTool {

	my $tool = $Q->{act};
	$tool =~ s/tool_system_//i;
	my $node = $Q->{node};
	
	my $NT = loadNodeTable();
	my $host = $NT->{$node}{host};

	my $S = Sys::->new;
	$S->init(name=>$node,snmp=>'false');

	my $title = "Command $tool for node $NT->{$node}{name} ($host)";
	$title = "Command $tool" if $node eq '';
	
	if ( $tool =~ /ping|trace|nslookup|mtr|lft/ and $node eq "" ) {
		selectNode();
		exit;
	}

	print header($headeropts);
	pageStart(title => $title) if (!$wantwidget);
	
	return unless $AU->CheckAccess("tls_$tool");

	my $tooloutput;
	my $ctool;
	my $wid = "580px";

	print createHrButtons(node=>$node, system=>$S, widget=>$widget);

	#certain outputs will have their own layout
	if ($tool eq "hostinfo") { 
		hostInfo(); 
	}
	else {
		print start_table({width=>"$wid"});
	
		print start_Tr,start_td,start_table;
		print Tr(td({class=>'header',width=>"$wid"},$title));
	
		if ($tool eq "ping") { $tooloutput=`ping -c 3 $host`; }
		elsif ($tool eq "trace") { $tooloutput=`traceroute -n -m 15 $host`;	}
		elsif ($tool eq "nslookup") { $tooloutput=`nslookup $host`; }
		elsif ($tool eq "finger") { $tooloutput=`finger \@$node`; }
		elsif ($tool eq "who") { $tooloutput=`who`; }
		elsif ($tool eq "man") { $tooloutput=`man $host`; }
		elsif ($tool eq "mank") { $tooloutput=`man -k $host`; }
		elsif ($tool eq "ps") { $tooloutput=`ps -ef`; }
		elsif ($tool eq "iostat") { $tooloutput=`iostat 1 10`; }
		elsif ($tool eq "vmstat") { $tooloutput=`vmstat 1 10`; }
		elsif ($tool eq "date") { $tooloutput=`date`; }
		elsif ($tool eq "df") { $tooloutput=`df -k`; }
		elsif ($tool eq "dns") { viewDNS(); }
		elsif ($tool eq "lft") { 
			$ctool = $tool;
			if ( $C->{$tool} ) { $ctool = $C->{$tool} }
				
			if ( &testTool($ctool) ) {
				$tooloutput = `$ctool -NASE $host 2>&1`;	
			}
			else {
				$tooloutput = "$ctool not found in the path";				
			}
		}
		elsif ($tool eq "mtr") { 
			$ctool = $tool;
			if ( $C->{$tool} ) { $ctool = $C->{$tool} }
				
			if ( &testTool($ctool) ) {
				$tooloutput = `$ctool --report --report-cycles=10 $host 2>&1`;	
			}
			else {
				$tooloutput = "$ctool not found in the path";				
			}
		}
	
		print Tr(td({width=>"$wid"},pre("$tooloutput"))) if $tooloutput ne '';
	
		print end_table,end_td,end_Tr;
		print end_table;
	}
	
	pageEnd() if (!$wantwidget);

}	

sub testTool {
	my $tool = shift;
	my $out = `which $tool`;
	if ( -f $out ) {
		return 1;
	}
	elsif ( -f $tool ) {
		return 1;
	}
	else {
		return 0;
	}
}

sub selectNode {
	my $url = "tools.pl?conf=$Q->{conf}&act=$Q->{act}";
	print header($headeropts);
	
	print start_html(
		-title=>'NMIS Network Tools',-style=>{'src'=>"$C->{'styles'}"},
		-meta=>{ 'CacheControl' => "no-cache",'Pragma' => "no-cache",'Expires' => -1 },
		-head => [
			Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>"$C->{'nmis_favicon'}"}),
			Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'jquery_jdmenu_css'}"}),
			Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'styles'}"})
		]
	);

	print start_form(-id=>"nmisTools",-href=>"$url");
	hidden(-name=>'act', -default=>"$Q->{act}",-override=>'1');
	print start_table({width=>'500px'});
	#print start_table();
	
	print Tr(td({class=>'header'},"Node"),td({class=>'info Plain'},textfield(-name=>"node",size=>'25',value=>"$Q->{node}")));
	print Tr(
		td({class=>'info'},button(-name=>'cancel',onclick=>"get('nmisTools','cancel');",-value=>"Cancel")),
		td({class=>'info'},button(-name=>"submit",onclick=>"get('nmisTools');",-value=>"GO"))		
	);

	print end_table,end_form,end_html;

}

sub hostInfo {
	my $wid = "580px";
	my $output = `ifconfig -a`;
	print start_table({width=>"$wid"});
	print Tr(td({class=>'header',width=>"$wid"},"Host Info"));
	print Tr(
		td({class=>'lft Plain'},pre($output))
	);
	print end_table;
}

sub viewDNS {
	if ($Q->{dns} eq 'host') { viewHostDNS(); }
	elsif ($Q->{dns} eq 'dns') { viewDnsDNS(); }
	elsif ($Q->{dns} eq 'arpa') { viewArpaDNS(); }
	elsif ($Q->{dns} eq 'loc') { viewLocDNS(); }
}

sub getInterfaceTable {

	my $NT = loadNodeTable();
	#Load the Interface Information file
	my $II = loadInterfaceInfo();
	my $ii;

	# build new table with unique key based on ip addr
	foreach my $intHash (keys %{$II}) {
		next unless $AU->InGroup($NT->{$II->{$intHash}{node}}{group});

		my $cnt = 1;
		while ($II->{$intHash}{"ipAdEntAddr$cnt"} ne '') {
			my $ip = $II->{$intHash}{"ipAdEntAddr$cnt"};
	       	if ( 	$ip ne "" and
	       			$ip ne "0.0.0.0" and
	       			$ip !~ /^127/
			) {
	
				$II->{$intHash}{ifSpeed} = convertIfSpeed($II->{$intHash}{ifSpeed});
				my $shortInt = shortInterface($II->{$intHash}{ifDescr});
				if ( $II->{$intHash}{node} =~ /\d+\.\d+\.\d+\.\d+/ 
					and $II->{$intHash}{sysName} ne ""
				) {
					$II->{$intHash}{node} = $II->{$intHash}{sysName};
				}
				elsif ( $II->{$intHash}{sysName} ne "" ) {
					$II->{$intHash}{node} = $II->{$intHash}{sysName};
				}
				$ii->{$ip}{ipAdEntAddr} = $II->{$intHash}{"ipAdEntAddr$cnt"};
				$ii->{$ip}{node} = $II->{$intHash}{node};
				$ii->{$ip}{Description} = $II->{$intHash}{Description};
				$ii->{$ip}{ifDescr} = $II->{$intHash}{ifDescr};
				$ii->{$ip}{ipSubnet} = $II->{$intHash}{ipSubnet};
				$ii->{$ip}{ipAdEntNetMask} = $II->{$intHash}{"ipAdEntNetMask$cnt"};
				$ii->{$ip}{ifSpeed} = $II->{$intHash}{ifSpeed};
				$ii->{$ip}{ifType} = $II->{$intHash}{ifType};
			}
			$cnt++;
		} # while
	} # for
	return $ii;
}


sub viewHostDNS {

	#Load the Interface Information table
	my $ii = getInterfaceTable();

	# Host Records
	print Tr(td({class=>'header'},"Host Records"));

	print start_Tr,start_td,start_table;
	print Tr(
		td({class=>'header'},'IP Addr'),
		td({class=>'header'},'Node'),
		td({class=>'header'},'Description'),
		td({class=>'header'},'Interface'),
		td({class=>'header'},'Subnet'),
		td({class=>'header'},'Mask'),
		td({class=>'header'},'Speed'),
		td({class=>'header'},'Type'));

	foreach my $ip (sortall($ii,'ipAdEntAddr','fwd')) {
		print Tr(
			td({class=>'info'},$ii->{$ip}{ipAdEntAddr}),
			td({class=>'info'},$ii->{$ip}{node}),
			td({class=>'info'},$ii->{$ip}{Description}),
			td({class=>'info'},$ii->{$ip}{ifDescr}),
			td({class=>'info'},$ii->{$ip}{ipSubnet}),
			td({class=>'info'},$ii->{$ip}{ipAdEntNetMask}),
			td({class=>'info'},$ii->{$ip}{ifSpeed}),
			td({class=>'info'},$ii->{$ip}{ifType}));
	} # FOR
	print end_table,end_td,end_Tr;
}

sub viewDnsDNS {

	#Load the Interface Information table
	my $ii = getInterfaceTable();

	# DNS Records
	print Tr(td({class=>'header'},"DNS Records"));
	print start_Tr,start_td,start_table;
	print Tr(
		td({class=>'header'},'Node'),
		td({class=>'header'},''),
		td({class=>'header'},'IP Addr'),
		td({class=>'header'},''),
		td({class=>'header'},'Description'),
		td({class=>'header'},'Interface'),
		td({class=>'header'},'Subnet'),
		td({class=>'header'},'Mask'),
		td({class=>'header'},'Speed'),
		td({class=>'header'},'Type'));

	foreach my $ip (sortall2($ii,'node','ipAdEntAddr','fwd')) {
		print Tr(
			td({class=>'info'},$ii->{$ip}{node}),
			td({class=>'info',nowrap=>undef},'IN A'),
			td({class=>'info'},$ii->{$ip}{ipAdEntAddr}),
			td({class=>'info'},'#'),
			td({class=>'info'},$ii->{$ip}{Description}),
			td({class=>'info'},$ii->{$ip}{ifDescr}),
			td({class=>'info'},$ii->{$ip}{ipSubnet}),
			td({class=>'info'},$ii->{$ip}{ipAdEntNetMask}),
			td({class=>'info'},$ii->{$ip}{ifSpeed}),
			td({class=>'info'},$ii->{$ip}{ifType}));

	} # FOR
	print end_table,end_td,end_Tr;
}

sub viewArpaDNS {

	#Load the Interface Information table
	my $ii = getInterfaceTable();

	#0.19.64.10.in-addr.arpa.       IN      PTR     network.mosp.cisco.com.
	#1.19.64.10.in-addr.arpa.       IN      PTR     gw.mosp.cisco.com.

	# in-addr.arpa. Records
	print Tr(td({class=>'header'},"in-addr.arpa. DNS Records"));
	print start_Tr,start_td,start_table;
	print Tr(
		td({class=>'header'},'Arpa'),
		td({class=>'header'},''),
		td({class=>'header'},'Name'),
		td({class=>'header'},''),
		td({class=>'header'},'Mask'));

	foreach my $ip (keys %{$ii}) {
		my @in_addr_arpa = split (/\./,$ii->{$ip}{ipAdEntAddr});
		$ii->{$ip}{ipAdEntAddr_arpa} = "$in_addr_arpa[3].$in_addr_arpa[2].$in_addr_arpa[1].$in_addr_arpa[0]";
	}
	foreach my $ip (sortall($ii,'ipAdEntAddr_arpa','fwd')) {
		print Tr(
			td({class=>'info'},"$ii->{$ip}{ipAdEntAddr_arpa}.in-addr.arpa."),
			td({class=>'info'},"IN PTR"),
			td({class=>'info'},"$ii->{$ip}{node}"),
			td({class=>'info'},'#'),
			td({class=>'info'},$ii->{$ip}{ipAdEntNetMask}));
	} # FOR
	print end_table,end_td,end_Tr;
}

sub viewLocDNS {

	my $node;
	my $location;
	my %location_data;

	#Load the Interface Information table
	my $ii = getInterfaceTable();
	#Load the location data.
	my $LT = loadLocationsTable();


# Extract from RFC1876 A Means for Expressing Location Information in the Domain Name System
# This RFC specifies creates DNS LOC (location) records for visual traceroutes
#--snip--
#3. Master File Format
#   The LOC record is expressed in a master file in the following format:
#   <owner> <TTL> <class> LOC ( d1 [m1 [s1]] {"N"|"S"} d2 [m2 [s2]]
#                               {"E"|"W"} alt["m"] [siz["m"] [hp["m"]
#                               [vp["m"]]]] )
#   (The parentheses are used for multi-line data as specified in [RFC1035] section 5.1.)
#   where:
#       d1:     [0 .. 90]            (degrees latitude)
#       d2:     [0 .. 180]           (degrees longitude)
#       m1, m2: [0 .. 59]            (minutes latitude/longitude)
#       s1, s2: [0 .. 59.999]        (seconds latitude/longitude)
#       alt:    [-100000.00 .. 42849672.95] BY .01 (altitude in meters)
#       siz, hp, vp: [0 .. 90000000.00] (size/precision in meters)
#
#   If omitted, minutes and seconds default to zero, size defaults to 1m,
#   horizontal precision defaults to 10000m, and vertical precision
#   defaults to 10m.  These defaults are chosen to represent typical
#   ZIP/postal code area sizes, since it is often easy to find
#   approximate geographical location by ZIP/postal code.
#
#4. Example Data
#;;;
#;;; note that these data would not all appear in one zone file
#;;;
#;; network LOC RR derived from ZIP data.  note use of precision defaults
#cambridge-net.kei.com.        LOC   42 21 54 N 71 06 18 W -24m 30m
#;; higher-precision host LOC RR.  note use of vertical precision default
#loiosh.kei.com.               LOC   42 21 43.952 N 71 5 6.344 W -24m 1m 200m
#pipex.net.                    LOC   52 14 05 N 00 08 50 E 10m
#curtin.edu.au.                LOC   32 7 19 S 116 2 25 E 10m
#rwy04L.logan-airport.boston.  LOC   42 21 28.764 N 71 00 51.617 W -44m 2000m
#--end snip--

	# DNS LOC Records

	print Tr(td({class=>'header'},"DNS LOC Records"));
	print start_Tr,start_td,start_table;
	print Tr(
		td({class=>'header'},'Node'),
		td({class=>'header'},''),
		td({class=>'header'},'Latitude'),
		td({class=>'header'},'Longitude'),
		td({class=>'header'},'Altitude'),
		td({class=>'header'},'Setting'));

	foreach my $ip (sortall($ii,'node','fwd')) {
		if ( $ii->{$ip}{ipAdEntAddr} ne "" ) {
			if ( $node ne $ii->{$ip}{node} ) {
				$node = $ii->{$ip}{node};
				my $NI = loadNodeInfoTable($node);
				$location = lc($NI->{system}{sysLocation});
				if ( $LT->{$location}{Latitude} ne "" and
					$LT->{$location}{Longitude} ne "" and
					$LT->{$location}{Altitude} ne ""
					) {
					print Tr(
						td({class=>'info'},$ii->{$ip}{node}),
						td({class=>'info'},'IN LOC'),
						td({class=>'info'},$LT->{$location}{Latitude}),
						td({class=>'info'},$LT->{$location}{Longitude}),
						td({class=>'info'},$LT->{$location}{Altitude}),
						td({class=>'info'},"1.00m 10000m 100m"));

				}
			}
			if ( $LT->{$location}{Latitude} ne "" and
				$LT->{$location}{Longitude} ne "" and
				$LT->{$location}{Altitude} ne ""
				) {
				print Tr(
					td({class=>'info'},$ii->{$ip}{node}),
					td({class=>'info'},'IN LOC'),
					td({class=>'info'},$LT->{$location}{Latitude}),
					td({class=>'info'},$LT->{$location}{Longitude}),
					td({class=>'info'},$LT->{$location}{Altitude}),
					td({class=>'info'},"1.00m 10000m 100m"));
			}
		}
	} # FOR
	print end_table,end_td,end_Tr;

} #viewLocDNS
