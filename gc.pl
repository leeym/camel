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
    base_uri => 'https://api.team-manager.gc.com',
    path     => '/public/organizations/5NiE1G9pMY4y/events',
  );

  return if $START{$url};
  $START{$url} = time;
  warn "get $url\n";
  return $http->GET($url)->on_done(
    sub {
      my $response = shift;
      my $url      = $response->request->url;
      my $elapsed  = int((time - $START{$url}) * 1000);
      my $json     = $response->content;
      my $data     = decode_json($json);
      my $n        = 0;
      foreach my $g (@{$data})
      {
        next if $VEVENT{ $g->{id} };
        my $tpe = 'Asia-Pacific';
        my $twn = 'Taiwan';
        (my $away = $g->{away_team}->{name}) =~ s{ - LLBWS}{};
        (my $home = $g->{home_team}->{name}) =~ s{ - LLBWS}{};
        next if $away ne $tpe && $home ne $tpe;
        $away = $twn if $away eq $tpe;
        $home = $twn if $home eq $tpe;

        # warn Dumper($g);
        my $score =
          sprintf('%d:%d', $g->{away_team}->{score}, $g->{home_team}->{score});
        $score = 'vs' if $score eq '0:0';
        my $summary =
          sprintf("%s %s %s | Little League Baseball", $away, $score, $home);
        my $epoch = str2time($g->{start_ts});

        # warn $g->{start_ts} . " $summary\n";
        my $gameday =
          'https://web.gc.com/organizations/5NiE1G9pMY4y/schedule/' . $g->{id};
        my $description = "* $gameday \n";
        $description .= "* " . Date::ICal->new(epoch => time)->ical . "\n";
        my $vevent = Data::ICal::Entry::Event->new();
        $vevent->add_properties(
          description     => $description,
          dtstart         => Date::ICal->new(epoch => $epoch)->ical,
          duration        => 'PT3H0M',
          'last-modified' => Date::ICal->new(epoch => time)->ical,
          location => $g->{location}->{name} . ', South Williamsport, PA 17702',
          summary  => $summary,
          uid      => $g->{id},
          url      => $gameday,
        );
        $VEVENT{ $g->{id} } = $vevent;
        $n++;
      }
      warn "got $url ($n events, $elapsed ms)\n";
    }
  );
}
