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
my $counter;
my @VEVENT;
my %T;

sub mmdd
{
  my ($dd, $mm, $yy) = split('/', shift);
  return "$mm/$dd";
}

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
  warn 'G:' . Dumper($g);
  warn 'T:' . Dumper($t);
  die 'Unable to determine timezone for venueid:'
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
  $counter++;
  $T{$url} = time;
  $T{ $url . '/' } = time;
  warn "=> GET $url\n";
  my %headers;
  $headers{Accept} = 'application/vnd.wbsc_tournaments.v1+json';
  http_get $url,
    headers => \%headers,
    $cb;
}

sub elapsed
{
  my $url   = shift;
  my $start = $T{$url};
  return 0 if !$start;
  return int((time - $start) * 1000);
}

GET "$base/calendar", sub {
  my $body = shift;
  my $hdr  = shift;
  my $url  = $hdr->{URL};
  warn "<= GET $url (" . elapsed($url) . " ms)\n";
  foreach my $events ($body =~ m{"(https://www.wbsc.org/calendar/\d+)">\d+}g)
  {
    GET $events, sub {
      my $body = shift;
      my $hdr  = shift;
      my $url  = $hdr->{URL};
      warn "<= GET $url (" . elapsed($url) . " ms)\n";
      my $year = $1 if $url =~ m{/(\d{4})/};
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
        GET "$event", sub {
          my $body = shift;
          my $hdr  = shift;
          my $url  = $hdr->{URL};
          my $year = $1 if $url =~ m{/(\d{4})/};
          warn "<= GET $url (" . elapsed($url) . " ms)\n";
          $body =~ s/\r//g;
          $body =~ s/\n//g;
          foreach my $script ($body =~ m{(<script.*?</script>)}g)
          {
            next if $script !~ m{tournament:};
            my $t = decode_json($1)
              if $script =~ m{tournament:\s*(\{.*\})\s*\};};
            my $id = $t->{id};
            GET "https://api.wbsc.org/api/tournaments/$id/schedules?", sub {
              my $body = shift;
              my $hdr  = shift;
              my $url  = $hdr->{URL};
              my $s    = decode_json($body);
              foreach my $g (@{ $s->{data} })
              {
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
                next if $summary !~ m{Taiwan};
                my $boxscore = $url . '/box-score/' . $g->{id};
                $boxscore =~ s{/en/}{/zh/};
                my ($yyyy, $mm, $dd, $HH, $MM) = split(/\D/, $g->{start});
                $ENV{TZ} = tz($g, $t);
                my $start = mktime(0, $MM, $HH, $dd, $mm - 1, $yyyy - 1900);
                warn sprintf("%s (%s): %s\n", $g->{start}, $ENV{TZ}, $summary);
                my $duration = $g->{duration} || '3:00';
                my ($hour, $min) = split(/\D/, $duration);
                $duration = 'PT' . int($hour) . 'H' . int($min) . 'M';
                my $vevent = Data::ICal::Entry::Event->new();
                $vevent->add_properties(
                  description => "$boxscore\n\n"
                    . $g->{video_url} . "\n\n"
                    . strftime('%FT%T', gmtime),
                  dtstart         => Date::ICal->new(epoch => $start)->ical,
                  duration        => $duration,
                  'last-modified' => Date::ICal->new(epoch => time)->ical,
                  location        => $g->{stadium} . ', ' . $g->{location},
                  summary         => $summary,
                  uid             => $g->{id},
                  url             => $boxscore,
                );
                push(@VEVENT, $vevent);
              }
              $counter--;
              EV::break if !$counter;
            };
          }
          $counter--;
        };
      }
      $counter--;
    };
  }
  $counter--;
};
EV::run;
foreach my $vevent (sort { dtstart($a) cmp dtstart($b) } @VEVENT)
{
  $ics->add_entry($vevent);
}
warn "\nTotal: " . scalar(@VEVENT) . " events\n\n";
print $ics->as_string;
