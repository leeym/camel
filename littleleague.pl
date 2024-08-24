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
    captured($ENV{_X_AMZN_TRACE_ID}, \&event, $url, $type, $year);
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
        my %DESC;
        $DESC{Schedule} = $url;
        while ($links =~ m{<a [^>]*?href="([^"]+)"[^>]*>\s*([^<]+?)\s*<})
        {
          my $href = $1;
          my $text = $2;
          $DESC{$2} = $1;
          $links = $';
        }
        my $desc = '<ul>';
        for my $text (sort keys %DESC)
        {
          $desc .= sprintf('<li><a href="%s">%s</a></li>', $DESC{$text}, $text);
        }
        $desc .= '</ul>';
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
  my $segment  = $SEGMENT{$url};
  return if !$segment;
  $segment->{end_time} = time;
  $segment->{http}     = {
    request => {
      method => $response->request->method,
      url    => $url,
    },
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
