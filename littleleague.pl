#!/opt/bin/perl
use lib 'local/lib/perl5';
use AWS::XRay qw(capture);
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

my $yyyy = (localtime)[5] + 1900;

my @YEAR = ($yyyy - 10 .. $yyyy);
my $ics  = new Data::ICal;
my $http = Net::Async::HTTP->new(
  max_connections_per_host => 0,
  max_in_flight            => 0,
  timeout                  => 20,
);
my @FUTURE;
my %VEVENT;
my $start = time();
my $now   = Date::ICal->new(epoch => $start)->ical;
my %START;

my %MON;
$MON{January}   = '01';
$MON{Febrery}   = '02';
$MON{March}     = '03';
$MON{April}     = '04';
$MON{May}       = '05';
$MON{June}      = '06';
$MON{July}      = '07';
$MON{August}    = '08';
$MON{September} = '09';
$MON{October}   = '10';
$MON{November}  = '11';
$MON{December}  = '12';

my %LOCATION;
$LOCATION{llbws} =
  'Little League International Complex, South Williamsport, PA';
$LOCATION{jlbws} =
  'Junior League World Series Field, Heritage Park, Taylor, MI';

IO::Async::Loop->new()->add($http);

foreach my $year (reverse sort @YEAR)
{
  my @TYPE = qw(llbws jlbws);
  for my $type (@TYPE)
  {
    captured_year($type, $year);
  }
}

for my $future (@FUTURE)
{
  await $future->get();
}

foreach my $vevent (sort by_dtstart values %VEVENT)
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
  my $year = shift;
  my $type = shift;
  my $url  = build_url(
    base_uri => 'https://www.littleleague.org',
    path     => "/world-series/$year/$type/teams/asia-pacific-region/",
  );

  return if $START{$url};
  $START{$url} = time;
  my $future = $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      return if !$START{$url};
      my $elapsed = int((time - $START{$url}) * 1000);
      warn "GET $url ($elapsed ms)\n";
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
        foreach my $text (sort keys %DESC)
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
  foreach my $url (keys %START)
  {
    $html .= "<li>$url</li>";
  }
  return "<ul>$html</ul>";
}

sub captured_year
{
  my $type = shift;
  my $year = shift;
  capture "$type-$year" => sub {
    event($year, $type);
  }
}
