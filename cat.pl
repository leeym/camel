# $Id$
my $file = shift;
open(F, $file) || die $!;
while(<F>)
{
  print "$_\n";
}
close(F);
