#!/opt/bin/perl
use lib 'local/lib/perl5';
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use Date::Parse;
use IO::Socket::SSL;
use JSON::XS qw(decode_json);
use Net::Async::HTTP;
use Net::SSLeay;
use POSIX       qw(mktime);
use Time::HiRes qw(time sleep);
use URL::Builder;
use strict;

my @YEAR = (2006 .. (localtime)[5] + 1901);
my $ics  = new Data::ICal;
my $http = Net::Async::HTTP->new(
  max_connections_per_host => 0,
  max_in_flight            => 0,
  timeout                  => 20,
);
my %VEVENT;
my $start = time();

IO::Async::Loop->new()->add($http);

my $url = build_url(
  base_uri => 'https://sph-s-api.olympics.com',
  path     => '/summer/schedules/api/ENG/schedule/noc/TPE',
);

warn "get $url\n";
my $future = $http->GET($url)->on_done(
  sub {
    my $response = shift;
    my $url      = $response->request->url;
    my $elapsed  = int((time - $start) * 1000);
    my $json     = $response->content;
    my $data     = decode_json($json);

    #warn "got $url ($elapsed ms)\n";
    foreach my $u (@{ $data->{'units'} })
    {
      my $summary     = $u->{'disciplineName'} . " " . $u->{'eventUnitName'};
      my $description = '';
      foreach my $c (@{ $u->{'competitors'} })
      {
        next if $c->{'noc'} ne 'TPE';
        $description .= $c->{'name'} . " " . results($c->{'results'}) . "\n";
      }

      #warn Dumper($u);
      my $vevent = Data::ICal::Entry::Event->new();
      $vevent->add_properties(
        dtstart         => ical($u->{'startDate'}),
        dtend           => ical($u->{'endDate'}),
        'last-modified' => Date::ICal->new(epoch => time)->ical,
        summary         => $summary,
        uid             => $u->{id},
        url      => 'https://olympics.com' . $u->{'extraData'}->{'detailUrl'},
        location => $u->{'locationDescription'},
        description => $description,
      );
      $ics->add_entry($vevent);
    }
  }
);
await $future->get();

END
{
  print $ics->as_string;
  warn "\n";
  warn "Total: " . scalar(keys %VEVENT) . " events\n";
  warn "Duration: " . int((time - $start) * 1000) . " ms\n";
  exit(0);
}

sub ical
{
  # 2024-07-25T09:30:00+02:00
  my $str   = shift;
  my @field = split(/\+/, $str);
  (my $ical   = $field[0]) =~ s{\W}{}g;
  (my $offset = $field[1]) =~ s{\W}{}g;
  return Date::ICal->new(ical => $ical, offset => '+' . $offset)->ical;
}

sub results
{
  my $r = shift;
  my $s = $r->{'mark'};
  $s .= ' [' . $r->{'winnerLoserTie'} . ']' if $r->{'winnerLoserTie'};
  return $s;
}
