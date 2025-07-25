#!/opt/bin/perl
# $Id$
use lib 'local/lib/perl5';
use AWS::XRay;
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use IO::Async::SSL;
use IO::Socket::SSL;
use JSON::XS qw(decode_json encode_json);
use Net::Async::HTTP;
use Net::SSLeay;
use POSIX       qw(mktime);
use Time::HiRes qw(time);
use strict;

$Data::Dumper::Terse    = 1;    # don't output names where feasible
$Data::Dumper::Sortkeys = 1;

AWS::XRay->auto_flush(0);

my $start   = time;
my $dtstamp = Date::ICal->new(epoch => $start)->ical;
my $loop    = new IO::Async::Loop;
my $ics = Data::ICal->new(calname => 'World Baseball Softball Confederation');
my %SEGMENT;
my %VEVENT;
my @FUTURE;
my @YEAR = (2012 .. yyyy() + 1);

for my $yyyy (sort by_year @YEAR)
{
  for my $domain ('wbsc', 'wbscasia')
  {
    my $url = "https://www.$domain.org/en/calendar/$yyyy/baseball";
    captured($ENV{_X_AMZN_TRACE_ID}, $url, sub { calendar($url) });
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
$ics->add_entry(last_modified_event());
print $ics->as_string;

END
{
  AWS::XRay->sock->flush();
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

sub _tz
{
  my $tz = shift;
  return $tz          if $tz =~ m{^\w+/\w+$};
  return 'Asia/Tokyo' if $tz eq 'Japan';
  warn "Unknown timezone: $tz";
  return $tz;
}

sub tz
{
  my $g = shift;
  my $t = shift;
  return _tz($g->{start_tz}) if $g->{start_tz};
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
  WARN('G:' . Dumper($g));
  WARN('T:' . Dumper($t));
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
  return '2:00' if $summary =~ m{U-12};
  return '2:30' if $summary =~ m{U-15};
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
        captured($SEGMENT{$url}->trace_header, $next, sub { events($next) });
      }
    }
  );
  push(@FUTURE, $future);
}

sub stadium
{
  my $str = shift;
  $str =~ s,ASPAC,Asia-Pacific International Baseball Training Centers -,;
  return $str;
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

      my %LOGS;
      for my $g (@{ $d->{props}->{games} })
      {
        next if $VEVENT{ $g->{id} };
        next if $g->{homeioc} ne 'TPE' && $g->{awayioc} ne 'TPE';
        $ENV{TZ} = tz($g, $t);
        my $score = "$g->{awayruns}:$g->{homeruns}";
        my $away  = "$g->{awaylabel}";
        my $home  = "$g->{homelabel}";
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
          min   => $min,
          sec   => 1,
        );
        $score = 'vs' if $dtstart->epoch > time;
        my $summary = "$away $score $home";
        $summary .= " | $t->{tournamentname}";
        $summary .= " - $g->{gametypelabel}";
        $summary =~ s{Chinese Taipei}{Taiwan};

        my $duration = $g->{duration} || duration($summary);
        my ($HH, $MM) = split(/\D/, $duration);
        $duration = 'PT' . int($HH) . 'H' . int($MM) . 'M';
        my $standings = $url;
        $standings =~ s,schedule-and-results,standings,;
        my $boxscore = boxscore($url, $g);
        my %LI;
        $LI{'Standings'} = $standings;
        $LI{'Box Score'} = $boxscore;
        $LI{'Schedule'}  = $url;
        $LI{'Watch'}     = $g->{gamevideo} if $g->{gamevideo};
        my $desc   = unordered(%LI);
        my $vevent = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description => $desc,
          dtstart     => $dtstart->ical,
          duration    => $duration,
          dtstamp     => $dtstamp,
          location    => stadium($g->{stadium}) . ', ' . $g->{location},
          summary     => $summary,
          uid         => $g->{id},
          url         => $boxscore,
        );
        $VEVENT{ $g->{id} } = $vevent;
        $LOGS{ $g->{id} }   = "$start ($ENV{TZ}) $summary";
      }
      WARN(\%LOGS) . "\n" if %LOGS;
    }
  );
  push(@FUTURE, $future);
}

sub http
{
  my $http = Net::Async::HTTP->new(
    max_connections_per_host => 0,
    max_in_flight            => 0,
    timeout                  => $start + 28 - time,
    user_agent => 'Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)',
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
      status         => int($response->code),
      content_length => length($response->content),
    },
  };
  $segment->close();
  my $elapsed = int(($segment->{end_time} - $segment->{start_time}) * 1000);
  warn "GET $url ($elapsed ms)\n";
}

