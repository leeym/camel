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
use POSIX       qw(mktime);
use Time::HiRes qw(time);
use strict;

my $domain = shift || 'wbsc';
my $base   = "http://www.$domain.org";
my $year   = shift || (localtime)[5] + 1900;
my $ics    = new Data::ICal;
my $http   = new HTTP::Tiny;
my %URL;
my %VEVENT;
my $start = time();

sub get
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
  my $url      = shift;
  my $g        = shift;
  my $boxscore = $url . '/box-score/' . $g->{id};
  return $boxscore;
}

sub yyyy0
{
  return (localtime)[5] + 1900 - (((localtime)[4] + 1) <= 3 ? 1 : 0);
}

sub yyyy1
{
  return (localtime)[5] + 1900 + (((localtime)[4] + 1) >= 10 ? 1 : 0);
}

sub duration
{
  my $summary = shift;
  return '1:10' if $summary =~ m{U-12};
  return '2:00' if $summary =~ m{U-15};
  return '3:00';
}

sub event
{
  my $url  = shift;
  my $html = get($url);
  my $data = $1 if $html =~ m{data-page="(.*?)">};
  return if !$data;
  $data =~ s{&quot;}{"}g;
  my $d = decode_json($data);
  my $t = $d->{props}->{tournament};

  foreach my $g (@{ $d->{props}->{games} })
  {
    next if $VEVENT{ $g->{id} };
    next if $g->{homeioc} ne 'TPE' && $g->{awayioc} ne 'TPE';
    $ENV{TZ} = tz($g, $t);
    my $score = "$g->{awayruns}:$g->{homeruns}";
    $score = 'vs' if $score eq '0:0';
    my $away    = "$g->{awaylabel}";
    my $home    = "$g->{homelabel}";
    my $summary = "#$g->{gamenumber} $away $score $home";
    $summary .= " | $t->{tournamentname}";
    $summary .= " - $g->{gametypelabel}";
    $summary =~ s{Chinese Taipei}{Taiwan};
    my $start = $g->{start};

    if ($g->{gamestart})
    {
      $start = (split(' ', $start))[0] . ' ' . $g->{gamestart};
    }
    my ($yyyy, $mm, $dd, $HH, $MM) = split(/\D/, $start);

    # warn "$yyyy-$mm-$dd $HH:$MM ($ENV{TZ}) $summary\n";
    my $dtstart  = mktime(0, $MM, $HH, $dd, $mm - 1, $yyyy - 1900);
    my $duration = $g->{duration} || duration($summary);
    my ($hour, $min) = split(/\D/, $duration);
    $duration = 'PT' . int($hour) . 'H' . int($min) . 'M';
    my $standings = $url;
    $standings =~ s,schedule-and-results,standings,;
    my $description;
    $description .= "* " . $standings . "\n";
    $description .= "* " . boxscore($url, $g) . "\n";
    $description .= "* " . $g->{gamevideo} . "\n" if $g->{gamevideo};
    $description .= "* " . Date::ICal->new(epoch => time)->ical;
    my $vevent = Data::ICal::Entry::Event->new();
    $vevent->add_properties(
      description     => $description,
      dtstart         => Date::ICal->new(epoch => $dtstart)->ical,
      duration        => $duration,
      'last-modified' => Date::ICal->new(epoch => time)->ical,
      location        => $g->{stadium} . ', ' . $g->{location},
      summary         => $summary,
      uid             => $g->{id},
      url             => boxscore($url, $g),
    );
    $VEVENT{ $g->{id} } = $vevent;
  }
}

sub events
{
  my $url  = shift;
  my $html = get($url);
  foreach my $url ($html =~ m{href="([^"]+)"}g)
  {
    next if $url !~ m{/events/\d{4}-.*/home$};
    $url =~ s,/home,/schedule-and-results,;
    event($url);
  }
}

my @YEAR = ($year);
@YEAR = (yyyy0() .. yyyy1()) if scalar(@YEAR) == 0;

foreach my $yyyy (@YEAR)
{
  events("$base/calendar/$yyyy/baseball");
}

END
{
  warn "\nTotal: " . scalar(keys %VEVENT) . " events\n\n";
  foreach my $id (sort { $a <=> $b } keys %VEVENT)
  {
    $ics->add_entry($VEVENT{$id});
  }
  print $ics->as_string;
}
