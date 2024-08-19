#!/opt/bin/perl
use lib 'local/lib/perl5';
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use IO::Async::SSL;
use IO::Socket::SSL;
use JSON::XS qw(decode_json);
use Net::Async::HTTP;
use Net::SSLeay;
use POSIX       qw(mktime);
use Time::HiRes qw(time);
use strict;

my $ics = new Data::ICal;
my %URL;
my %VEVENT;
my $http = Net::Async::HTTP->new(
  max_connections_per_host => 0,
  max_in_flight            => 0,
  timeout                  => 20,
);
my %START;
my @FUTURE;
my $start = time;
my $now   = Date::ICal->new(epoch => $start)->ical;

IO::Async::Loop->new()->add($http);

sub by_year
{
  return -1 if $a == ((localtime)[5] + 1900);
  return $b <=> $a;
}

sub dtstart
{
  my $vevent = shift;
  return $vevent->{properties}->{dtstart}[0]->{value};
}

sub by_dtstart
{
  return dtstart($a) cmp dtstart($b);
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

sub yyyy
{
  return (localtime)[5] + 1900;
}

sub duration
{
  my $summary = shift;
  return '1:10' if $summary =~ m{U-12};
  return '2:00' if $summary =~ m{U-15};
  return '3:00';
}

sub year
{
  my $url = shift;
  return if $START{$url};
  $START{$url} = time;
  my $future = $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $html     = $response->content;
      my $elapsed  = int((time - $START{$url}) * 1000);
      warn "GET $url ($elapsed ms)\n";
      foreach my $url ($html =~ m{window.open\('([^']+)'}g)
      {
        next if $url !~ m{/events/\d{4}-.*/home$};
        $url =~ s,/home,/schedule-and-results,;
        next if $START{$url};
        events($url);
      }
    }
  );
  push(@FUTURE, $future);
}

sub events
{
  my $url = shift;
  return if $START{$url};
  $START{$url} = time;
  my $future = $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $html     = $response->content;
      my $data     = $1 if $html =~ m{data-page="(.*?)">};
      return if !$data;
      my $elapsed = int((time - $START{$url}) * 1000);
      warn "GET $url ($elapsed ms)\n";
      $data =~ s{&quot;}{"}g;
      $data =~ s{&#039;}{'}g;
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
        my $summary = "$away $score $home";
        $summary .= " | $t->{tournamentname}";
        $summary .= " - $g->{gametypelabel}";
        $summary =~ s{Chinese Taipei}{Taiwan};
        my $start = $g->{start};

        if ($g->{gamestart})
        {
          $start = (split(' ', $start))[0] . ' ' . $g->{gamestart};
        }
        my ($year, $month, $day, $hour, $min) = split(/\D/, $start);

        my $dtstart = Date::ICal->new(
          year  => $year,
          month => $month,
          day   => $day,
          hour  => $hour,
          mon   => $min,
        )->ical;
        $dtstart =~ s{Z}{T000000Z} if $dtstart !~ m{T};
        warn "$start ($ENV{TZ}) $summary\n";
        my $duration = $g->{duration} || duration($summary);
        my ($hour, $min) = split(/\D/, $duration);
        $duration = 'PT' . int($hour) . 'H' . int($min) . 'M';
        my $standings = $url;
        $standings =~ s,schedule-and-results,standings,;
        my $boxscore    = boxscore($url, $g);
        my $description = '<ul>';
        $description .= '<li><a href="' . $standings . '">Standing</a></li>';
        $description .= '<li><a href="' . $boxscore . '">Box Score</a></li>';
        $description .= '<li><a href="' . $g->{gamevideo} . '">Watch</a></li>'
          if $g->{gamevideo};
        $description .= '</ul>';
        my $vevent = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description     => $description,
          dtstart         => $dtstart,
          duration        => $duration,
          'last-modified' => $now,
          location        => $g->{stadium} . ', ' . $g->{location},
          summary         => $summary,
          uid             => $g->{id},
          url             => $boxscore,
        );
        $VEVENT{ $g->{id} } = $vevent;
      }
    }
  );
  push(@FUTURE, $future);
}

foreach my $yyyy (sort by_year (yyyy() - 10 .. yyyy() + 1))
{
  foreach my $domain ('wbsc', 'wbscasia')
  {
    year("https://www.$domain.org/en/calendar/$yyyy/baseball");
  }
}

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
  dtstart => Date::ICal->new(epoch => $start)->ical,
  dtend   => Date::ICal->new(epoch => time)->ical,
  summary => 'Last Modified',
  uid     => 'Last Modified',
);
$ics->add_entry($vevent);
print $ics->as_string;

END
{
  warn "Total: " . scalar(keys %VEVENT) . " events\n";
  warn "Duration: " . int((time - $start) * 1000) . " ms\n";
}
