#!/opt/bin/perl
use lib 'local/lib/perl5';
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use HTTP::Tiny;
use IO::Socket::SSL;
use JSON::Tiny qw(decode_json);
use Net::SSLeay;
use POSIX qw(mktime);
use Time::HiRes qw(time);
use strict;

my $team = shift || 'TPE';
my $ics  = new Data::ICal;
my $http = new HTTP::Tiny;
my $base = 'http://www.wbsc.org';
my $YEAR = (localtime)[5] + 1900;
my %URL;
my @VEVENT;

sub get
{
  my $url = shift;
  $url =~ s{^http:}{https:};
  die "$url: duplicate\n" if $URL{$url};
  $URL{$url}++;
  my $start   = time;
  my $res     = $http->get($url);
  my $elapsed = int((time - $start) * 1000);
  die "$url: $res->{status}: $res->{reason}" if !$res->{success};
  warn "GET $url ($elapsed ms)\n";
  my $body = $res->{content};
  $body =~ s/\\u\w+//g;
  $body =~ s/&#039;/'/g;
  $body =~ s/\r//g;
  $body =~ s/\n//g;
  return $body;
}

sub mmdd
{
  my ($dd, $mm, $yy) = split('/', shift);
  return "$yy-$mm-$dd";
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

sub boxscore
{
  my $g   = shift;
  my $t   = shift;
  my $url = $t->{external_link} . '/schedule-and-results/box-score/' . $g->{id};
  $url =~ s{/en/}{/zh/};
  return $url;
}

foreach my $year ($YEAR - 1 .. $YEAR + 1)
{
  my $html = get("$base/calendar/$year");
  foreach my $event ($html =~ m{href="([^"]+)" target="_blank"}g)
  {
    next if $event !~ m{wbsc.org};
    next if $event =~ m{edition};
    next if $event =~ m{rankings};
    next if $event =~ m{congress};
    next if $event =~ m{baseball5};
    $event .= "/en/$year" if $event !~ m{$year};
    $event .= '/schedule-and-results';
    next if $event =~ m{/e-2020-};
    my $html   = get($event);
    my @SCRIPT = ($html =~ m{(<script.*?</script>)}g);

    foreach my $script (@SCRIPT)
    {
      next if $script !~ m{schedule:};
      next if $script !~ m{tournament:};
      my $s = $1 if $script =~ m{schedule:\s*(\{.*?\})\s{8,}\};};
      $s = decode_json($s);
      my $t = $1 if $script =~ m{tournament:\s*(\{.*?\}),\s{8,}};
      $t = decode_json($t);
      foreach my $g (@{ $s->{games} })
      {
        next if $g->{homeioc} ne 'TPE' && $g->{awayioc} ne 'TPE';
        $ENV{TZ} = tz($g, $t);
        my $score = "$g->{awayruns}:$g->{homeruns}";
        $score = 'vs' if $score eq '0:0';
        my $away    = "$g->{awaylabel}";
        my $home    = "$g->{homelabel}";
        my $summary = "#$g->{gamenumber} $away $score $home";
        $summary .= " - $t->{tournamentname}";
        $summary .= " - $g->{gametypelabel}";
        $summary =~ s{Chinese Taipei}{Taiwan};
        my $start = $g->{start};

        if ($g->{gamestart})
        {
          $start = (split(' ', $start))[0] . ' ' . $g->{gamestart};
        }
        warn $start . ' (' . $ENV{TZ} . ') ' . $summary . "\n";
        my ($yyyy, $mm, $dd, $HH, $MM) = split(/\D/, $start);
        my $dtstart = mktime(0, $MM, $HH, $dd, $mm - 1, $yyyy - 1900);
        my $duration = $g->{duration} || '3:00';
        my ($hour, $min) = split(/\D/, $duration);
        $duration = 'PT' . int($hour) . 'H' . int($min) . 'M';
        my $description;
        $description .= boxscore($g, $t) . "\n";
        $description .= Date::ICal->new(epoch => time)->ical;
        my $vevent = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description     => $description,
          dtstart         => Date::ICal->new(epoch => $dtstart)->ical,
          duration        => $duration,
          'last-modified' => Date::ICal->new(epoch => time)->ical,
          location        => $g->{stadium} . ', ' . $g->{location},
          summary         => $summary,
          uid             => $g->{id},
          url             => boxscore($g, $t),
        );
        push(@VEVENT, $vevent);
      }
    }
  }
}

END
{
  warn "\nTotal: " . scalar(@VEVENT) . " events\n\n";
  foreach my $vevent (@VEVENT)
  {
    $ics->add_entry($vevent);
  }
  print $ics->as_string;
}
