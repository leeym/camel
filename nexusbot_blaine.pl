#!/opt/bin/perl
use HTTP::Tiny;
use JSON::XS qw(decode_json);
use Data::Dumper;
use strict;

my $locationId = '5020';
my $http       = HTTP::Tiny->new;

sub get
{
  my $url = shift;
  return $http->get($url)->{content};
}

sub post
{
  my $url    = shift;
  my $data   = shift;
  my $header = ['X-Priority' => 5];
  return $http->post($url, $header, $data);
}

my $base = 'https://ttp.cbp.dhs.gov/schedulerapi/slot-availability?locationId=';
my $url  = $base . $locationId;
warn "GET $url\n";
my $json = get($url) || die $!;
warn "$json\n";
my $hash = decode_json($json);
my $slot = $hash->{availableSlots}[0];
exit if !$slot;
my $startTimestamp = $slot->{startTimestamp};
print "startTimestamp: $startTimestamp\n";
post('https://ntfy.sh/nexus_blaine', $startTimestamp);
