#!/usr/bin/perl

#
# The MIT License (MIT)
#
# Copyright (c) 2013 Damian Murphy
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

use strict;
use warnings;

use POSIX;
use LWP;
use HTTP::Request;
use XML::Simple;
use Date::Parse;
use Data::Dumper;

my $CACHE_FILE = '.service_cache';
my $HOSTNAME = $ENV->{'COLLECTD_HOSTNAME'} ? $ENV->{'COLLECTD_HOSTNAME'} : 'localhost';
my $INTERVAL = 3600;
my $ATTEMPTS = 5;
my $BACKOFF_TIME = 60;
my $API_BASE = 'https://customer-webtools-api.internode.on.net';
my $SERVICE_INFO_PATH = '/api/v1.5/';

my $username = undef;
my $password = undef;
my $datadir = undef;

if ($ARGV[0]) {
    $datadir = $ARGV[0];
    print STDERR "Reading auth config from data dir: ${datadir}\n";
    open(DDIR, $datadir . '/.auth') or die("Failed to open .auth file");
    while (<DDIR>) {
        chomp;
        my $line = $_;
        if ($line =~ /user:/) {
            ($username) = $line =~ /user:(.*)/;
            print STDERR "Config for user: ${username}\n";
        } elsif ($line =~ /password:/) {
            ($password) = $line =~ /password:(.*)/;
        }
    }
    close(DDIR) or die("Failed to close .auth file");
} else {
  print "Usage:\n";
  print "node_usage.pl <data directory>\n\n";
  exit(10);
}

my $ua = LWP::UserAgent->new;
$ua->timeout(10);
$ua->agent("NodeUsageCollectdPlugin/0.0.0 (https://github.com/damomurf/node-usage-collectd)");

my $usage_href = undef;

# Next poll delay
sub next_poll_delay() {
    my $now = time();
    my $delay = $INTERVAL - ($now % $INTERVAL);
    print STDERR "Sleeping $delay\n";
    sleep $delay;
}

if (-r "$datadir/$CACHE_FILE") {
    # Read the cached HREF
    print STDERR "Reading cached service url\n";

    if (open(FCACHE, "<$datadir/$CACHE_FILE")) {
        $usage_href = <FCACHE>;
        chomp $usage_href;

        if (not defined($usage_href)) {
            print STDERR "Cache is invalid\n";
            unlink($CACHE_FILE) or die ("Could not delete cache file");
        } else {
            print STDERR "Cached href: $usage_href\n";
        }
    }
}

if (not defined($usage_href)) {
    # Cache the Usage HREF
    print STDERR "Caching new service url\n";

    my $req = HTTP::Request->new(GET => $API_BASE . $SERVICE_INFO_PATH);
    $req->authorization_basic($username, $password);

    my $response = $ua->request($req);

    if ($response->is_success) {
        my $xml = $response->decoded_content;
        my $ref = XMLin($xml);

        my $service = $ref->{'api'}->{'services'}->{'service'};
        $usage_href = $service->{'href'} . '/usage';

        open(FCACHE, '>'. $datadir . '/' . $CACHE_FILE)
            or die("Failed to write cache");

        print FCACHE $usage_href . "\n" or die("Failed to write cache file");
        close(FCACHE) or die("Failed to write cache file");
    }
}

defined($usage_href) or die("Could not retrieve usage URI");

#Enable output buffer auto flush
$| = 1;

while (1) {

    my $attempts = $ATTEMPTS;
    while ($attempts gt 0) {
        my $req = HTTP::Request->new(GET => $API_BASE . $usage_href);
        $req->authorization_basic($username, $password);
        $attempts--;

        my $response = $ua->request($req);

        if ($response->is_success) {

            my $xml = $response->decoded_content;

            my $ref = XMLin($xml);
            my $quota = $ref->{api}->{traffic}->{quota};
            my $usage = $ref->{api}->{traffic}->{content};
            my $rollover = $ref->{api}->{traffic}->{rollover}; # yyyy-mm-dd

            my ($rollover_year, $rollover_month, $rollover_day) = $rollover =~ /^(\d{4})-(\d{2})-(\d{2})\z/;

            my $start_year = $rollover_year;
            my $start_month = $rollover_month - 1;
            my $start_day = $rollover_day;

            my $rollover_time = POSIX::mktime(0,0,0,$rollover_day, $rollover_month-1,$rollover_year-1900);
            my $start_time = POSIX::mktime(0,0,0,$start_day, $start_month-1,$start_year-1900);
            my $now = time();

            my $quota_per_sec = $quota / ($rollover_time - $start_time);
            my $target = $quota_per_sec * ($now - $start_time);

            print "PUTVAL \"${HOSTNAME}/usage/gauge-quota\" interval=" . $INTERVAL . " N:" . $quota . "\n";
            print "PUTVAL \"${HOSTNAME}/usage/gauge-target\" interval=" . $INTERVAL . " N:" . int($target) . "\n";
            print "PUTVAL \"${HOSTNAME}/usage/gauge-used\" interval=" . $INTERVAL . " N:" . $usage . "\n";
            print "PUTVAL \"${HOSTNAME}/usage/gauge-remain\" interval=" . $INTERVAL . " N:" . ( $quota - $usage ) ."\n";
            print STDERR "Wrote: quota=${quota} target=${target} usage=${usage}\n";

            # Success, we don't need to try any more.
            $attempts = 0;
        }
        else {
            # We failed, so wait a few seconds then try again
            print STDERR $response->status_line
                . ": $attempts attempts remain.\n";
            sleep (($ATTEMPTS - $attempts) * $BACKOFF_TIME);
        }
    }

    next_poll_delay();
}
