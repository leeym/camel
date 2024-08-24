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

my @YEAR = (2006, 2009, 2012, 2013, 2017, 2023, 2026);
my $ics  = new Data::ICal;
my $http = Net::Async::HTTP->new(
  max_connections_per_host => 0,
  max_in_flight            => 0,
  timeout                  => 20,
);
my %VEVENT;
my $start = time();
my $now   = Date::ICal->new(epoch => $start)->ical;
my @FUTURE;
my %START;

my $loop = IO::Async::Loop->new();

foreach my $year (reverse sort @YEAR)
{
  captured_event($year);
}

while (scalar(@FUTURE))
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

sub last_modified_description
{
  my $html;
  foreach my $url (keys %START)
  {
    $html .= "<li>$url</li>";
  }
  return "<ul>$html</ul>";
}

sub venue
{
  my $v = shift;
  my $l = $v->{location};
  return sprintf('%s, %s, %s, %s, %s',
    $v->{name}, $l->{address1}, $l->{address2}, $l->{city}, $l->{country});
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

sub captured_event
{
  my $year = shift;
  my $url  = build_url(
    base_uri => 'https://bdfed.stitch.mlbinfra.com',
    path     => '/bdfed/transform-mlb-schedule',
    query    => [
      stitch_env   => 'prod',
      sortTemplate => 5,
      sportId      => 51,
      startDate    => "$year-01-01",
      endDate      => "$year-12-31",
      gameType     => 'A',
      gameType     => 'D',
      gameType     => 'F',
      gameType     => 'L',
      gameType     => 'R',
      gameType     => 'S',
      gameType     => 'W',
      language     => 'en',
      leagueId     => 159,
      leagueId     => 160,
    ],
  );
  capture $year => sub {
    my $segment = shift;
    event($url, $segment);
  }
}

sub event
{
  my $url     = shift;
  my $segment = shift;
  return if $START{$url};
  $START{$url} = time;
  $segment->{start_time} = $START{$url};
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      $segment = wrapped($segment, $response);
      my $url     = $response->request->url;
      my $elapsed = elapsed($segment);
      my $json    = $response->content;
      my $data    = decode_json($json);
      warn "GET $url ($elapsed ms)\n";

      foreach my $date (@{ $data->{dates} })
      {
        next if $date->{totalGames} == 0;
        foreach my $g (@{ $date->{games} })
        {
          next if $VEVENT{ $g->{gamePk} };
          my $tpe  = 'Chinese Taipei';
          my $twn  = 'Taiwan';
          my $away = $g->{teams}->{away}->{team}->{teamName};
          my $home = $g->{teams}->{home}->{team}->{teamName};
          next if $away ne $tpe && $home ne $tpe;
          $away = $twn if $away eq $tpe;
          $home = $twn if $home eq $tpe;

          # warn Dumper($g);
          my $score = sprintf('%d:%d',
            $g->{teams}->{away}->{score},
            $g->{teams}->{home}->{score});
          $score = 'vs' if $score eq '0:0';
          my $summary = sprintf("%s %s %s | World Baseball Classic %s - %s",
            $away, $score, $home, $g->{season}, $g->{description});
          my $epoch = str2time($g->{gameDate});

          warn $g->{gameDate} . " $summary\n";
          my $gameday = 'https://www.mlb.com/gameday/' . $g->{gamePk};
          my %DESC;
          $DESC{Gameday} = $gameday;
          my $desc = '<ul>';
          foreach my $text (sort keys %DESC)
          {
            $desc .= '<li>';
            $desc .= sprintf('<a href="%s">%s</a>', $DESC{$text}, $text);
            $desc .= '</li>';
          }
          $desc .= '</ul>';
          my $vevent = Data::ICal::Entry::Event->new();
          $vevent->add_properties(
            description     => $desc,
            dtstart         => Date::ICal->new(epoch => $epoch + 1)->ical,
            duration        => 'PT3H0M',
            'last-modified' => $now,
            location        => venue($g->{venue}),
            summary         => $summary,
            uid             => $g->{gamePk},
            url             => $gameday,
          );
          $VEVENT{ $g->{gamePk} } = $vevent;
        }
      }
    }
  );
  push(@FUTURE, $future);
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
      method => 'GET',
      url    => $url,
    },
    response => {
      status => $response->code,
    },
  };
  return $segment;
}