sub captured
{
  my $header = shift;
  my $url    = shift;
  my $func   = shift;
  return if $SEGMENT{$url};
  my $code = sub {
    my $segment = shift;
    $SEGMENT{$url} = $segment;
    $func->();
  };
  my $name = $url;
  $name =~ s{\?}{#}g;
  if ($header)
  {
    capture_from($header, $name, $code);
  }
  else
  {
    capture($name, $code);
  }
}

sub last_modified_description
{
  my %LI;
  my $region = $ENV{AWS_REGION} || $ENV{AWS_DEFAULT_REGION} || 'us-west-2';
  my $url;
  $url .= "https://$region.console.aws.amazon.com/cloudwatch/home?";
  $url .= "region=$region";
  if ($ENV{_X_AMZN_TRACE_ID})
  {
    my $t = $1 if $ENV{_X_AMZN_TRACE_ID} =~ m{Root=([0-9a-fA-F-]+)};
    $LI{Trace} = $url . "#xray:traces/$t";
  }
  if ($ENV{AWS_LAMBDA_LOG_STREAM_NAME} && $ENV{AWS_LAMBDA_LOG_GROUP_NAME})
  {
    $LI{'Logs'} =
        $url
      . '#logsV2:log-groups/log-group/'
      . escaped($ENV{AWS_LAMBDA_LOG_GROUP_NAME})
      . '/log-events/'
      . escaped($ENV{AWS_LAMBDA_LOG_STREAM_NAME});
  }
  if (!scalar(%LI))
  {
    for my $url (keys %SEGMENT)
    {
      $LI{$url} = $url;
    }
  }
  return unordered(%LI);
}

sub escaped
{
  my $src = shift;
  my $dst = $src;
  $dst =~ s{\[}{%5B}g;
  $dst =~ s{\]}{%5D}g;
  $dst =~ s{/}{%2F}g;
  $dst =~ s{\$}{%24}g;
  $dst =~ s{%}{\$25}g;
  return $dst;
}

sub unordered
{
  my %LI = @_;
  my $html;
  for my $text (sort keys %LI)
  {
    $html .= '<li><a href="' . $LI{$text} . '">' . $text . '</a></li>';
  }
  return '<ul>' . $html . '</ul>';
}

# Cloned from AWS::XRay::capture_from
sub capture_from
{
  my ($header, $name, $code) = @_;
  my ($trace_id, $segment_id, $sampled) =
    AWS::XRay::parse_trace_header($header);

  $AWS::XRay::SAMPLED = $sampled // $AWS::XRay::SAMPLER->();
  $AWS::XRay::ENABLED = $AWS::XRay::SAMPLED;
  ($AWS::XRay::TRACE_ID, $AWS::XRay::SEGMENT_ID) = ($trace_id, $segment_id);
  capture($name, $code);
}

# Cloned from AWS::XRay::capture without closing the segment
sub capture
{
  my ($name, $code) = @_;
  if (!AWS::XRay::is_valid_name($name))
  {
    my $msg = "invalid segment name: $name";
    $AWS::XRay::CROAK_INVALID_NAME ? croak($msg) : carp($msg);
  }
  my $wantarray = wantarray;

  my $enabled;
  my $sampled = $AWS::XRay::SAMPLED;
  if (defined $AWS::XRay::SAMPLED)
  {
    $enabled = $AWS::XRay::ENABLED ? 1 : 0;    # fix true or false (not undef)
  }
  elsif ($AWS::XRay::TRACE_ID)
  {
    $enabled = 0;                              # called from parent capture
  }
  else
  {
    # root capture try sampling
    $sampled = $AWS::XRay::SAMPLER->() ? 1 : 0;
    $enabled = $sampled                ? 1 : 0;
  }
  $AWS::XRay::ENABLED = $enabled;
  $AWS::XRay::SAMPLED = $sampled;

  return $code->(AWS::XRay::Segment->new) if !$enabled;

  $AWS::XRay::TRACE_ID = $AWS::XRay::TRACE_ID // AWS::XRay::new_trace_id();

  my $segment = AWS::XRay::Segment->new({ name => $name });
  unless (defined $segment->{type} && $segment->{type} eq "subsegment")
  {
    $_->apply_plugin($segment) for @AWS::XRay::PLUGINS;
  }

  $AWS::XRay::SEGMENT_ID = $segment->{id};

  my @ret;
  eval {
    if ($wantarray)
    {
      @ret = $code->($segment);
    }
    elsif (defined $wantarray)
    {
      $ret[0] = $code->($segment);
    }
    else
    {
      $code->($segment);
    }
  };
  my $error = $@;
  if ($error)
  {
    $segment->{error} = Types::Serialiser::true;
    $segment->{cause} = {
      exceptions => [
        {
          id      => new_id(),
          message => "$error",
          remote  => Types::Serialiser::true,
        },
      ],
    };
  }
  die $error if $error;
  return $wantarray ? @ret : $ret[0];
}

sub last_modified_event
{
  my $vevent = Data::ICal::Entry::Event->new();
  $vevent->add_properties(
    dtstart     => Date::ICal->new(epoch => $start)->ical,
    dtend       => Date::ICal->new(epoch => time)->ical,
    summary     => 'Last Modified',
    uid         => 'Last Modified',
    description => last_modified_description(),
    dtstamp     => $dtstamp,
  );
  return $vevent;
}

sub WARN
{
  my $msg = shift;
  if ($ENV{_X_AMZN_TRACE_ID})
  {
    warn encode_json($msg) . "\n";
  }
  else
  {
    warn Dumper($msg);
  }
}
