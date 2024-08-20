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
my $now   = Date::ICal->new(epoch => $start)->ical, my @FUTURE;
my %START;
IO::Async::Loop->new()->add($http);

home('https://www.pony.org/');

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
  'last-modified' => $now,
);
$ics->add_entry($vevent);
print $ics->as_string;

END
{
  warn "Total: " . scalar(keys %VEVENT) . " events\n";
  warn "Duration: " . int((time - $start) * 1000) . " ms\n";
}

sub home
{
  my $url = shift;
  return if $START{$url};
  $START{$url} = time;
  my $future = $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $elapsed  = int((time - $START{$url}) * 1000);
      warn "GET $url ($elapsed ms)\n";
      my $html = $response->content;
      my $next = my $url = build_url(
        base_uri => 'https://www.pony.org',
        path     => $1,
      ) if $html =~ m{<a [^>]*href="([^"]+)">Baseball World Series</a>};
      return if !$next;
      schedules($next);
    }
  );
  push(@FUTURE, $future);
}

sub schedules
{
  my $url = shift;
  return if $START{$url};
  $START{$url} = time;
  my $future = $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $elapsed  = int((time - $START{$url}) * 1000);
      warn "GET $url ($elapsed ms)\n";
      my $html = $response->content;
      while ($html =~ m{<a href="([^"]+)"[^>]*>\s*([^>]+?)\s*</a>})
      {
        my $href = $1;
        my $text = $2;
        $html = $';
        next if $text !~ m{World Series};
        next if $text !~ m{1(2|4|8)U};
        event($href, $text);
      }
    }
  );
  push(@FUTURE, $future);
}

sub event
{
  my $url   = shift;
  my $title = shift;
  return if $START{$url};
  $START{$url} = time;
  my $future = $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $elapsed  = int((time - $START{$url}) * 1000);
      warn "GET $url ($elapsed ms)\n";
      my $html     = $response->content;
      my $base_uri = $1 if $url =~ m{^(https://.*?/)};
      my $next     = build_url(
        base_uri => $base_uri,
        path     => $1,
      ) if $html =~ m{<a [^>]*href="([^"]+)">GameChanger[^<]*</a>};
      return if !$next;
      teams($next, $title);
    }
  );
  push(@FUTURE, $future);
}

sub teams
{
  my $url   = shift;
  my $title = shift;
  return if $START{$url};
  $START{$url} = time;
  my $future = $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $elapsed  = int((time - $START{$url}) * 1000);
      warn "GET $url ($elapsed ms)\n";
      my $html = $response->content;
      my ($next, $name) = ($1, $2)
        if $html =~ m{<a [^>]*href="([^"]+)">([^<]*Chinese Taipei)</a>};
      my $tid = $1 if $next =~ m{/teams/([^/]+)/};
      $name =~ s{Chinese Taipei}{Taiwan};
      return if !$tid;
      team($tid, $name, $title);
    }
  );
  push(@FUTURE, $future);
}

sub team
{
  my $id    = shift;
  my $name  = shift;
  my $title = shift;
  my $url   = "https://api.team-manager.gc.com/public/teams/$id/games";
  return if $START{$url};
  $START{$url} = time;
  my $future = $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $elapsed  = int((time - $START{$url}) * 1000);
      warn "GET $url ($elapsed ms)\n";
      my $json = $response->content;
      my $data = decode_json($json);
      foreach my $g (@{$data})
      {
        next if $VEVENT{ $g->{id} };

        #warn Dumper($g);
        my $summary;
        my $home;
        my $away;
        my $score;
        if ($g->{home_away} eq 'home')
        {
          $home  = $name;
          $away  = $g->{opponent_team}->{name};
          $score = $g->{score}->{opponent_team} . ':' . $g->{score}->{team};
        }
        else
        {
          $home  = $g->{opponent_team}->{name};
          $away  = $name;
          $score = $g->{score}->{team} . ':' . $g->{score}->{opponent_team};
        }
        $score = 'vs' if $score eq '0:0';
        my $summary  = "$away $score $home | $title";
        my $start_ts = str2time($g->{start_ts});
        my $end_ts   = str2time($g->{end_ts});

        warn $g->{start_ts} . " $summary\n";
        my $description =
          "<ul><li><a href=\"https://web.gc.com/teams/$id\">Team</a></li></ul>";
        my $vevent = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description     => $description,
          dtstart         => Date::ICal->new(epoch => $start_ts)->ical,
          dtend           => Date::ICal->new(epoch => $end_ts)->ical,
          'last-modified' => $now,
          summary         => $summary,
          uid             => $g->{id},
        );
        $VEVENT{ $g->{id} } = $vevent;
      }
    }
  );
  push(@FUTURE, $future);
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
