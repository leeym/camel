#!/opt/bin/perl
use lib 'local/lib/perl5';
use AWS::XRay qw(capture capture_from);
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

my $start = time;
my $now   = Date::ICal->new(epoch => $start)->ical;
my $loop  = new IO::Async::Loop;
my $ics   = new Data::ICal;
my %SEGMENT;
my %VEVENT;
my @FUTURE;
my @YEAR = (2012 .. yyyy() + 1);

for my $yyyy (sort by_year @YEAR)
{
  for my $domain ('wbsc', 'wbscasia')
  {
    my $url = "https://www.$domain.org/en/calendar/$yyyy/baseball";
    captured($ENV{_X_AMZN_TRACE_ID}, \&calendar, $url);
  }
}

for my $future (@FUTURE)
{
  await $future->get();
}

for my $vevent (sort by_dtstart values %VEVENT)
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

sub tz
{
  my $g = shift;
  my $t = shift;
  return $g->{start_tz} if $g->{start_tz};
  my $country = '';
  $country = $1 if ($g->{location} =~ m{\(([A-Z]{3})\)});
  for my $venue (@{ $t->{venues} })
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

sub calendar
{
  my $url    = shift;
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html = $response->content;
      for my $next ($html =~ m{window.open\('([^']+)'}g)
      {
        next if $next !~ m{/events/\d{4}-.*/\w+$};
        $next =~ s{/\w+$}{/schedule-and-results};
        captured($SEGMENT{$url}, \&events, $next);
      }
    }
  );
  push(@FUTURE, $future);
}

sub events
{
  my $url    = shift;
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $url  = $response->request->url;
      my $html = $response->content;
      my $data = $1 if $html =~ m{data-page="(.*?)">};
      return if !$data;
      $data =~ s{&quot;}{"}g;
      $data =~ s{&#039;}{'}g;
      my $d = decode_json($data);
      my $t = $d->{props}->{tournament};

      for my $g (@{ $d->{props}->{games} })
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
          sec   => 1,
        )->ical;
        warn "$start ($ENV{TZ}) $summary\n";
        my $duration = $g->{duration} || duration($summary);
        my ($hour, $min) = split(/\D/, $duration);
        $duration = 'PT' . int($hour) . 'H' . int($min) . 'M';
        my $standings = $url;
        $standings =~ s,schedule-and-results,standings,;
        my $boxscore = boxscore($url, $g);
        my %DESC;
        $DESC{'Standings'} = $standings;
        $DESC{'Box Score'} = $boxscore;
        $DESC{'Schedule'}  = $url;
        $DESC{'Watch'}     = $g->{gamevideo} if $g->{gamevideo};

        my $desc = '<ul>';
        for my $text (sort keys %DESC)
        {
          $desc .= sprintf('<li><a href="%s">%s</a></li>', $DESC{$text}, $text);
        }
        $desc .= '</ul>';

        my $vevent = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description     => $desc,
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

sub last_modified_description
{
  my $html;
  for my $url (keys %SEGMENT)
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
  return if !$SEGMENT{$url};
  $SEGMENT{$url}->{end_time} = time;
  $SEGMENT{$url}->{http}     = {
    request => {
      method => $response->request->method,
      url    => $url,
    },
    response => {
      status         => $response->code,
      content_length => length($response->content),
    },
  };
  my $elapsed =
    int(($SEGMENT{$url}->{end_time} - $SEGMENT{$url}->{start_time}) * 1000);
  warn "GET $url ($elapsed ms)\n";
}

sub captured
{
  my $header = shift;
  my $func   = shift;
  my @args   = @_;
  my $url    = $args[0];
  return if $SEGMENT{$url};
  my $code = sub {
    my $segment = shift;
    $SEGMENT{$url} = $segment;
    $func->(@args);
  };
  my $name = $url;
  $name =~ s{\?}{#}g;
  if ($header)
  {
    capture_from $header, $name => $code;
  }
  else
  {
    capture $name => $code;
  }
}
