#!/opt/bin/perl
use lib 'local/lib/perl5';
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use HTTP::Tiny;
use POSIX qw(strftime);
use Time::HiRes qw(time);
use Time::ParseDate qw(parsedate);
use strict;

my $ics  = new Data::ICal;
my $http = new HTTP::Tiny;
my $base = 'http://www.baseballasia.org/BFA/include';
my %URL;

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

sub tz
{
  my $host = shift;
  return 'Asia/Taipei'    if $host =~ m{Taichung}i;
  return 'Asia/Taipei'    if $host =~ m{Taipei}i;
  return 'Asia/Manila'    if $host =~ m{Philippines}i;
  return 'Asia/Bangkok'   if $host =~ m{Thailand}i;
  return 'Asia/Seoul'     if $host =~ m{Korea}i;
  return 'Asia/Tokyo'     if $host =~ m{Japan}i;
  return 'Asia/Shanghai'  if $host =~ m{China}i;
  return 'Asia/Shanghai'  if $host =~ m{2019 X BFA U15 Baseball Championship}i;
  return 'Asia/Taipei'    if $host =~ m{2019 XXIX Asian Baseball Championship}i;
  return 'Asia/Shanghai'  if $host =~ m{2019 II BFA Women's Baseball Asia Cup}i;
  return 'Asia/Hong_Kong' if $host =~ m{Hong Kong}i;
  return 'Asia/Jakarta'   if $host =~ m{Jakarta}i;
  die "Cannot determine TZ based on $host";
}

sub validate
{
  my ($t, $g, $home, $h, $away, $a) = @_;
  return if $h == $a;
  my $winner = ($h > $a) ? $home : $away;
  my $loser  = ($h < $a) ? $home : $away;
  return ($a, $h) if $t eq '2019 X BFA U15 Baseball Championship' && $g == 13;
  die "$t $g" if $loser eq 'Taiwan' && $winner !~ m{(Japan|Korea)};
  return ($h, $a);
}

my @EVENT;
my $events = "$base/index.php?Page=1-2";
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
  next if $html !~ m{Chinese Taipei};
  my $host       = $1 if $html =~ m{<div.*?resault-page(.*?)</div>};
  my $tournament = $1 if $host =~ m{<b>(.*?)(\s*\(.*?\))?</b>};
  $ENV{TZ} = tz($host);

  foreach my $tr ($html =~ m{(<tr>.*?</tr>)}g)
  {
    $tr =~ s{<!--.*?-->}{};
    my @TD = ($tr =~ m{<td>\s*(.*?)\s*</td>}g);
    next if !scalar(@TD);
    my $game = shift @TD;
    my $time = shift @TD;
    $time =~ s{ , ([A-Z][a-z][a-z])([a-z]*)}{, $1};
    $time =~ s{ [ap]m$}{};
    my $start = parsedate($time) || die "Cannot parse $time\n";
    my $home = shift @TD;
    $home =~ s{Chinese Taipei}{Taiwan};
    my $away = shift @TD;
    $away =~ s{Chinese Taipei}{Taiwan};
    my $park = shift @TD;
    my ($h, $a) = split(/\D+/, (shift @TD));
    my $score = ($h > 0 || $a > 0) ? "$a : $h" : 'vs';
    ($h, $a) = validate($tournament, $game, $home, $h, $away, $a);
    my $boxscore = shift @TD;
    my $url      = $event;
    my $duration = 'PT3H0M';
    my $summary  = "#$game $away $score $home - $tournament";
    next if $summary !~ m{Taiwan};
    warn strftime('%F %T %z', localtime($start)) . ": $summary\n";
    my $vevent = Data::ICal::Entry::Event->new();
    $vevent->add_properties(
      description     => "$url\n" . strftime('%F %T %z', gmtime),
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

print $ics->as_string;
