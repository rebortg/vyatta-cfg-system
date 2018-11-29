#!/usr/bin/perl
#
# Module: vyatta-dhcpv6-client.pl
#
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Copyright (C) 2010 Vyatta, Inc.
# All Rights Reserved.
#
# Author: Bob Gilligan <gilligan@vyatta.com>
# Date: April 2010
# Description: Start and stop DHCPv6 client daemon for an interface.
#
# **** End License ****
#
#

use strict;
use warnings;

use lib "/opt/vyatta/share/perl5/";
use Sys::Hostname;
use Vyatta::Config;
use Vyatta::Interface;
use Getopt::Long;

sub gen_conf_file {
    my ($conffile, $ifname) = @_;
    my $FD_WR;

    open($FD_WR, '>', $conffile)
        or die "Can't write config file: $conffile : $!\n";

    my $date = localtime;
    my $user = getpwuid($<);

    print $FD_WR "# This file was auto-generated by the Vyatta\n";
    print $FD_WR "# configuration sub-system.  Do not edit it.\n";
    print $FD_WR "\n";
    print $FD_WR "#   Generated on $date by $user\n";
    print $FD_WR "#\n";
    print $FD_WR "interface \"$ifname\" {\n";

    my $intf = new Vyatta::Interface($ifname)
        or die "Can't find interface $ifname\n";
    my $level = $intf->path() . ' dhcpv6-options';
   
    my $config = new Vyatta::Config;
    $config->setLevel($level);

    if ($config->exists('duid')) { 
        my $duid = $config->returnValue('duid');
        print $FD_WR "        send dhcp6.client-id $duid;\n";
    }
#    my $hostname = hostname;
#    print $FD_WR "        send host-name \"$hostname\";\n";
#    print $FD_WR "        send dhcp6.oro 1, 2, 7, 12, 13, 23, 24, 39;\n";
    print $FD_WR "}\n";
    close $FD_WR;
}
    
sub usage {
    print "Usage: $0 --ifname=ethX --{start|stop|renew|release}\n";
    exit 1;
}


#
# Main Section
#

my $start_flag;  # Start the daemon
my $stop_flag;   # Stop the daemon and delete all config files
my $release_flag;       # Stop the daemon, but leave config file
my $renew_flag;  # Re-start the daemon.  Functionally same as start_flag
my $ifname;
my $temporary;
my $params_only;

GetOptions("start" => \$start_flag,
           "stop" => \$stop_flag,
           "release" => \$release_flag,
           "renew" => \$renew_flag,
           "ifname=s" => \$ifname,
           "temporary" => \$temporary,
           "parameters-only" => \$params_only
    ) or usage();

die "Error: Interface name must be specified with --ifname parameter.\n"
    unless $ifname;

my $pidfile = "/var/lib/dhcp/dhclient_v6_$ifname.pid";
my $leasefile = "/var/lib/dhcp/dhclient_v6_$ifname.leases";
my $conffile = "/var/lib/dhcp/dhclient_v6_$ifname.conf";
my $cmdname = "/sbin/dhclient";

if ($release_flag) {
    die "DHCPv6 client is not configured on interface $ifname.\n"
        unless (-e $conffile);

    die "DHCPv6 client is already released on interface $ifname.\n"
        unless (-e $pidfile);
}

if ($renew_flag) {
    die "DHCPv6 client is not configured on interface $ifname.\n"
        unless (-e $conffile);
}

if (defined($stop_flag) || defined ($release_flag)) {
    # Stop dhclient -6 on $ifname

    printf("Stopping daemon...\n");
    system("$cmdname -6 -cf $conffile -pf $pidfile -lf $leasefile -x $ifname");
    
    # Delete files it leaves behind...
    printf("Deleting related files...\n");
    unlink($pidfile);
    if (defined $stop_flag) {
        # If just releasing, leave the config file around as a flag that
        # DHCPv6 remains configured on this interface.
        unlink($conffile);
    }
}

if (defined($start_flag) || defined ($renew_flag)) {

    # Generate the DHCP client config file...
    gen_conf_file($conffile, $ifname);

    # First, kill any previous instance of dhclient running on this interface
    #
    printf("Stopping old daemon...\n");
    system("$cmdname -6 -pf $pidfile -x $ifname");

    # Wait for IPv6 duplicate address detection to finish, dhclient won't start otherwise
    # https://phabricator.vyos.net/T903
    for (my $attempt_count = 0; $attempt_count <= 60; $attempt_count++) {
        # Check for any non-tentative addresses (exit code 0 if any exist, 1 otherwise)
        if (system("test -n \"\$(ip -6 -o addr show dev $ifname scope link -tentative)\"") != 0) {
            # No non-tentative address found, sleep and retry or exit
            if ($attempt_count == 0) {
                print "Duplicate address detection incomplete, waiting\n"
            }

            if ($attempt_count < 60) {
                sleep(1);
                next;
            } else {
                print "Error: No non-tentative address was found for interface $ifname\n";
                exit 1;
            }
        } else {
            # Address found, exit loop
            last;
        }
    }


    if (defined($temporary) && defined($params_only)) {
        print "Error: temporary and parameters-only options are mutually exclusive!\n";
        exit 1;
    }

    my $temp_opt = defined($temporary) ? "-T" : "";
    my $po_opt = defined($params_only) ? "-S" : "";

    printf("Starting new daemon...\n");
    exec "$cmdname -6 $temp_opt $po_opt -nw -cf $conffile -pf $pidfile -lf $leasefile $ifname"
        or die "Can't exec $cmdname";
}
