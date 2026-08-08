#!/opt/bin/perl
# $Id$
use lib 'local/lib/perl5';
use AWS::XRay;
use Data::Dumper;
use Data::ICal::Entry::Event;
use Data::ICal;
use Date::ICal;
use IO::Socket::SSL;
use JSON::XS qw(decode_json);
use Net::Async::HTTP;
use Net::SSLeay;
use POSIX       qw(mktime tzset);
use Time::HiRes qw(time sleep);
use URI;
use strict;

$Data::Dumper::Terse    = 1;    # don't output names where feasible
$Data::Dumper::Indent   = 0;    # turn off all pretty print
$Data::Dumper::Sortkeys = 1;

AWS::XRay->auto_flush(0);

my $start   = time();
my $dtstamp = Date::ICal->new(epoch => $start)->ical;
my $loop    = new IO::Async::Loop;
my $ics     = Data::ICal->new(calname => 'Babe Ruth');
my %SEGMENT;
my %VEVENT;
my @FUTURE;

my $url = 'https://baberuthworldseries.org/';
captured($ENV{_X_AMZN_TRACE_ID}, $url, sub { baberuth($url) });

for my $future (@FUTURE)
{
    await $future->get();
}

for my $vevent (sort by_dtstart values %VEVENT)
{
    $ics->add_entry($vevent);
}
$ics->add_entry(last_modified_event());
print $ics->as_string;

END
{
    AWS::XRay->sock->flush();
    die $@ if $@;
    warn "Total: " . scalar(keys %VEVENT) . " events\n";
    warn "Duration: " . int((time - $start) * 1000) . " ms\n";
}

# https://baberuthworldseries.org/#/events is a single page application, the
# events are rendered from an API whose address is embedded in the bundle.
sub baberuth
{
    my $url     = shift;
    my $segment = $SEGMENT{$url};
    my $future  = get($url)->on_done(
        sub {
            my $response = shift;
            segment($response);
            my $html = $response->content;
            my $next = absolute($1, $url)
              if $html =~ m{<script [^>]*type="module"[^>]*src="([^"]+)"};
            return if !$next;
            captured($segment->trace_header, $next, sub { bundle($next) });
        }
    );
    push(@FUTURE, $future);
}

