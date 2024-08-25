# $Id$
use POSIX;
printf strftime('%F %T %z', gmtime) . "\n";
