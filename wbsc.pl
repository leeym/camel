#!/opt/bin/perl
use lib 'local/lib/perl5';
use AnyEvent::HTTP;
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use EV;
use JSON::Tiny qw(decode_json);
use POSIX qw(mktime);
use Time::HiRes qw(time);
use strict;

my $ics  = new Data::ICal;
my $base = 'http://www.wbsc.org';
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
  http_get $url, $cb;
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
  foreach my $events ($body =~ m{"(/events/filter/\d+/all)">\d+<}g)
  {
    GET "$base$events", sub {
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
            next if $script !~ m{schedule:};
            next if $script !~ m{tournament:};
            my ($s, $t) = (decode_json($1), decode_json($2))
              if $script =~
              m{schedule:\s*(\{.*?\}),\s+tournament:\s*(\{.*\})\s*\};};
            foreach
              my $ddmm (sort { mmdd($a) cmp mmdd($b) } keys %{ $s->{games} })
            {
              foreach my $g (@{ $s->{games}->{$ddmm} })
              {
                my $score = "$g->{awayruns}:$g->{homeruns}";
                $score = 'vs' if $score eq '0:0';
                my $away    = "$g->{awaylabel}";
                my $home    = "$g->{homelabel}";
                my $summary = "#$g->{gamenumber} $away $score $home";
                $summary .= " - $t->{tournamentname}";
                $summary .= " - $g->{gametypelabel}";
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
                  description => $boxscore,
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
            }
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
EV::run;
foreach my $vevent (sort { dtstart($a) cmp dtstart($b) } @VEVENT)
{
  $ics->add_entry($vevent);
}
warn "\nTotal: " . scalar(@VEVENT) . " events\n\n";
print $ics->as_string;
