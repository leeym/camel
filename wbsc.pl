#!/opt/bin/perl
use lib 'local/lib/perl5';
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use HTTP::Tiny;
use IO::Socket::SSL;
use Net::SSLeay;
use POSIX;
use JSON::Tiny qw(encode_json decode_json);
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
    my @SCRIPT = ($html =~ m{(<script.*?</script>)}g);

    foreach my $script (@SCRIPT)
    {
      next if $script !~ m{schedule:};
      next if $script !~ m{tournament:};
      my ($s, $t) = (decode_json($1), decode_json($2))
        if $script =~ m{schedule:\s*({.*?}),\s+tournament:\s*({.*})\s*\};};
      foreach my $date (keys $s->{games})
      {
        foreach my $g (@{ $s->{games}->{$date} })
        {
          next if $g->{homeioc} ne 'TPE' && $g->{awayioc} ne 'TPE';
          $ENV{TZ} = $g->{start_tz};
          my $score = "$g->{awayruns}:$g->{homeruns}";
          $score = 'vs' if $score eq '0:0';
          my $away    = "$g->{awaylabel}";
          my $home    = "$g->{homelabel}";
          my $summary = "#$g->{gamenumber} $away $score $home";
          $summary .= " - $t->{tournamentname}";
          $summary .= " - $g->{gametypelabel}";
          $summary =~ s{Chinese Taipei}{Taiwan};
          my $boxscore = $event . '/box-score/' . $g->{id};
          $boxscore =~ s{/en/}{/zh/};
          my ($yyyy, $mm, $dd, $HH, $MM) = split(/\D/, $g->{start});
          my $start    = mktime(0, $MM, $HH, $dd, $mm - 1, $yyyy - 1900);
          my $duration = $g->{duration} || '3:00';
          my ($hour, $min) = split(/\D/, $duration);
          $duration = 'PT' . $hour . 'H' . $min . 'M';
          my $event = Data::ICal::Entry::Event->new();
          $event->add_properties(
            location    => $g->{stadium} . ', ' . $g->{location},
            summary     => $summary,
            dtstart     => Date::ICal->new(epoch => $start)->ical,
            duration    => $duration,
            description => $boxscore,
          );
          $ics->add_entry($event);
        }
      }
    }
  }
}

END
{
  print $ics->as_string;
}
