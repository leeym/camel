#!/opt/bin/perl
use lib 'local/lib/perl5';
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use HTTP::Tiny;
use IO::Socket::SSL;
use Net::SSLeay;
use POSIX;
use strict;

my $team = shift || 'TPE';
my $ics  = new Data::ICal;
my $http = new HTTP::Tiny;
my $base = 'http://www.wbsc.org';
my $YEAR = (localtime)[5] + 1900;
my %URL;

sub get
{
  my $url = shift;
  return if $URL{$url};
  warn "GET $url\n";
  $URL{$url}++;
  my $res = $http->get($url);
  die "$res->{status}: $res->{reason}" if !$res->{success};
  return $res->{content};
}

foreach my $year ($YEAR - 1 .. $YEAR + 1)
{
  foreach my $event (
    get("$base/events/filter/$year/all") =~ m{href="(.*?)" target="_blank"}g)
  {
    next if $event !~ m{wbsc.org};
    next if $event =~ m{edition};
    next if $event =~ m{congress};
    next if $event =~ m{baseball5};
    $event .= "/en/$year" if $event !~ m{$year};
    $event .= '/schedule-and-results';
    my $html = get($event);
    next if !$html;
    $html =~ s/&#039;/'/g;
    $html =~ s/\r//g;
    $html =~ s/\n//g;
    my $title = $1 if $html =~ m{<title>(.*?) - .+</title>};
    $ENV{TZ} = $1 if $html =~ m{timezone="(.*?)"};
    my @rows = split('game-row', $html);
    shift @rows;

    foreach my $row (@rows)
    {
      my $game = $1 if $row =~ m{>\s*#?(\d+)\s*<};
      my $ppp  = $1 if ($row =~ m{<div class="col-md-3">(.*?)</div>});
      die $row if !$ppp;
      my ($p1, $p2, $p3) = ($ppp =~ m{<p>(.*?)</p>}g);
      die $ppp if !$p1;
      my ($dd, $mm, $yyyy, $HH, $MM) = ($1, $2, $3, $4, $5)
        if $p1 =~ m{(\d{2})/(\d{2})/(\d{4}) (\d{2}):(\d{2})};
      my $time     = mktime(0, $MM, $HH, $dd, $mm - 1, $yyyy - 1900);
      my $round    = $p2;
      my $location = $p3;
      my ($away, $home) = ($row =~ m{>([A-Z]{3})<}g);
      my @score =
        ($row =~ m{<span class="(?:away|home)\d+">\s*(\d+)\s*</span>}g);
      my $score = join(':', @score);
      $score = 'vs' if $score eq '0:0';
      my $url = $1 if $row =~ m{"(http://.*?)"};
      $url =~ s{/en/}{/zh/};
      next if $away ne $team && $home ne $team;
      my $event = Data::ICal::Entry::Event->new();
      $event->add_properties(
        location    => $location,
        summary     => "#$game $away $score $home - $title - $round",
        dtstart     => Date::ICal->new(epoch => $time)->ical,
        dtend       => Date::ICal->new(epoch => $time + 60 * 60 * 3)->ical,
        description => $url
      );
      $ics->add_entry($event);
    }
  }
}

print $ics->as_string;
