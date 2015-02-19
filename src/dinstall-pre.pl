#!/usr/bin/perl

# Ensure the .changes declares a distribution for which
# mini-dinstall has config sections (or aliases).

use strict;
use warnings;
use re '/aa';
use open qw< :encoding(UTF-8) >;

my @dists;
my $dist;
my $mini_dinstall_conf = "/etc/mini-dinstall.conf";

my $changespath = shift
    or die "usage: $0 <changes_file_path>\n";

# Resolve allowed dists, i.e. section names
# and aliases (except the name DEFAULT).
open (my $fh, '<', $mini_dinstall_conf)
    or die "Failed to open $mini_dinstall_conf: $!\n";
while (<$fh>) {
    push @dists, split /DEFAULT|,\s*/, $1
        if /(?|^\[([-\w]+)\]$|^alias\s*=\s*(.*))/;
}
close($fh);

# Resolve the dist in .changes file.
open (my $ch, '<', $changespath)
    or die "Failed to open $changespath: $!\n";
while (<$ch>) {
    $dist = $1 if /^Distribution:\s*([-\w]+)/;
}
close($ch);

# Verify the dist is in allowed dists list.
foreach (@dists) {
    exit 0 if /$dist/;
}
die "Distribution '$dist' denied (allowed: ", join(', ', @dists), ")\n";
