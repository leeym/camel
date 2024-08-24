use lib 'local/lib/perl5';
use Data::Dumper;
use Data::Dump qw(dump);
use Data::Printer use_prototypes => 0;
use Switch;

my $mode = shift;
foreach my $key (keys %ENV)
{
  #delete($ENV{$key}) if $key =~ m{^AWS_};
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
