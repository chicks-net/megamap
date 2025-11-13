#!/usr/bin/env perl

# the shell version of this is fine
# but I didn't want this to be a just
# repo so I added a couple of Perl
# scripts... maybe I should find
# better things to do.

use strict;
use warnings;

exec "megablink", "-u", @ARGV;
