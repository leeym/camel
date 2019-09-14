use lib 'local/lib/perl5';
use Data::Dumper;
foreach my $key (qw(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN))
{
  delete($ENV{$key});
}
print Dumper(\%ENV);
