#!/opt/bin/perl
use lib 'local/lib/perl5';
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use HTTP::Tiny;
use IO::Socket::SSL;
use JSON::Tiny qw(encode_json decode_json);
use Net::SSLeay;
use POSIX qw(mktime strftime);
use Time::HiRes qw(time);
use strict;

my $team = shift || 'TPE';
my $ics  = new Data::ICal;
my $http = new HTTP::Tiny;
my $base = 'http://www.wbsc.org';
my $YEAR = (localtime)[5] + 1900;
my %URL;

sub get
{
  my $url = shift;
  return if $URL{$url};
  $URL{$url}++;
  my %options;
  $options{headers}{Accept} = 'application/vnd.wbsc_tournaments.v1+json';
  my $start   = time;
  my $res     = $http->get($url, \%options);
  my $elapsed = int((time - $start) * 1000);
  die "$res->{status}: $res->{reason}" if !$res->{success};
  warn "GET $url ($elapsed ms)\n";
  return $res->{content};
}

sub tz
{
  my $g = shift;
  my $t = shift;
  return $g->{start_tz} if $g->{start_tz};
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
  warn 'G:' . Dumper($g);
  warn 'T:' . Dumper($t);
  die 'Unable to determine timezone for venueid:'
    . $g->{venueid}
    . ' location:'
    . $g->{location}
    . ' country:'
    . $country;
}

foreach my $year ($YEAR .. $YEAR + 1)
{
  foreach
    my $event (get("$base/calendar/$year") =~ m{href="(.*?)" target="_blank"}g)
  {
    next if $event !~ m{wbsc.org};
    next if $event =~ m{edition};
    next if $event =~ m{congress};
    next if $event =~ m{baseball5};
    next if $event =~ m{ranking};
    next if $event =~ m{documents};
    $event .= "/en/$year" if $event !~ m{$year};
    $event .= '/schedule-and-results';
    my $html = get($event);
    next if !$html;
    $html =~ s/&#039;/'/g;
    $html =~ s/\r//g;
    $html =~ s/\n//g;
    my @SCRIPT = ($html =~ m{(<script.*?</script>)}g);

    foreach my $script (@SCRIPT)
    {
      next if $script !~ m{tournament:};
      my $t = decode_json($1) if $script =~ m{tournament:\s*(\{.*\})\s*\};};
      my $id = $t->{id};
      my $schedules = "https://api.wbsc.org/api/tournaments/$id/schedules?";
      my $s         = decode_json(get($schedules));

      foreach my $g (sort { $a->{id} <=> $b->{id} } @{ $s->{data} })
      {
        next if $g->{home}->{ioc} ne $team && $g->{away}->{ioc} ne $team;
        $ENV{TZ} = tz($g, $t);
        my $score = $g->{away}->{runs} . ':' . $g->{home}->{runs};
        $score = 'vs' if $score eq '0:0';
        my $away    = $g->{away}->{label};
        my $home    = $g->{home}->{label};
        my $game    = $1 if $g->{label} =~ m{#(\d+)};
        my $round   = $1 if $g->{label} =~ m{\((.*?)\)};
        my $summary = "#$game $away $score $home";
        $summary .= " - $t->{tournamentname}";
        $summary .= " - $round";
        $summary =~ s{Chinese Taipei}{Taiwan};
        warn join(' ', $g->{id}, $g->{start}, $ENV{TZ}, $summary) . "\n";
        my $boxscore = $event . '/box-score/' . $g->{id};
        $boxscore =~ s{/en/}{/zh/};
        my ($yyyy, $mm, $dd, $HH, $MM) = split(/\D/, $g->{start});
        my $start = mktime(0, $MM, $HH, $dd, $mm - 1, $yyyy - 1900);
        my $duration = $g->{duration} || '3:00';
        my ($hour, $min) = split(/\D/, $duration);
        $duration = 'PT' . int($hour) . 'H' . int($min) . 'M';
        my $vevent = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description => "$boxscore\n\n"
            . $g->{video_url} . "\n\n"
            . strftime('%FT%T%z', gmtime),
          dtstart         => Date::ICal->new(epoch => $start)->ical,
          duration        => $duration,
          'last-modified' => Date::ICal->new(epoch => time)->ical,
          location        => $g->{stadium} . ', ' . $g->{location},
          summary         => $summary,
          uid             => $g->{id},
          url             => $boxscore,
        );
        $ics->add_entry($vevent);
      }
    }
  }
}

END
{
  print $ics->as_string;
}
