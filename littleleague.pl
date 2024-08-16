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

my @YEAR = (2006 .. (localtime)[5] + 1901);
my $ics  = new Data::ICal;
my $http = Net::Async::HTTP->new(
  max_connections_per_host => 0,
  max_in_flight            => 0,
  timeout                  => 20,
);
my %VEVENT;
my $start = time();
my %START;

my %MM;
$MM{January}   = '01';
$MM{Febrery}   = '02';
$MM{March}     = '03';
$MM{April}     = '04';
$MM{May}       = '05';
$MM{June}      = '06';
$MM{July}      = '07';
$MM{August}    = '08';
$MM{September} = '09';
$MM{October}   = '10';
$MM{November}  = '11';
$MM{December}  = '12';

IO::Async::Loop->new()->add($http);

event()->get();

END
{
  foreach my $vevent (sort by_dtstart values %VEVENT)
  {
    $ics->add_entry($vevent);
  }
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
  my $url  = build_url(
    base_uri => 'https://www.littleleague.org',
    path     => '/world-series/2024/llbws/tournaments/world-series/',
  );

  return if $START{$url};
  $START{$url} = time;
  warn "get $url\n";
  return $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $elapsed  = int((time - $START{$url}) * 1000);
      my $html     = $response->content;
      $html =~ s{\r}{}g;
      $html =~ s{\n}{}g;
      $html =~ s{>\s+<}{><}g;
      $html =~ s{.*#schedule}{}g;
      my $n;
      my @DATE = split(/site-panel--game-schedule__heading/, $html);
      shift @DATE;

      for my $d (@DATE)
      {
        my $date = $1      if $d    =~ m{(\w+ \d{1,2}, \d{4})};
        my $mm   = $MM{$1} if $date =~ m{^(\w+) };
        my $dd   = $1      if $date =~ m{(\d{1,2}),};
        my $yyyy = $1      if $date =~ m{(\d{4})};
        my @GAME = split(/g-col/, $d);
        shift @GAME;
        for my $g (@GAME)
        {
          next if $g !~ m{Asia-Pacific};
          my ($header, $content, $footer) = ($1, $2, $3)
            if $g =~ m{(<header.*/header>)(.*)(<footer.*/footer>)};
          my $header = $1 if $g =~ m{<header.*?>(.*)</header>};

          my $title = $1 if $header =~ m{<h3 class="ws-card__title">(.*?)</h3>};
          my $game  = $1 if $header =~ m{>(Game.*?)<};
          my $info  = $1 if $header =~ m{.*>(.*?Stadium)<};
          my @INFO     = split(/@/, $info);
          my $datetime = $INFO[0];
          my $location = $INFO[1];

          my $hh = $1 if $datetime =~ m{^(\d)};
          $hh += 12   if $datetime =~ m{\d+ PM};

          my $ical = $yyyy . $mm . $dd . 'T' . $hh . '0000';
          warn $ical;
          my $summary;
          my $away;
          my $home;
          my $result;
          my @LI = split(/<\/li>/, $content);
          for my $li (@LI)
          {
            next           if $away && $home;
            my $team = $1  if $li =~ m{<h4.*>(.*?) Region</h4>};
            die $li        if !$team;
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

          my $watch = $1
            if $footer =~ m{"(https://www.espn.com/watch/[^"]*)"};
          my $lineups = $1
            if $footer =~
            m{"(https://www.littleleague.org/downloads/[^"]*?-lineups/)"};
          my $boxscore = $1
            if $footer =~
            m{"(https://www.littleleague.org/downloads/[^"]*?-box-score/)"};

          my $description = "* $watch\n* $lineups\n* $boxscore\n";
          my $vevent      = Data::ICal::Entry::Event->new();
          my $epoch       = time;
          $vevent->add_properties(
            description => $description,
            dtstart  => Date::ICal->new(ical => $ical, offset => '-0400')->ical,
            duration => 'PT3H0M',
            'last-modified' => Date::ICal->new(epoch => time)->ical,
            location        => $location . ', South Williamsport, PA 17702',
            summary         => $summary,
            id              => $game,
            url             => $boxscore,
          );
          $VEVENT{$game} = $vevent;
          $n++;
        }
      }
      warn "got $url ($n events, $elapsed ms)\n";
    }
  );
}
