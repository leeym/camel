#!/opt/bin/perl
use lib 'local/lib/perl5';
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

#my @YEAR = ($yyyy - 10 .. $yyyy);
my @YEAR = ($yyyy);
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
  #my @TYPE = qw(llbws jlbws);
  my @TYPE = qw(jlbws);
  for my $type (@TYPE)
  {
    event($year, $type);
  }
}

for my $future (@FUTURE)
{
  await $future->get();
}

END
{
  foreach my $vevent (sort by_dtstart values %VEVENT)
  {
    $ics->add_entry($vevent);
  }
  my $vevent = Data::ICal::Entry::Event->new();
  $vevent->add_properties(
    dtstart => Date::ICal->new(epoch => $start)->ical,
    dtend   => Date::ICal->new(epoch => time)->ical,
    summary => 'Last Modified',
  );
  $ics->add_entry($vevent);
  print $ics->as_string;
  warn "\n";
  warn "Total: " . scalar(keys %VEVENT) . " events\n";
  warn "Duration: " . int((time - $start) * 1000) . " ms\n";
  exit(0);
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
  warn "get $url\n";
  my $future = $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $elapsed  = int((time - $START{$url}) * 1000);
      my $html     = $response->content;
      $html         =~ s{\r}{}g;
      $html         =~ s{\n}{}g;
      $html         =~ s{\s+}{ }g;
      $html         =~ s{>\s+<}{><}g;
      next if $html !~ m{Chinese Taipei};
      my @GAME = split(/\bws-card\b/, $html);
      shift @GAME;
      my $n;

      for my $g (@GAME)
      {
        my ($header, $content, $footer) = ($1, $2, $3)
          if $g =~ m{(<header.*?/header>)(.*?)(<footer.*?/footer>).*};
        next if !$header || !$content || !$footer;
        next if $header !~ m{Game};

        my $title = $1 if $header =~ m{<h3 class="ws-card__title">(.*?)</h3>};
        my $game  = $1 if $header =~ m{>(Game.*?)<};
        my $info  = $1 if $header =~ m{.*>(.*?M.*?)<};
        my @INFO     = split(/@/, $info);
        my $datetime = $INFO[0];

        my $HH = sprintf("%02d", $1) if $datetime =~ m{(\d+)};
        my $MM = sprintf("%02d", $2) if $datetime =~ m{(\d+):(\d{2})};
        $HH += 12 if $datetime =~ m{PM} && $HH != 12;
        my $mm = $MON{$1}            if $datetime =~ m{ ([A-Z][a-z]*) \d+};
        my $dd = sprintf("%02d", $1) if $datetime =~ m{ [A-Z][a-z]* (\d{1,2})};

        my $ical = $year . $mm . $dd . 'T' . $HH . $MM . '00';
        my $summary;
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
        $summary .= "$away $result $home | $title $game";

        my $links       = $1 if $footer =~ m{(<ul.*?/ul>)};
        my $description = $links;
        my $vevent      = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description => $description,
          dtstart  => Date::ICal->new(ical => $ical, offset => '-0400')->ical,
          duration => 'PT3H0M',
          'last-modified' => $now,
          location        => $LOCATION{$type},
          summary         => $summary,
        );
        $VEVENT{$game} = $vevent;
        $n++;
      }
      warn "got $url ($n events, $elapsed ms)\n";
    }
  );
  push(@FUTURE, $future);
}
