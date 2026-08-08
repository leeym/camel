# $Id$
use lib 'local/lib/perl5';
use Data::Dumper;
use Data::Dump qw(dump);
use Data::Printer use_prototypes => 0;
use Switch;

my $mode = shift;

# https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html#configuration-envvars-runtime
foreach my $key (
  qw(AWS_ACCESS_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN))
{
  delete($ENV{$key});
}

switch ($mode)
{
  case 'dump'
  {
    print dump(\%ENV);
  }
  case 'printer'
  {
    p(\%ENV);
  }
  else
  {
    print Dumper(\%ENV);
  }
}
