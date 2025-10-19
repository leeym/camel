#!/opt/bin/perl
use lib 'local/lib/perl5';
use AWS::XRay;
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

$Data::Dumper::Terse    = 1;    # don't output names where feasible
$Data::Dumper::Indent   = 0;    # turn off all pretty print
$Data::Dumper::Sortkeys = 1;

AWS::XRay->auto_flush(0);

my $start   = time();
my $dtstamp = Date::ICal->new(epoch   => $start)->ical;
my $ics     = Data::ICal->new(calname => 'FIFA World Cup 2026');
my $loop    = IO::Async::Loop->new();
my %SEGMENT;
my %VEVENT;
my @FUTURE;

my $url = build_url(
  base_uri => 'https://www.roadtrips.com/',
  path     => '/world-cup/2026-world-cup-packages/schedule/',
);

captured($ENV{_X_AMZN_TRACE_ID}, $url, sub { roadtrip($url) });

my %month = (
  Jan => '01',
  Feb => '02',
  Mar => '03',
  Apr => '04',
  May => '05',
  Jun => '06',
  Jul => '07',
  Aug => '08',
  Sep => '09',
  Oct => '10',
  Nov => '11',
  Dec => '12'
);

sub roadtrip
{
  my $url    = shift;
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html = $response->content;
      for my $line (split(/\n/, $html))
      {
        my $table = $1 if $line =~ m{(<table.*</table>)};
        next           if !$table;
        while ($table =~ m{(<tr.*?></tr>)})
        {
          my $tr = $1;
          $table = $';
          next if $tr !~ m{<td};

          $tr =~ s{ class="column-\d+"}{}g;
          $tr =~ s{<a [^>]*>}{}g;
          $tr =~ s{</a>}{}g;

          #$tr =~ s{&amp;}{&}g;

          my @TD   = ($tr =~ m{<td>([^<]*)</td>}g);
          my $date = $TD[0];
          next if !$date;
          my $epoch = str2time($date);
          my ($dd, $mon) = ($1, $2) if $date =~ m{(\d+)-(\w+)};
          my $mm    = $month{$mon};
          my $match = $TD[1];
          my $venue = $TD[2];
          my $city  = $TD[3];
          my $teams = $TD[4];

          my $summary     = "M$match $teams";
          my $description = "M$match $venue, $city";

          my $vevent = Data::ICal::Entry::Event->new();
          $vevent->add_properties(
            uid      => $match,
            location => "$venue, $city",
            dtstart  => Date::ICal->new(
              year   => 2026,
              month  => $mm,
              day    => $dd,
              hour   => 12,
              min    => 30,
              offset => $offset{$city}
            )->ical,
            duration    => 'P3H',
            summary     => $summary,
            description => $description,
            dtstamp     => $dtstamp,
          );
          $VEVENT{$match} = $vevent;
        }
      }
    }
  );
  push(@FUTURE, $future);
}

for my $future (@FUTURE)
{
  my $future = shift @FUTURE;
  await $future->get();
}

for my $vevent (sort by_dtstart values %VEVENT)
{
  $ics->add_entry($vevent);
}
my $vevent = Data::ICal::Entry::Event->new();
$vevent->add_properties(
  dtstart     => Date::ICal->new(epoch => $start)->ical,
  dtend       => Date::ICal->new(epoch => time)->ical,
  summary     => 'Last Modified',
  uid         => 'Last Modified',
  description => last_modified_description(),
  dtstamp     => $dtstamp,
);
$ics->add_entry($vevent);
print $ics->as_string;

END
{
  AWS::XRay->sock->flush();
  die $@ if $@;
  warn "Total: " . scalar(keys %VEVENT) . " events\n";
  warn "Duration: " . int((time - $start) * 1000) . " ms\n";
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
      status         => int($response->code),
      content_length => length($response->content),
    },
  };
  $segment->close();
  my $elapsed = int(($segment->{end_time} - $segment->{start_time}) * 1000);
  warn "GET $url ($elapsed ms)\n";
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

my %offset = (
  'Seattle'                => '-0700',
  'Los Angeles'            => '-0700',
  'San Francisco Bay Area' => '-0700',
  'Dallas'                 => '-0500',
  'Houston'                => '-0500',
  'Kansas City'            => '-0500',
  'Atlanta'                => '-0400',
  'Boston'                 => '-0400',
  'New York/New Jersey'    => '-0400',
  'Philadelphia'           => '-0400',
  'Miami'                  => '-0400',
  'Vancouver'              => '-0700',
  'Toronto'                => '-0400',
  'Monterrey'              => '-0600',
  'Guadalajara'            => '-0600',
  'Mexico City'            => '-0600',
);
