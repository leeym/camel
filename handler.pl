use Data::Dumper;

sub handle
{
  my $payload = shift;
  my $context = shift;
  my %JSON;
  $JSON{statusCode}              = 200;
  $JSON{isBase64Encoded}         = \0;
  $JSON{headers}{'Content-Type'} = 'text/plain';

  eval {
    # parse payload and return query hash
    my %Q;
    eval { %Q = parse($payload); };
    if ($@)
    {
      $JSON{statusCode} = 400;    # HTTP_BAD_REQUEST
      $JSON{body}       = $@;
      return \%JSON;
    }

    # construct command based on query hash
    my $cmd;
    eval { $cmd = discover(%Q); };
    if ($@)
    {
      $JSON{statusCode} = 404;    # HTTP_NOT_FOUND
      $JSON{body}       = $@;
      return \%JSON;
    }

    # execute command and return result
    warn "COMMAND: $cmd\n";
    my ($stdout, $stderr, $exit) = capture { system($cmd); };
    if ($exit)
    {
      $JSON{statusCode} = 500;       # HTTP_INTERNAL_SERVER_ERROR
      $JSON{body}       = $stderr;
    }
    else
    {
      $JSON{statusCode} = 200;       # HTTP_OK
      $JSON{body}       = $stdout;
      warn $stderr if $stderr;
    }
  };
  if ($@)
  {
    $JSON{statusCode} = 501;    # HTTP_NOT_IMPLEMENTED
    $JSON{body}       = $@;
  }
  return \%JSON;
}

sub parse
{
  my $payload = shift;
  warn 'PAYLOAD: ' . Dumper($payload);
  my %P;
  if ($payload->{httpMethod} eq 'GET')
  {
    if ($payload->{multiValueQueryStringParameters})
    {
      %P = %{ $payload->{multiValueQueryStringParameters} };
    }
  }
  elsif ($payload->{httpMethod} eq 'POST')
  {
    foreach my $pair (split('&', $payload->{'body'}))
    {
      my ($k, $v) = split('=', $pair);
      push(@{ $P{$k} }, $v);
    }
  }
  else
  {
    die 'Unsupported method: ' . $payload->{httpMethod};
  }

  my %Q;
  foreach my $k (keys %P)
  {
    next if $k ne 'q' && $k !~ m{^p\d+$};
    my @V = @{ $P{$k} };
    die "Multiple '$k': ['" . join("', '", @V) . "']\n" if scalar(@V) > 1;
    $Q{$k} = shift @V;
  }
  return %Q;
}

sub discover
{
  my %Q = @_;
  my @ARG;
  push(@ARG, '/opt/bin/perl');
  if (!$Q{q})
  {
    push(@ARG, 'help.pl');
  }
  else
  {
    my $script;
    if (-f $Q{q})
    {
      $script = $Q{q};
    }
    elsif (-f $Q{q} . '.pl')
    {
      $script = $Q{q} . '.pl';
    }
    else
    {
      die "$Q{q} not found\n";
    }
    push(@ARG, $script);
    for (my $i = 0; exists($Q{"p$i"}); $i++)
    {
      push(@ARG, $Q{"p$i"});
    }
  }
  return "@ARG";
}

1;
