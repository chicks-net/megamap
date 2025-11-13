#!/usr/bin/env perl

# the shell version of this is fine
# but I didn't want this to be a just
# repo so I added a couple of Perl
# scripts... maybe I should find
# better things to do.

use strict;
use warnings;

print "```\n";

print "### megacli:\n";
system("megacli -pdlist -a0 | egrep 'Slot|^SAS'");

print "\n";
print "### /dev/disk/by-id:\n";
system("ls -l /dev/disk/by-id");

print "\n";
print "### uname:\n";
system("uname -a");

print "\n";
print "### lsb_release:\n";
system("lsb_release -a");

print "```\n";
