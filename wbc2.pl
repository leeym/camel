#!/opt/bin/perl
use lib 'local/lib/perl5';
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use Date::Parse;
use Net::Async::HTTP;
use IO::Socket::SSL;
use JSON::Tiny qw(decode_json);
use Net::SSLeay;
use POSIX       qw(mktime);
use Time::HiRes qw(time);
use strict;

my $ics  = new Data::ICal;
my $http = Net::Async::HTTP->new(max_connections_per_host => 0);
my %VEVENT;
my $start = time();
my @FUTURE;
my %START;

IO::Async::Loop->new()->add($http);

foreach my $year (qw(2006 2009 2013 2017 2023))
{
  event($year);
}

sub event
{
  my $year = shift;
  my $url =
"https://bdfed.stitch.mlbinfra.com/bdfed/transform-mlb-schedule?stitch_env=prod&sortTemplate=5&sportId=51&startDate=$year-01-01&endDate=$year-12-31&gameType=S&&gameType=R&&gameType=F&&gameType=D&&gameType=L&&gameType=W&&gameType=A&language=en&leagueId=159&&leagueId=160&contextTeamId=";
  return if $START{$url};
  $START{$url} = time;
  warn "get $url\n";
  my $future = $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $elapsed  = int((time - $START{$url}) * 1000);
      warn "got $url ($elapsed ms)\n";
      my $json = $response->content;
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
          warn $g->{gameDate} . " $summary\n";
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
  );
  push(@FUTURE, $future);
}

foreach my $future (@FUTURE)
{
  await $future->get();
}

sub venue
{
  my $v = shift;
  my $l = $v->{location};
  return sprintf('%s, %s, %s, %s, %s',
    $v->{name}, $l->{address1}, $l->{address2}, $l->{city}, $l->{country});
}

END
{
  foreach my $id (sort { $a <=> $b } keys %VEVENT)
  {
    $ics->add_entry($VEVENT{$id});
  }
  print $ics->as_string;
  warn "\n";
  warn "Total: " . scalar(keys %VEVENT) . " events\n";
  warn "Duration: " . int((time - $start) * 1000) . " ms\n";
}
