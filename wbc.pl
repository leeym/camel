#!/opt/bin/perl
use lib 'local/lib/perl5';
use strict;
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use Date::Parse;
use HTTP::Tiny;
use IO::Socket::SSL;
use JSON::Tiny qw(decode_json);
use Net::SSLeay;
use POSIX       qw(mktime);
use Time::HiRes qw(time);
use URL::Builder;

my $ics  = new Data::ICal;
my $http = new HTTP::Tiny;
my $base = 'https://www.mlb.com/world-baseball-classic/schedule';
my %URL;
my %VEVENT;
my $start = time();

my @YEAR = qw(2006 2009 2012 2013 2017 2023);
foreach my $year (@YEAR)
{
  event($year);
}

sub GET
{
  my $url = shift;
  $url =~ s{^http:}{https:};
  return $URL{$url} if $URL{$url};
  my $start = time;
  warn "GET $url\n";
  my $res     = $http->get($url);
  my $elapsed = int((time - $start) * 1000);
  die "$url: $res->{status}: $res->{reason}" if !$res->{success};
  warn "GOT $url ($elapsed ms)\n";
  my $body = $res->{content};
  $body =~ s/\\u\w+//g;
  $body =~ s/&#039;/'/g;
  $body =~ s/\r//g;
  $body =~ s/\n//g;
  $URL{$url} = $body;
  return $body;
}

sub event
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
  my $json = GET($url);
  my $data = decode_json($json);
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
      my $summary = sprintf(
        "#%d %s %s %s | World Baseball Classic %d - %s",
        $g->{seriesGameNumber},
        $away, $score, $home, $g->{season}, $g->{description},
      );
      my $epoch = str2time($g->{gameDate});

      # warn $g->{gameDate} . " $summary\n";
      my $gameday     = 'https://www.mlb.com/gameday/' . $g->{gamePk};
      my $description = "* $gameday \n";
      $description .= "* " . Date::ICal->new(epoch => time)->ical . "\n";
      my $vevent = Data::ICal::Entry::Event->new();
      $vevent->add_properties(
        description     => $description,
        dtstart         => Date::ICal->new(epoch => $epoch)->ical,
        duration        => 'PT3H0M',
        'last-modified' => Date::ICal->new(epoch => time)->ical,
        location        => venue($g->{venue}),
        summary         => $summary,
        uid             => $g->{gamePk},
        url             => $gameday,
      );
      $VEVENT{ $g->{gamePk} } = $vevent;
    }
  }

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

END
{
  foreach my $vevent (sort { dtstart($a) <=> dtstart($b) } values %VEVENT)
  {
    $ics->add_entry($vevent);
  }
  print $ics->as_string;
  warn "\n";
  warn "Total: " . scalar(keys %VEVENT) . " events\n";
  warn "Duration: " . int((time - $start) * 1000) . " ms\n";
}
