#!/opt/bin/perl
use lib 'local/lib/perl5';
use AWS::XRay qw(capture);
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
my %START;
my %VEVENT;
my @FUTURE;
my $start = time();
my $now   = Date::ICal->new(epoch => $start)->ical;

my $loop = IO::Async::Loop->new();

my $url = build_url(
  base_uri => 'https://sph-s-api.olympics.com',
  path     => '/summer/schedules/api/ENG/schedule/noc/TPE',
);

my %METAL;
$METAL{1} = 'Gold';
$METAL{3} = 'Bronze';

$START{$url} = time();

capture $url => sub {
  my $segment = shift;
  my $future  = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      $segment = wrapped($segment, $response);
      my $url     = $response->request->url;
      my $elapsed = elapsed($segment);
      warn "GET $url ($elapsed ms)\n";
      my $json = $response->content;
      my $data = decode_json($json);
      foreach my $u (@{ $data->{'units'} })
      {
        my $url = 'https://olympics.com' . $u->{'extraData'}->{'detailUrl'};
        my $medalFlag = $u->{'medalFlag'};
        my $summary;
        $summary = "[" . $METAL{$medalFlag} . "] " if $medalFlag;
        $summary .= $u->{'disciplineName'} . " " . $u->{'eventUnitName'};

        my $description = '<ul>';
        $description .= '<li><a href="' . $url . '">Details</a></li>';
        $description .= '<li>' . $u->{'locationDescription'} . '</li>';
        $description .= '</ul>';

        foreach my $c (@{ $u->{'competitors'} })
        {
          next if $c->{'noc'} ne 'TPE';
          $description .= $c->{'name'} . " " . results($c->{'results'}) . "\n";
        }
        my $vevent = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          uid             => $u->{id},
          url             => $url,
          location        => $u->{'venueDescription'},
          dtstart         => ical($u->{'startDate'}),
          dtend           => ical($u->{'endDate'}),
          summary         => $summary,
          description     => $description,
          'last-modified' => $now,
        );
        $VEVENT{ $u->{id} } = $vevent;
      }
    }
  );
  push(@FUTURE, $future);
};

foreach my $future (@FUTURE)
{
  my $future = shift @FUTURE;
  await $future->get();
}

foreach my $vevent (sort by_dtstart values %VEVENT)
{
  $ics->add_entry($vevent);
}
my $vevent = Data::ICal::Entry::Event->new();
$vevent->add_properties(
  dtstart         => Date::ICal->new(epoch => $start)->ical,
  dtend           => Date::ICal->new(epoch => time)->ical,
  summary         => 'Last Modified',
  uid             => 'Last Modified',
  description     => last_modified_description(),
  'last-modified' => $now,
);
$ics->add_entry($vevent);
print $ics->as_string;

END
{
  die $@ if $@;
  warn "Total: " . scalar(keys %VEVENT) . " events\n";
  warn "Duration: " . int((time - $start) * 1000) . " ms\n";
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

sub dtstart
{
  my $vevent = shift;
  return $vevent->{properties}{'dtstart'}[0]->{value};
}

sub by_dtstart
{
  return dtstart($a) cmp dtstart($b);
}

sub last_modified_description
{
  my $html;
  foreach my $url (keys %START)
  {
    $html .= "<li>$url</li>";
  }
  return "<ul>$html</ul>";
}

sub http
{
  my $http = Net::Async::HTTP->new(
    max_connections_per_host => 0,
    max_in_flight            => 0,
    timeout                  => $start + 28 - time,
  );
  $loop->add($http);
  return $http;
}

sub elapsed
{
  my $segment = shift;
  return int(($segment->{end_time} - $segment->{start_time}) * 1000);
}

sub wrapped
{
  my $segment  = shift;
  my $response = shift;
  my $url      = $response->request->url->as_string;
  $segment->{end_time} = time;
  $segment->{http}     = {
    request => {
      method => $response->request->method,
      url    => $url,
    },
    response => {
      status         => $response->code,
      content_length => length($response->content),
    },
  };
  return $segment;
}
