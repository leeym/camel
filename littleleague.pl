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

my $start = time();
my $now   = Date::ICal->new(epoch => $start)->ical;
my $loop  = new IO::Async::Loop;
my $ics   = new Data::ICal;
my %SEGMENT;
my %VEVENT;
my @FUTURE;
my @YEAR = (2017 .. (localtime)[5] + 1900);

my %MON = (
  January   => '01',
  Febrery   => '02',
  March     => '03',
  April     => '04',
  May       => '05',
  June      => '06',
  July      => '07',
  August    => '08',
  September => '09',
  October   => '10',
  November  => '11',
  December  => '12',
);

my %LOCATION = (
  llbws => 'Little League International Complex, South Williamsport, PA',
  jlbws => 'Junior League World Series Field, Heritage Park, Taylor, MI',
);

for my $year (reverse sort @YEAR)
{
  my @TYPE = qw(llbws jlbws);
  for my $type (@TYPE)
  {
    my $url = build_url(
      base_uri => 'https://www.littleleague.org',
      path     => "/world-series/$year/$type/teams/asia-pacific-region/",
    );
    captured($ENV{_X_AMZN_TRACE_ID}, $url, sub { event($url, $type, $year) });
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

sub duration
{
  my $title = shift;
  return 'PT1H30M' if $title =~ m{LLB};
  return 'PT2H0M'  if $title =~ m{JLB};
  return 'PT3H0M';
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

sub event
{
  my $url    = shift;
  my $type   = shift;
  my $year   = shift;
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $url  = $response->request->url;
      my $html = $response->content;
      $html         =~ s{\r}{}g;
      $html         =~ s{\n}{}g;
      $html         =~ s{\s+}{ }g;
      $html         =~ s{>\s+<}{><}g;
      next if $html !~ m{Chinese Taipei};
      $html         =~ s{Asia-Pacific}{Taiwan}g;
      my @GAME = split(/\bws-card\b/, $html);
      shift @GAME;

      for my $g (@GAME)
      {
        my ($header, $content, $footer) = ($1, $2, $3)
          if $g =~ m{(<header.*?/header>)(.*?)(<footer.*?/footer>).*};
        next if !$header || !$content || !$footer;
        next if $header !~ m{Game};

        my $title = "$1 $year"
          if $header =~ m{<h3 class="ws-card__title">(.*?)</h3>};
        my $game     = $1 if $header =~ m{(Game\s+\d+)};
        my $info     = $1 if $header =~ m{.*>(.*?M.*?)<};
        my @INFO     = split(/@/, $info);
        my $datetime = $INFO[0];

        my $hour;
        my $min;
        if ($datetime =~ m{(\d+):(\d+)\s*(AM|PM)})
        {
          $hour = sprintf("%02d", $1);
          $min  = sprintf("%02d", $2);
          $hour += 12 if $3 eq 'PM' && $hour != 12;
        }
        elsif ($datetime =~ m{(\d+)\s*(AM|PM)})
        {
          $hour = sprintf("%02d", $1);
          $min  = '00';
          $hour += 12 if $2 eq 'PM' && $hour != 12;
        }
        die $datetime if !$hour;
        my $month;
        my $day;
        if ($datetime =~ m{ ([A-Z][a-z]*) (\d{1,2})})
        {
          $month = $MON{$1};
          $day   = sprintf("%02d", $2);
        }
        die $datetime if !$day;

        my $away;
        my $home;
        my $result;
        my @LI = split(/<\/li>/, $content);

        for my $li (@LI)
        {
          last if $away && $home;
          my $team  = $1 if $li =~ m{<h4.*>(.*?) Region</h4>};
          my $score = $1 if $li =~ m{score">(\d+)</div>};
          if (!$away)
          {
            $away   = $team;
            $result = $score;
          }
          else
          {
            $home = $team;
            $result .= ":$score";
          }
        }
        $result = 'vs' if $result eq ':';
        my $summary = "$away $result $home | $title - $game";

        warn "$year-$month-$day $hour:$min (America/New_York) $summary\n";
        my $links = $1 if $footer =~ m{(<ul.*?/ul>)};
        my %LI;
        $LI{Schedule} = $url;
        while ($links =~ m{<a [^>]*?href="([^"]+)"[^>]*>\s*([^<]+?)\s*<})
        {
          $LI{$2} = $1;
          $links = $';
        }
        my $desc    = unordered(%LI);
        my $dtstart = Date::ICal->new(
          year   => $year,
          month  => $month,
          day    => $day,
          hour   => $hour,
          min    => $min,
          sec    => 1,
          offset => '-0400'
        )->ical;
        my $vevent = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description     => $desc,
          dtstart         => $dtstart,
          duration        => duration($title),
          'last-modified' => $now,
          location        => $LOCATION{$type},
          summary         => $summary,
          uid             => "$title - $game",
        );
        $VEVENT{$summary} = $vevent;
      }
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
    $LI{'Log groups'} =
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
    dtstart         => Date::ICal->new(epoch => $start)->ical,
    dtend           => Date::ICal->new(epoch => time)->ical,
    summary         => 'Last Modified',
    uid             => 'Last Modified',
    description     => last_modified_description(),
    'last-modified' => $now,
  );
  return $vevent;
}
