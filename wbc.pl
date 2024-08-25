#!/opt/bin/perl
use lib 'local/lib/perl5';
use AWS::XRay qw(capture capture_from);
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

my $start = time();
my $now   = Date::ICal->new(epoch => $start)->ical;
my $loop  = new IO::Async::Loop;
my $ics   = new Data::ICal;
my @YEAR  = (2006, 2009, 2012, 2013, 2017, 2023, 2026);
my %SEGMENT;
my %VEVENT;
my @FUTURE;

for my $year (reverse sort @YEAR)
{
  my $url = build_url(
    base_uri => 'https://bdfed.stitch.mlbinfra.com',
    path     => '/bdfed/transform-mlb-schedule',
    query    => [
      sportId   => 51,
      startDate => "$year-01-01",
      endDate   => "$year-12-31",
    ],
  );
  captured($ENV{_X_AMZN_TRACE_ID}, \&event, $url);
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

sub venue
{
  my $v = shift;
  my $l = $v->{location};
  return sprintf('%s, %s, %s, %s, %s',
    $v->{name}, $l->{address1}, $l->{address2}, $l->{city}, $l->{country});
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
  my $future = http()->GET($url)->on_done(
    sub {
      my $response = shift;
      segment($response);
      my $json = $response->content;
      my $data = decode_json($json);

      for my $date (@{ $data->{dates} })
      {
        next if $date->{totalGames} == 0;
        for my $g (@{ $date->{games} })
        {
          next if $VEVENT{ $g->{gamePk} };
          my $tpe  = 'Chinese Taipei';
          my $twn  = 'Taiwan';
          my $away = $g->{teams}->{away}->{team}->{teamName};
          my $home = $g->{teams}->{home}->{team}->{teamName};
          next if $away ne $tpe && $home ne $tpe;
          $away = $twn if $away eq $tpe;
          $home = $twn if $home eq $tpe;

          # warn Dumper($g);
          my $score = sprintf('%d:%d',
            $g->{teams}->{away}->{score},
            $g->{teams}->{home}->{score});
          $score = 'vs' if $score eq '0:0';
          my $summary = sprintf("%s %s %s | World Baseball Classic %s - %s",
            $away, $score, $home, $g->{season}, $g->{description});
          my $epoch = str2time($g->{gameDate});

          warn $g->{gameDate} . " $summary\n";
          my $gameday = 'https://www.mlb.com/gameday/' . $g->{gamePk};
          my %LI;
          $LI{Gameday} = $gameday;
          my $desc   = unordered(%LI);
          my $vevent = Data::ICal::Entry::Event->new();
          $vevent->add_properties(
            description     => $desc,
            dtstart         => Date::ICal->new(epoch => $epoch + 1)->ical,
            duration        => 'PT3H0M',
            'last-modified' => $now,
            location        => venue($g->{venue}),
            summary         => $summary,
            uid             => $g->{gamePk},
            url             => $gameday,
          );
          $VEVENT{ $g->{gamePk} } = $vevent;
        }
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
    response => {
      status         => $response->code,
      content_length => length($response->content),
    },
  };
  my $elapsed = int(($segment->{end_time} - $segment->{start_time}) * 1000);
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
    $segment->{http} = {
      request => {
        method => 'GET',
        url    => $url,
      },
    };
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

sub last_modified_description
{
  my %LI;
  my $region = region();
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

sub region
{
  return $ENV{AWS_REGION} || $ENV{AWS_DEFAULT_REGION} || 'us-west-2';
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
