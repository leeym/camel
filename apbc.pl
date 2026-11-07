#!/opt/bin/perl
# $Id$
use lib 'local/lib/perl5';
use AWS::XRay;
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use Encode qw(decode);
use IO::Socket::SSL;
use Net::Async::HTTP;
use Net::SSLeay;
use POSIX       qw(mktime tzset);
use Time::HiRes qw(time sleep);
use strict;
use utf8;

$Data::Dumper::Terse    = 1;    # don't output names where feasible
$Data::Dumper::Indent   = 0;    # turn off all pretty print
$Data::Dumper::Sortkeys = 1;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

AWS::XRay->auto_flush(0);

my $start   = time();
my $dtstamp = Date::ICal->new(epoch => $start)->ical;
my $loop    = new IO::Async::Loop;
my $ics = Data::ICal->new(calname => 'Asia Professional Baseball Championship');
my %SEGMENT;
my %VEVENT;
my @FUTURE;

my $url = 'https://www.japan-baseball.jp/jp/games/apbc2026/';
captured($ENV{_X_AMZN_TRACE_ID}, $url, sub { schedule($url) });

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

# The schedule section of the page lists every game as a card under the
# heading of its day, all times in Japan time:
# <h4 class="subHeading">11月12日(木)</h4>
# <div class="card"><div class="date">19:00<br>決勝戦</div>
#   <div class="home"><span>TPE</span>...</div><div class="num">-</div>
#   <div class="visitor">...<span>JPN</span></div>
# Home/away follow the class names; the score in "num" is in page order
# (home team first), e.g. a home TPE 3, visitor JPN 5 shows as 3-5.
sub schedule
{
  my $url    = shift;
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $html    = decode('UTF-8', $response->content);
      my $year    = $1 if $url =~ m{apbc(\d{4})};
      my $section = $1
        if $html =~ m{<section[^>]*id="schedule"[^>]*>(.*?)</section>}s;
      return if !$year || !$section;
      $ENV{TZ} = 'Asia/Tokyo';
      tzset();
      my ($month, $day);

      for my $chunk (
        split(m{(?=<h4[^>]*subHeading|<div class="card">)}, $section))
      {
        if ($chunk =~ m{^<h4[^>]*>(.*?)</h4>}s)
        {
          ($month, $day) = trimmed($1) =~ m{(\d+)月(\d+)日};
          next;
        }
        next if $chunk !~ m{^<div class="card">};
        my $date = $1 if $chunk =~ m{<div class="date">(.*?)</div>}s;
        my ($hour, $min) = $date =~ m{(\d{1,2}):(\d{2})};
        my $label = $date =~ m{<br\s*/?>(.*)}s ? trimmed($1) : '';
        my $home  = team($chunk, 'home');
        my $away  = team($chunk, 'visitor');
        my $num   = $1 if $chunk =~ m{<div class="num">(.*?)</div>}s;

        if (!$month || !defined($hour) || $home eq '' || $away eq '')
        {
          warn "Unparseable card: " . trimmed($chunk) . "\n";
          next;
        }
        next if !grep { m{^(TPE|TBD)$} } $home, $away;
        $home = name($home);
        $away = name($away);
        my $epoch = mktime(1, $min, $hour, $day, $month - 1, $year - 1900);
        my $score = 'vs';
        $score = "$2:$1" if trimmed($num) =~ m{(\d+)\D+(\d+)};
        $score = 'vs'    if $epoch > time;
        my $game = game($label);
        my $summary =
          sprintf("%s %s %s | Asia Professional Baseball Championship %s - %s",
          $away, $score, $home, $year, $game);
        my $when =
          sprintf('%04d-%02d-%02d %02d:%02d', $year, $month, $day, $hour, $min);
        warn "$when ($ENV{TZ}) $summary\n";
        my $uid = sprintf('apbc-%04d%02d%02d-%02d%02d',
          $year, $month, $day, $hour, $min);
        my $link = $url . '#schedule';
        my %LI;
        $LI{Schedule} = $link;
        my $vevent = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description => unordered(%LI),
          dtstart     => Date::ICal->new(epoch => $epoch)->ical,
          duration    => 'PT3H0M',
          dtstamp     => $dtstamp,
          location    => 'Tokyo Dome, 1-3-61 Koraku, Bunkyo-ku, Tokyo, Japan',
          summary     => $summary,
          uid         => $uid,
          url         => $link,
        );
        $VEVENT{$uid} = $vevent;
      }
    }
  );
  push(@FUTURE, $future);
}

sub team
{
  my $chunk = shift;
  my $class = shift;
  my $text  = $1 if $chunk =~ m{<div class="$class">(.*?)</div>}s;
  return trimmed($text);
}

sub name
{
  my $code = shift;
  my %NAME = (
    TPE => 'Taiwan',
    JPN => 'Japan',
    KOR => 'Korea',
    AUS => 'Australia',
    TBD => 'TBD',
  );
  return $NAME{$code} || $code;
}

sub game
{
  my $label = shift;
  return 'Opening Round'    if $label eq '';
  return 'Third Place Game' if $label eq '3位決定戦';
  return 'Final'            if $label eq '決勝戦';
  return $label;
}

sub trimmed
{
  my $text = shift;
  return '' if !defined($text);
  $text =~ s{<[^>]*>}{ }g;
  $text =~ s{&nbsp;}{ }g;
  $text =~ s{&amp;}{&}g;
  $text =~ s{\s+}{ }g;
  $text =~ s{^ | $}{}g;
  return $text;
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
          id      => AWS::XRay::new_id(),
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
