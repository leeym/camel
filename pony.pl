#!/opt/bin/perl
use lib 'local/lib/perl5';
use AWS::XRay qw(capture capture_from);
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
my %VEVENT;
my $start = time();
my $now   = Date::ICal->new(epoch => $start)->ical, my @FUTURE;
my %SEGMENT;
my $loop = IO::Async::Loop->new();

captured(undef, \&pony, 'https://www.pony.org/');

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

sub pony
{
  my $url    = shift;
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html = $response->content;
      my $next = build_url(
        base_uri => 'https://www.pony.org',
        path     => $1,
      ) if $html =~ m{<a [^>]*href="([^"]+)">Baseball World Series</a>};
      return if !$next;
      captured($SEGMENT{$url}, \&schedules, $next);
    }
  );
  push(@FUTURE, $future);
}

sub schedules
{
  my $url    = shift;
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html = $response->content;
      while ($html =~ m{<a href="([^"]+)"[^>]*>\s*([^>]+?)\s*</a>})
      {
        my $href = $1;
        my $text = $2;
        $html = $';
        next if $text !~ m{World Series};
        next if $text !~ m{1(2|4|8)U};
        captured($SEGMENT{$url}, \&event, $href, $text);
      }
    }
  );
  push(@FUTURE, $future);
}

sub event
{
  my $url    = shift;
  my $title  = shift;
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html     = $response->content;
      my $base_uri = $1 if $url =~ m{^(https://.*?/)};
      my $next     = build_url(
        base_uri => $base_uri,
        path     => $1,
      ) if $html =~ m{<a [^>]*href="([^"]+)">GameChanger[^<]*</a>};
      return if !$next;
      captured($SEGMENT{$url}, \&teams, $next, $title);
    }
  );
  push(@FUTURE, $future);
}

sub teams
{
  my $url    = shift;
  my $title  = shift;
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html = $response->content;
      my ($next, $name) = ($1, $2)
        if $html =~ m{<a [^>]*href="([^"]+)">([^<]*Chinese Taipei)</a>};
      my $id = $1 if $next =~ m{/teams/([^/]+)/};
      $name =~ s{Chinese Taipei}{Taiwan};
      return if !$id;
      my $next = "https://api.team-manager.gc.com/public/teams/$id/games";
      captured($SEGMENT{$url}, \&team, $next, $id, $name, $title);
    }
  );
  push(@FUTURE, $future);
}

sub team
{
  my $url    = shift;
  my $id     = shift;
  my $name   = shift;
  my $title  = shift;
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
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
          dtstart         => Date::ICal->new(epoch => $start_ts + 1)->ical,
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

sub last_modified_description
{
  my $html;
  foreach my $url (keys %SEGMENT)
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

sub segment
{
  my $response = shift;
  my $url      = $response->request->url->as_string;
  my $segment  = $SEGMENT{$url};
  return if !$segment;
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
  my $elapsed = int(($segment->{end_time} - $segment->{start_time}) * 1000);
  warn "GET $url ($elapsed ms)\n";
}

sub captured
{
  my $parent = shift;
  my $func   = shift;
  my @args   = @_;
  my $url    = $args[0];
  my $code   = sub {
    my $segment = shift;
    $SEGMENT{$url} = $segment;
    $func->(@args);
  };
  my $name = $url;
  $name =~ s{\?}{#}g;
  if ($parent)
  {
    capture_from $parent->trace_header, $name => $code;
  }
  else
  {
    capture $name => $code;
  }
}
