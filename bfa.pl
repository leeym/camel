#!/opt/bin/perl
use lib 'local/lib/perl5';
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use HTTP::Tiny;
use IO::Socket::SSL;
use JSON::Tiny qw(encode_json decode_json);
use Net::SSLeay;
use POSIX qw(mktime strftime);
use Time::HiRes qw(time);
use Time::ParseDate;
use strict;

my $team = shift || 'TPE';
my $ics  = new Data::ICal;
my $http = new HTTP::Tiny;
my $base = 'http://www.baseballasia.org';
my $YEAR = (localtime)[5] + 1900;
my %URL;

END
{
  print $ics->as_string;
}

sub get
{
  my $url = shift;
  return if $URL{$url};
  $URL{$url}++;
  my $start   = time;
  my $res     = $http->get($url);
  my $elapsed = int((time - $start) * 1000);
  die "$res->{status}: $res->{reason}" if !$res->{success};
  warn "GET $url ($elapsed ms)\n";
  return $res->{content};
}

my @EVENT;
my $events = "$base/BFA/include/index.php?Page=1-2";
foreach my $score01 (get($events) =~ m{score01=(\w+)}g)
{
  # unshift(@EVENT, "$events-1&score01=$score01");
  push(@EVENT, "$events-1&score01=$score01");
}

while (scalar(@EVENT))
{
  my $event = pop(@EVENT);
  my $html  = get($event);
  $html =~ s{\r}{}g;
  $html =~ s{\n}{}g;
  foreach my $tr ($html =~ m{(<tr>.*?</tr>)}g)
  {
    $tr =~ s{<!--.*?-->}{};
    my @TD    = ($tr =~ m{<td>\s*(.*?)\s*</td>}g);
    my $game  = shift @TD;
    my $time  = shift @TD;
    my $start = parsedate($time);
    my $home  = shift @TD;
    my $away  = shift @TD;
    my $park  = shift @TD;
    my $score = shift @TD;
    $score = 'vs' if !$score;
    my $boxscore = shift @TD;
    my $url      = $boxscore || $event;
    my $duration = 'PT3H0M';
    my $summary  = "$home $score $away";
    $summary =~ s{Chinese Taipei}{Taiwan};
    next if $summary !~ m{Taiwan};
    my $vevent = Data::ICal::Entry::Event->new();
    $vevent->add_properties(
      description     => "$url\n" . strftime('%FT%T%z', gmtime),
      dtstart         => Date::ICal->new(epoch => $start)->ical,
      duration        => $duration,
      'last-modified' => Date::ICal->new(epoch => time)->ical,
      location        => $park,
      summary         => $summary,
      url             => $url,
    );
    $ics->add_entry($vevent);
  }
}
