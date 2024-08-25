# $Id$
opendir(D, '.') || die $!;
my @QUERY;
while (readdir(D))
{
  my $file = $_;
  next if $file !~ m{\.pl$};
  (my $query = $file) =~ s{\.pl$}{};
  push(@QUERY, $query);
}
closedir(D);
print join("\n", sort @QUERY) . "\n";
