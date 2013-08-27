#!/usr/bin/perl
#
# File: check_linux_mem_snmp
# Author: Adam Portier <ajportier@gmail.com>
# Date: 08/27/2013 (Version 1.1)
#
# Uses the values reported by the HOST-RESOURCES-MIB::hrStorage MIB to
# calculate the "real" memory available to a Linux host; i.e. the memory that
# is not reserved by the kernel in cache. This value closer approximates the
# value in "-/+ buffers/cache" when running "free -m"
#
# Based on "check_disk_snmp.pl" from the Nagios Exchange
#
# License Information:
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

##### PRAGMA AND INCLUDES #####
use strict;
use warnings;
use vars qw($VERSION $PROGNAME);
use lib "/usr/lib/nagios/plugins";
use utils qw(%ERRORS $TIMEOUT);
use Getopt::Long;
use Net::SNMP;

##### CONFIGURATION AND VARIABLES #####
$VERSION  = '1.1';
$PROGNAME = 'check_linux_mem_snmp';
my $OID_BASE = '.1.3.6.1.2.1.25.2.3.1';
my $TOTAL_INDEX = '1';
my $BUFFER_INDEX = '6';
my $CACHED_INDEX = '7';

my $host  = undef;
my $port  = 161;
my $comm  = 'public';
my $warn  = '85%';
my $crit  = '90%';
my $total_mem = 0;
my $used_mem = 0;
my $state = undef;
my $help;

##### COMMAND LINE PARSE #####
GetOptions (
    "h|host=s"      => \$host,
    "s|community=s" => \$comm,
    "p|port=i"      => \$port,
    "w|warn=s"      => \$warn,
    "c|crit=s"      => \$crit,
    "help"          => \$help,
) or &croak("Unable to parse command line options");

# If looking for help, print extended help and exit
&print_help() if ($help);

# If no host is provided, print usage and exit
unless (defined $host) {
    &print_usage();
    &croak("Missing host argument (-h)");
}

##### MAIN #####
my $snmp = Net::SNMP->session(
    -hostname    => $host,
    -port        => $port,
    -community   => $comm,
    -timeout     => int(($TIMEOUT / 3) + 1),
    -retries     => 2,
    -version     => 1,
    -nonblocking => 0x0
);

&croak("Unable to open SNMP session with $host") unless defined($snmp);

# Look up SNMP values for each of the memory OIDs
foreach my $index ($TOTAL_INDEX,$BUFFER_INDEX,$CACHED_INDEX){
    my $resp = undef;
    my @varlist = ();
    my $used = join('.',$OID_BASE,'6',$index);
    my $size = join('.',$OID_BASE,'5',$index);
    push (@varlist,$used);

    # If the OID being looked up ws for total memory, get the max (size) too
    push (@varlist,$size) if ($index == $TOTAL_INDEX);

    $resp = $snmp->get_request(
        -varbindlist => [@varlist]
    ) or &croak("Unable to fetch data from $host");

    # If the OID looked up was for total memory, record the max total memory
    $total_mem = $resp->{$size} if ($index == $TOTAL_INDEX);

    # Subtract the value of cached memory from the running total; otherwise
    # add the value of used memory to the running total
    if ($index == $CACHED_INDEX){
        $used_mem -= $resp->{$used};
    } else {
        $used_mem += $resp->{$used};
    }
}

# Crude rounding to avoid POSIX / Math modules
my $percent_used = sprintf("%0.0f",(($used_mem / $total_mem) * 100));
my $free_mem_mb = sprintf("%0.0f",($total_mem - $used_mem)/1024);
my $total_mem_mb = sprintf("%0.0f",$total_mem / 1024);
my $free_mem_b = sprintf("%0.0f",($total_mem - $used_mem)*1024);

# If operating in percents, calculate state based off percent used
if ($warn =~ /\%$/o || $crit =~ /\%$/o) {
    $warn =~ s/\%$//;
    $crit =~ s/\%$//;
    $state = $percent_used >= $crit ? 'CRITICAL' :
             $percent_used >= $warn ? 'WARNING' :
             'OK';
# Otherwise, caclulate state based off total free (in MB)
} else {
    $state = $free_mem_mb <= $crit ? 'CRITICAL' :
             $free_mem_mb <= $warn ? 'WARNING' :
             'OK';
}

print "$state: Memory at ${percent_used}% ",
    "with $free_mem_mb of $total_mem_mb MB free",
    " | 'percent used'=${percent_used}%",
    " 'free'=${free_mem_b}B\n";

exit $ERRORS{$state};

##### ENDMAIN #####

##### SUBROUTINES #####

# Prints the plugin version
sub print_version {
    print "$PROGNAME $VERSION\n";
}

# Prints the usage statement
sub print_usage {
    print "\tUsage: ${PROGNAME} -h host_address [-s snmp_community]\n",
        "\t[-p snmp_udp_port] [-w warning_threshold] [-c critical_threshold]\n";
}

# Prints out syntax help
sub print_help {
    &print_version();
    print "\nThis plugin checks the memory available (minus cache) on a Linux\n",
        "server, using SNMP and HOST-RESOURCES-MIB::hrStorage\n";
    &print_usage();
    print "\nOptions:\n",
        "  -h STRING\n",
        "\tDotted Decimal IP address or fully qualified domain name of host\n",
        "  -p INTEGER\n",
        "\tUDP port number of SNMP access (default: 161)\n",
        "  -s STRING\n",
        "\tSNMP community string for host (default: public)\n",
        "  -w INTEGER\n",
        "\tExit with WARNING if less than INTEGER MB are free\n",
        "  -w PERCENT%\n",
        "\tExit with WARNING if more than PERCENT is used (default: 85%)\n",
        "  -c INTEGER\n",
        "\tExit with CRITICAL if less than INTEGER MB are free\n",
        "  -c PERCENT%\n",
        "\tExit with CRITICAL if more than PERCENT is used (default: 90%)\n";
    print "\nExamples:\n",
        "\n  $PROGNAME -h server.example.com -s rocommunity -w 80% -c 85%\n",
        "  * Will exit with a warning at more than 80% used, critical at 85%\n",
        "\n  $PROGNAME -h 10.0.0.1 -w 2048 -c 1024\n",
        "  * Will exit with a warning at less than 2048 MB free, critical at 2014 MB\n";
    exit $ERRORS{'UNKNOWN'};
}

# Exit with status "UNKNOWN" if something goes wrong
sub croak {
    my $message = shift;
    print "UNKNOWN: $message\n";
    exit $ERRORS{'UNKNOWN'};
}
