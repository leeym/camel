#!/opt/bin/perl
# $Id$
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
my $dtstamp = Date::ICal->new(epoch => $start)->ical;
my $loop    = new IO::Async::Loop;
my $ics     = Data::ICal->new(calname => 'PONY');
my %SEGMENT;
my %VEVENT;
my @FUTURE;

my $url = 'https://www.pony.org/';
captured($ENV{_X_AMZN_TRACE_ID}, $url, sub { pony($url) });

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

sub pony
{
  my $url     = shift;
  my $segment = $SEGMENT{$url};
  my $future  = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html = $response->content;
      my $next = "https://www.pony.org/$1"
        if $html =~ m{<a [^>]*href="([^"]+)">Baseball World Series</a>};
      return if !$next;
      captured($segment->trace_header, $next, sub { schedules($next) });
    }
  );
  push(@FUTURE, $future);
}

sub schedules
{
  my $url     = shift;
  my $segment = $SEGMENT{$url};
  my $future  = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html = $response->content;
      while ($html =~ m{<a href="([^"]+)"[^>]*>\s*([^>]+?)\s*</a>})
      {
        my $href = $1;
        my $text = $2;
        $html = $';
        next if $text !~ m{World Series};
        next if $text !~ m{1(2|4|8)U};
        captured($segment->trace_header, $href, sub { event($href, $text) });
      }
    }
  );
  push(@FUTURE, $future);
}

sub event
{
  my $url     = shift;
  my $title   = shift;
  my $segment = $SEGMENT{$url};
  my $future  = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html     = $response->content;
      my $base_uri = $1 if $url =~ m{^(https://.*?/)};
      my $next     = build_url(
        base_uri => $base_uri,
        path     => $1,
      ) if $html =~ m{<a [^>]*href="([^"]+)">GameChanger[^<]*</a>};
      return if !$next;
      captured($segment->trace_header, $next, sub { teams($next, $title) });
    }
  );
  push(@FUTURE, $future);
}

sub teams
{
  my $url     = shift;
  my $title   = shift;
  my $segment = $SEGMENT{$url};
  my $future  = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html = $response->content;
      my ($href, $name) = ($1, $2)
        if $html =~ m{<a [^>]*href="([^"]+)">([^<]*Chinese Taipei)</a>};
      my $id = $1 if $href =~ m{/teams/([^/]+)/};
      $name =~ s{Chinese Taipei}{Taiwan};
      return if !$id;
      my $next = "https://api.team-manager.gc.com/public/teams/$id/games";
      captured($segment->trace_header, api($id),
        sub { team($id, $name, $title) });
    }
  );
  push(@FUTURE, $future);
}

sub api
{
  my $id = shift;
  return "https://api.team-manager.gc.com/public/teams/$id/games";
}

sub team
{
  my $id     = shift;
  my $name   = shift;
  my $title  = shift;
  my $url    = api($id);
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $json = $response->content;
      my $data = decode_json($json);
      for my $g (@{$data})
      {
        next if $VEVENT{ $g->{id} };

        #warn Dumper($g);
        my $home;
        my $away;
        my $score;
        if ($g->{home_away} eq 'home')
        {
          $home  = $name;
          $away  = $g->{opponent_team}->{name};
          $score = $g->{score}->{opponent_team} . ':' . $g->{score}->{team};
        }
        else
        {
          $home  = $g->{opponent_team}->{name};
          $away  = $name;
          $score = $g->{score}->{team} . ':' . $g->{score}->{opponent_team};
        }
        my $summary  = "$away $score $home | $title";
        my $start_ts = str2time($g->{start_ts});
        my $end_ts   = str2time($g->{end_ts});
        $score = 'vs' if $start_ts > time;

        warn $g->{start_ts} . " $summary\n";
        my %LI;
        $LI{Home}     = "https://web.gc.com/teams/$id";
        $LI{Schedule} = "https://web.gc.com/teams/$id/schedule";
        my $description = unordered(%LI);
        my $vevent      = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description => $description,
          dtstart     => Date::ICal->new(epoch => $start_ts + 1)->ical,
          dtend       => Date::ICal->new(epoch => $end_ts)->ical,
          dtstamp     => $dtstamp,
          summary     => $summary,
          uid         => $g->{id},
        );
        $VEVENT{ $g->{id} } = $vevent;
      }
    }
  );
  push(@FUTURE, $future);
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