sub bundle
{
    my $url     = shift;
    my $segment = $SEGMENT{$url};
    my $future  = get($url)->on_done(
        sub {
            my $response = shift;
            segment($response);
            my $js   = $response->content;
            my $next = $1
              if $js =~
              m{(https://api\.baberuthleague\.org/\S*?worldseries/\d{4})};
            return if !$next;
            captured($segment->trace_header, $next, sub { events($next) });
        }
    );
    push(@FUTURE, $future);
}

# Every event carries its roster, only the ones hosting Chinese Taipei are
# interesting, and only those already having a schedule can be scraped.
sub events
{
    my $url     = shift;
    my $segment = $SEGMENT{$url};
    my $future  = get($url)->on_done(
        sub {
            my $response = shift;
            segment($response);
            my $data = decode_json($response->content);
            for my $e (@{$data})
            {
                my $title = trimmed($e->{title});
                next if !taiwan(map { $_->{name} } @{ $e->{teams} });
                my $next = $e->{tourneyMachineUrl};
                if (!$next)
                {
                    warn "No schedule yet: $title\n";
                    next;
                }

              # Some events link straight to their division, others to the whole
              # tournament, which in turn links to one division per age group.
                if ($next =~ m{/Tournament\.aspx}i)
                {
                    captured($segment->trace_header, $next,
                        sub { tournament($next, $e) });
                }
                else
                {
                    captured($segment->trace_header, $next,
                        sub { division($next, $e) });
                }
            }
        }
    );
    push(@FUTURE, $future);
}

# A TourneyMachine tournament page carries no schedule of its own, it links to
# every division of the tournament as
# <a class='well tournamentDivision' href='Division.aspx?...'>
sub tournament
{
    my $url     = shift;
    my $e       = shift;
    my $segment = $SEGMENT{$url};
    my $future  = get($url)->on_done(
        sub {
            my $response = shift;
            segment($response);
            my $html = $response->content;
            while ($html =~
                m{<a[^>]+href=["']([^"']*Division\.aspx\?[^"']+)["']}gi)
            {
                my $next = absolute(trimmed($1), $url);
                captured($segment->trace_header, $next,
                    sub { division($next, $e) });
            }
        }
    );
    push(@FUTURE, $future);
}

# A TourneyMachine division page lists every game of the division as
# <tr class='schedule_row date_YYYYMMDD ...' data-gameid='...'> with the
# columns Game, Time, Location, Away, Score, Score and Home.
sub division
{
    my $url    = shift;
    my $e      = shift;
    my $title  = trimmed($e->{title});
    my $where  = $e->{location}->{name};
    my $gc     = gamechanger($e);
    my $future = get($url)->on_done(
        sub {
            my $response = shift;
            segment($response);
            my $html = $response->content;
            $ENV{TZ} = timezone($where);
            tzset();
            my $game_row = qr{<tr\s+class='(schedule_row[^']*)'
                              \s+data-gameid='([^']+)'(.*?)</tr>}sx;
            while ($html =~ m{$game_row})
            {
                my $class = $1;
                my $id    = $2;
                my $row   = $3;
                $html = $';
                next if $VEVENT{$id};

                my @TEAM = teams($row);
                next if scalar(@TEAM) != 2;
                my $away     = $TEAM[0]->{name};
                my $home     = $TEAM[1]->{name};
                my ($taiwan) = grep { taiwan($_->{name}) } @TEAM;
                next if !$taiwan;

                my ($year, $month, $day) =
                  $class =~ m{date_(\d{4})(\d{2})(\d{2})};
                my ($hour, $min, $ampm) =
                  $row =~ m{(\d{1,2}):(\d{2})\s*([AP])M};
                next if !$year || !defined($hour);
                $hour %= 12;
                $hour += 12 if $ampm eq 'P';
                my $epoch =
                  mktime(1, $min, $hour, $day, $month - 1, $year - 1900);

                my $game    = tag($row, qr{<td[^>]*>});
                my ($runs1) = $row =~ m{id='\Q$id\E_1'[^>]*>(.*?)</td>}s;
                my ($runs2) = $row =~ m{id='\Q$id\E_2'[^>]*>(.*?)</td>}s;
                my $score   = trimmed($runs1) . ':' . trimmed($runs2);
                $score = 'vs' if $score !~ m{\d} || $epoch > time;
                my $summary = "$away $score $home | $title - $game";

                warn "$year-$month-$day $hour:$min ($ENV{TZ}) $summary\n";
                my $venue = tag($row, qr{<td [^>]*data-facilityid='[^']*'>});
                my %LI;

                # Pool Standings, Schedule and Bracket of the division
                $LI{SportsEngine} = $url;
                (my $team = $url) =~ s{/Division\.aspx}{/Team.aspx};
                $LI{ $taiwan->{name} } = $team . '&IDTeam=' . $taiwan->{id};

                # Boxscore and Gameday of every game of the event
                $LI{GameChanger} = $gc if $gc;
                my $vevent = Data::ICal::Entry::Event->new();
                $vevent->add_properties(
                    description => unordered(%LI),
                    dtstart     => Date::ICal->new(epoch => $epoch)->ical,
                    duration    => duration($title),
                    dtstamp     => $dtstamp,
                    location    => join(', ', grep { $_ } $venue, $where),
                    summary     => $summary,
                    uid         => $id,
                );
                $VEVENT{$id} = $vevent;
            }
        }
    );
    push(@FUTURE, $future);
}

# Away team first, home team second, both carrying their TourneyMachine id
sub teams
{
    my $row = shift;
    my @TEAM;
    while ($row =~ m{<td[^>]*data-teamid='([^']+)'[^>]*>(.*?)<br}s)
    {
        my $id   = $1;
        my $name = trimmed($2);
        $row = $';
        $name =~ s{^\[\d+\]\s*}{};            # seed of a bracket game
        $name =~ s{Chinese Taipei}{Taiwan};
        push(@TEAM, { id => $id, name => $name });
    }
    return @TEAM;
}

# TourneyMachine carries the schedule of an event, GameChanger the Boxscore and
# the Gameday of every game of it, either as a field of its own or as one of
# the broadcasts of the event.
sub gamechanger
{
    my $e = shift;
    return $e->{gameChangerUrl} if $e->{gameChangerUrl};
    for my $b (@{ $e->{broadcasts} })
    {
        my $url = $b->{streamURL};
        return $url if $url && $url =~ m{\bgc\.com/};
    }
    return;
}

sub taiwan
{
    return scalar(grep { m{Chinese Taipei|Taiwan} } @_);
}

# The content of the first cell matching the given opening tag
sub tag
{
    my $row  = shift;
    my $tag  = shift;
    my $text = $1 if $row =~ m{$tag(.*?)</td>}s;
    return trimmed($text);
}

sub trimmed
{
    my $text = shift;
    return '' if !defined($text);
    $text =~ s{<[^>]*>}{ }g;
    $text =~ s{&quot;}{"}g;
    $text =~ s{&#0?39;}{'}g;
    $text =~ s{&nbsp;}{ }g;
    $text =~ s{&amp;}{&}g;
    $text =~ s{\s+}{ }g;
    $text =~ s{^ | $}{}g;
    return $text;
}

# All the World Series are hosted in the United States
sub timezone
{
    my $location = shift;
    my $state    = $1 if $location =~ m{,\s*([A-Z]{2})$};
    my %TZ;
    $TZ{$_} = 'America/New_York'
      for qw(CT DC DE FL GA MA MD ME MI NC NH NJ NY OH PA RI SC VA VT WV);
    $TZ{$_} = 'America/Chicago'
      for qw(AL AR IA IL KS LA MN MO MS ND NE OK SD TN TX WI);
    $TZ{$_} = 'America/Denver'      for qw(CO ID MT NM UT WY);
    $TZ{$_} = 'America/Los_Angeles' for qw(CA NV OR WA);
    $TZ{AK} = 'America/Anchorage';
    $TZ{AZ} = 'America/Phoenix';
    $TZ{HI} = 'Pacific/Honolulu';
    $TZ{IN} = 'America/Indiana/Indianapolis';
    $TZ{KY} = 'America/Kentucky/Louisville';
    $TZ{PR} = 'America/Puerto_Rico';
    return $TZ{$state} if $state && $TZ{$state};
    warn "Unknown timezone: $location\n";
    return 'America/Chicago';    # Babe Ruth World Series headquarters
}

sub duration
{
    my $title = shift;
    return 'PT2H30M' if $title =~ m{16-18|18U};
    return 'PT2H0M';
}

# Resolve a possibly relative href against the page it was found on
sub absolute
{
    my $href = shift;
    my $base = shift;
    return URI->new_abs($href, $base)->as_string;
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

# TourneyMachine sits behind Cloudflare, which answers 403 to any request
# without an Accept header
sub get
{
    my $url = shift;
    return http()->GET($url, headers => { Accept => '*/*' });
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
            status         => int($response->code),
            content_length => length($response->content),
        },
    };
    $segment->close();
    my $elapsed = int(($segment->{end_time} - $segment->{start_time}) * 1000);
    warn "GET $url ($elapsed ms)\n";
}

sub captured
{
    my $header = shift;
    my $url    = shift;
    my $func   = shift;
    return if $SEGMENT{$url};
    my $code = sub {
        my $segment = shift;
        $SEGMENT{$url} = $segment;
        $func->();
    };
    my $name = $url;
    $name =~ s{\?}{#}g;
    if ($header)
    {
        capture_from($header, $name, $code);
    }
    else
    {
        capture($name, $code);
    }
}

sub last_modified_description
{
    my %LI;
    my $region = $ENV{AWS_REGION} || $ENV{AWS_DEFAULT_REGION} || 'us-west-2';
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
        $LI{'Logs'} =
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

# Cloned from AWS::XRay::capture_from
sub capture_from
{
    my ($header, $name, $code) = @_;
    my ($trace_id, $segment_id, $sampled) =
      AWS::XRay::parse_trace_header($header);

    $AWS::XRay::SAMPLED = $sampled // $AWS::XRay::SAMPLER->();
    $AWS::XRay::ENABLED = $AWS::XRay::SAMPLED;
    ($AWS::XRay::TRACE_ID, $AWS::XRay::SEGMENT_ID) = ($trace_id, $segment_id);
    capture($name, $code);
}

# Cloned from AWS::XRay::capture without closing the segment
sub capture
{
    my ($name, $code) = @_;
    if (!AWS::XRay::is_valid_name($name))
    {
        my $msg = "invalid segment name: $name";
        $AWS::XRay::CROAK_INVALID_NAME ? croak($msg) : carp($msg);
    }
    my $wantarray = wantarray;

    my $enabled;
    my $sampled = $AWS::XRay::SAMPLED;
    if (defined $AWS::XRay::SAMPLED)
    {
        $enabled = $AWS::XRay::ENABLED ? 1 : 0;  # fix true or false (not undef)
    }
    elsif ($AWS::XRay::TRACE_ID)
    {
        $enabled = 0;                            # called from parent capture
    }
    else
    {
        # root capture try sampling
        $sampled = $AWS::XRay::SAMPLER->() ? 1 : 0;
        $enabled = $sampled                ? 1 : 0;
    }
    $AWS::XRay::ENABLED = $enabled;
    $AWS::XRay::SAMPLED = $sampled;

    return $code->(AWS::XRay::Segment->new) if !$enabled;

    $AWS::XRay::TRACE_ID = $AWS::XRay::TRACE_ID // AWS::XRay::new_trace_id();

    my $segment = AWS::XRay::Segment->new({ name => $name });
    unless (defined $segment->{type} && $segment->{type} eq "subsegment")
    {
        $_->apply_plugin($segment) for @AWS::XRay::PLUGINS;
    }

    $AWS::XRay::SEGMENT_ID = $segment->{id};

    my @ret;
    eval {
        if ($wantarray)
        {
            @ret = $code->($segment);
        }
        elsif (defined $wantarray)
        {
            $ret[0] = $code->($segment);
        }
        else
        {
            $code->($segment);
        }
    };
    my $error = $@;
    if ($error)
    {
        $segment->{error} = Types::Serialiser::true;
        $segment->{cause} = {
            exceptions => [
                {
                    id      => AWS::XRay::new_id(),
                    message => "$error",
                    remote  => Types::Serialiser::true,
                },
            ],
        };
    }
    die $error if $error;
    return $wantarray ? @ret : $ret[0];
}

sub last_modified_event
{
    my $vevent = Data::ICal::Entry::Event->new();
    $vevent->add_properties(
        dtstart     => Date::ICal->new(epoch => $start)->ical,
        dtend       => Date::ICal->new(epoch => time)->ical,
        summary     => 'Last Modified',
        uid         => 'Last Modified',
        description => last_modified_description(),
        dtstamp     => $dtstamp,
    );
    return $vevent;
}
