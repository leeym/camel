#!/opt/bin/perl
use lib 'local/lib/perl5';
use AnyEvent::HTTP;
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use EV;
use JSON::Tiny qw(decode_json);
use POSIX qw(mktime strftime);
use Time::HiRes qw(time);
use strict;

my $ics  = new Data::ICal;
my $base = 'https://www.wbsc.org';
my $YEAR = (localtime)[5] + 1900;
my %URL;
my @VEVENT;
my %TOURNAMENT;

sub dtstart
{
  my $vevent = shift;
  return value($vevent, 'dtstart');
}

sub value
{
  my $vevent = shift;
  my $field  = shift;
  return $vevent->{properties}->{$field}[0]->{value};
}

sub tz
{
  my $g = shift;
  my $t = shift;
  return $g->{timezone} if $g->{timezone};
  my $country = '';
  $country = $1 if ($g->{location} =~ m{\(([A-Z]{3})\)});
  foreach my $venue (@{ $t->{venues} })
  {
    next if $venue->{id} != $g->{venueid};
    return decode_json($venue->{info})->{timezone}->{timezone}
      if $venue->{info};
    $country = $venue->{country} if $venue->{country};
  }
  if (!$country)
  {
    my @COUNTRIES = keys(%{ $t->{hostinfo} });
    $country = shift @COUNTRIES if scalar(@COUNTRIES) == 1;
  }
  if ($country && $t->{hostinfo}->{$country})
  {
    return $t->{hostinfo}->{$country}->{timezone};
  }
  return 'Asia/Taipei' if $g->{location} =~ m{Taichung};
  return 'Asia/Taipei' if $g->{location} =~ m{Tainan};
  return 'Asia/Seoul'  if $g->{location} =~ m{Busan};
  warn 'G:' . Dumper($g);
  warn 'T:' . Dumper($t);
  warn 'Unable to determine timezone for venueid:'
    . $g->{venueid}
    . ' location:'
    . $g->{location}
    . ' country:'
    . $country;
}

sub GET
{
  my $url = shift;
  my $cb  = shift;
  $url =~ s{^http:}{https:};
  $URL{$url} = time;
  warn "=> GET $url\n";
  my %headers;
  if ($url =~ m{api.wbsc.org})
  {
    $headers{Accept} = 'application/vnd.wbsc_tournaments.v1+json';
  }
  http_get(
    $url,
    headers => \%headers,
    sub {
      my $body    = shift;
      my $headers = shift;
      my $url     = $headers->{URL};
      warn "<= GET $url (" . int((time - $URL{$url}) * 1000) . " ms)\n";
      $cb->($body, $headers);
      delete($URL{$url});
      EV::break if !scalar(keys(%URL));
    }
  );
}

sub schedules
{
  my $body    = shift;
  my $headers = shift;
  my $url     = $headers->{URL};
  my $tid     = $1 if $url =~ m{/(\d+)/};
  die "No tournament id in $url\n" if !$tid;
  my $t = $TOURNAMENT{$tid};
  die "No tournament info for $tid: " . Dumper(\%TOURNAMENT) if !$t;
  my $s = decode_json($body) || die "No nody: $url";

  foreach my $g (@{ $s->{data} })
  {
    my $score = $g->{away}->{runs} . ':' . $g->{home}->{runs};
    $score = 'vs' if $score eq '0:0';
    my $away    = $g->{away}->{label};
    my $home    = $g->{home}->{label};
    my $game    = $1 if $g->{label} =~ m{#(\d+)};
    my $round   = $1 if $g->{label} =~ m{\((.*?)\)};
    my $summary = "#$game $away $score $home";
    $summary .= " - " . $t->{tournamentname};
    $summary .= " - $round";
    $summary =~ s{Chinese Taipei}{Taiwan};
    next if $summary !~ m{Taiwan};
    my ($yyyy, $mm, $dd, $HH, $MM) = split(/\D/, $g->{start});
    $ENV{TZ} = tz($g, $t);
    my $start = mktime(0, $MM, $HH, $dd, $mm - 1, $yyyy - 1900);
    warn sprintf("%s (%s): %s\n", $g->{start}, $ENV{TZ}, $summary);
    my $duration = $g->{duration} || '3:00';
    my ($hour, $min) = split(/\D/, $duration);
    $duration = 'PT' . int($hour) . 'H' . int($min) . 'M';
    my $vevent = Data::ICal::Entry::Event->new();
    $vevent->add_properties(
      description     => $g->{video_url} . "\n\n" . strftime('%FT%T', gmtime),
      dtstart         => Date::ICal->new(epoch => $start)->ical,
      duration        => $duration,
      'last-modified' => Date::ICal->new(epoch => time)->ical,
      location        => $g->{stadium} . ', ' . $g->{location},
      summary         => $summary,
      uid             => $g->{id},
      url             => $g->{video_url},
    );
    push(@VEVENT, $vevent);

  }
  my $pagination = $s->{meta}->{pagination};
  if ($pagination->{current_page} < $pagination->{total_pages})
  {
    GET $pagination->{links}->{next}, \&schedules;
  }
}

sub event
{
  my $body    = shift;
  my $headers = shift;
  my $year    = $1 if $headers->{URL} =~ m{/(\d{4})/};
  $body =~ s/\r//g;
  $body =~ s/\n//g;
  foreach my $script ($body =~ m{(<script.*?</script>)}g)
  {
    next if $script !~ m{tournament:};
    if ($script =~ m{tournament:\s*(\{.*\})\s+\};})
    {
      my $t   = decode_json($1);
      my $tid = $t->{id};
      my $url = "https://api.wbsc.org/api/tournaments/$tid/schedules";
      $TOURNAMENT{$tid} = $t;
      GET "$url?page=1", \&schedules;
    }
  }
}

sub events
{
  my $body    = shift;
  my $headers = shift;
  my $year    = $1 if $headers->{URL} =~ m{/(\d{4})/};
  foreach my $event ($body =~ m{href="(.*?)" target="_blank"}g)
  {
    next if $event !~ m{wbsc.org};
    next if $event =~ m{edition};
    next if $event =~ m{congress};
    next if $event =~ m{baseball5};
    next if $event =~ m{ranking};
    next if $event =~ m{document};
    $event .= "/en/$year" if $event !~ m{$year};
    $event .= '/schedule-and-results';
    GET $event, \&event;
  }
}

sub calendar
{
  my $body    = shift;
  my $headers = shift;
  foreach my $events ($body =~ m{"(https://www.wbsc.org/calendar/\d+)">\d+}g)
  {
    GET $events, \&events;
  }
}

GET "$base/calendar", \&calendar;

EV::run;
foreach my $vevent (sort { dtstart($a) cmp dtstart($b) } @VEVENT)
{
  $ics->add_entry($vevent);
}
warn "\nTotal: " . scalar(@VEVENT) . " events\n\n";
print $ics->as_string;
