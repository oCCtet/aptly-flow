#!/usr/bin/perl

## aptly-flow - streamline complex but recurring aptly tasks
##
## Commands:
##
##     update mirrors
##         update all configured mirrors
##
##     publish mirror <distribution> [<prefix>]
##         re-publish the distribution by re-snapshotting each
##         component (whose source is a mirror or local repo),
##         switching them, and dropping the obsoleted snapshots
##
##     incoming process <incoming_dir> <repo> <distribution> [<prefix>]
##         look for .dsc, .udeb and .deb files in incoming_dir, add
##         them to repo, and update the distribution
##
##     process incoming
##     process mirrors
##         process *all* configured (in the config file) incoming_db and
##         mirror_db items, respectively
##
##     help flow
##         show this help
##

use strict;
use warnings;
use re '/aa';
use open qw< :encoding(UTF-8) >;

my $min_aptly_version = 90;

#-------------------------------------------------------------------------------
# Options that can be overridded via the user- or site-specific
# config file (user-specific takes precedence).

our $dryrun = 1;
our $passphrase_file = '';
our $drop_old_snapshots = 0;
our %incoming_db;
our %mirror_db;

for my $file ("$ENV{HOME}/.aptly-flow.conf",
              "/etc/aptly-flow.conf")
{
    last if my $return = do $file;
    die  "Could not parse $file: $@"  if $@;
    warn "Could not read $file: $!\n" unless defined $return;
}

#-------------------------------------------------------------------------------
# Command-line option parsing.

my $command_arg = shift;
my $action_arg  = shift;
my $distro_arg;
my $prefix_arg;
my $indir_arg;
my $inrepo_arg;

my $do_re_snapshot_and_publish = 0;
my $do_update_mirrors = 0;
my $do_process_incoming = 0;
my $do_process_all_incoming = 0;
my $do_process_all_mirrors = 0;

die "usage: $0 <command> <action> [args ...]\n"
    unless $command_arg and $action_arg;

SWITCH:
for ($command_arg)
{
    if (/^help$/) {
        open(my $self, '<', $0);
        while (<$self>) {
            print s/^[#]*[ ]?//r if /^[#]{2}\s?/;
        }
        close($self);
        last SWITCH;
    }
    if (/^publish$/) {
        for ($action_arg) {
            if (/^mirror$/) {
                $distro_arg = shift;
                $prefix_arg = shift;
                die "usage: $0 publish mirror <distribution> [<prefix>]\n"
                    unless $distro_arg;
                $prefix_arg = '.' unless $prefix_arg;
                $do_re_snapshot_and_publish = 1;
                last SWITCH;
            }
        }
    }
    if (/^update$/) {
        for ($action_arg) {
            if (/^mirrors$/) {
                $do_update_mirrors = 1;
                last SWITCH;
            }
        }
    }
    if (/^incoming$/) {
        for ($action_arg) {
            if (/^process$/) {
                $indir_arg = shift;
                $inrepo_arg = shift;
                $distro_arg = shift;
                $prefix_arg = shift;
                die "usage: $0 incoming process <incoming_dir> <repo> <distribution> [<prefix>]\n"
                    unless $distro_arg;
                $prefix_arg = '.' unless $prefix_arg;
                $do_process_incoming = 1;
                last SWITCH;
            }
        }
    }
    if (/^process$/) {
        for ($action_arg) {
            if (/^incoming$/) {
                $do_process_all_incoming = 1;
                last SWITCH;
            }
            if (/^mirrors$/) {
                $do_process_all_mirrors = 1;
                last SWITCH;
            }
        }
    }
    die "try '$0 help flow' for help\n";
}

#-------------------------------------------------------------------------------
# Variables set based on config (file/command-line) options.

my $gpgopts = '';
$gpgopts = "-passphrase-file=$passphrase_file" if $passphrase_file;

my $comment = '';
$comment = 'echo \#' if $dryrun == 1;

#-------------------------------------------------------------------------------
# Execute the desired action.

`aptly version` =~ /version:\s*(\d+)\.(\d+).*/
    or die "Unrecognized aptly version\n";
die "Too old aptly version\n"
    unless (($1 * 1000) + ($2 * 10)) >= $min_aptly_version;

re_snapshot_and_publish($distro_arg, $prefix_arg)
    if $do_re_snapshot_and_publish == 1;

update_mirrors()
    if $do_update_mirrors == 1;

process_incoming($indir_arg, $inrepo_arg, $distro_arg, $prefix_arg)
    if $do_process_incoming == 1;

if ($do_process_all_incoming == 1) {
    foreach my $repo (keys %incoming_db) {
        process_incoming($incoming_db{$repo}[0], $repo,
            $incoming_db{$repo}[1], $incoming_db{$repo}[2]);
    }
}

if ($do_process_all_mirrors == 1) {
    foreach $prefix_arg (keys %mirror_db) {
        foreach $distro_arg (@{ $mirror_db{$prefix_arg} }) {
            re_snapshot_and_publish($distro_arg, $prefix_arg);
        }
    }
}

#-------------------------------------------------------------------------------
# Update all mirrors.

sub update_mirrors
{
    system("aptly mirror list -raw | xargs -n 1 ${comment}aptly mirror update") == 0
        or die "Failed to update all mirrors\n";
}

#-------------------------------------------------------------------------------
# Parse publish list for the specified distro, and
#  * re-create snapshots for each component,
#  * switch snapshots in proper order (preserving components),
#  * and finally drop old snapshots.

sub re_snapshot_and_publish
{
    my ($distro, $prefix) = @_;

    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) =
        localtime(time);
    my $timestamp = sprintf("%04d%02d%02dT%02d%02d%02d",
        $year + 1900, $mon + 1, $mday, $hour, $min, $sec);

    my $distro_regexp = qr![*]\s$prefix/$distro\s.*\spublishes\s(.*)!;
    my $wrd = '[-\w]+';  # a word allowing the '-' character
    my $publish_regexp =
        qr/\{($wrd):\s\[($wrd)\]:\sSnapshot from (mirror|local repo)\s\[($wrd)\]:.*\}/;

    # Select the matching prefix/distro line from the output
    # of 'aptly publish list' and split it into sections, one
    # per published component.
    `aptly publish list` =~ /$distro_regexp/
        or die "No such distribution ($distro) in $prefix\n";
    my @sections = split /(?:,\s)/, $1;

    my $cmdfile = sprintf("/tmp/aptly_run_%s.cmd", $$);
    open(my $fh, '>', $cmdfile)
        or die "Failed to open command file $cmdfile: $!\n";

    # Create a new snapshot for each component and store
    # relevant information for later.
    my %components;
    my @oldsnaps;
    foreach my $section (@sections) {
        my ($component, $snapshot, $type, $mirror) = ($section =~ /$publish_regexp/);
        next unless $mirror;
        if ($type eq "mirror") {
            print $fh "snapshot create ${mirror}-snap-${timestamp} from mirror $mirror\n"
                or die "Failed to update command file: $!, stopped";
        } elsif ($type eq "local repo") {
            print $fh "snapshot create ${mirror}-snap-${timestamp} from repo $mirror\n"
                or die "Failed to update command file: $!, stopped";
        }
        push @oldsnaps, $snapshot;
        $components{$component} = "${mirror}-snap-${timestamp}";
    }

    # Switch snapshots of the published distribution.
    my $complist = join ',', keys %components;
    my $snaplist = join ' ', values %components;
    print $fh "publish switch $gpgopts -component=$complist $distro $prefix $snaplist\n"
        or die "Failed to update command file: $!, stopped";

    # Drop the old, now obsolete, snapshots. If they happen
    # to be in another use, aptly shall refuse to drop them.
    if ($drop_old_snapshots == 1) {
        foreach my $oldsnap (@oldsnaps) {
            print $fh "snapshot drop $oldsnap\n"
                or warn "Failed to update command file: $!, warning";
        }
    }

    close($fh);
    if ($dryrun == 1) {
        print <$fh> if open($fh, '<', $cmdfile);
        close($fh);
    }
    system("${comment}aptly task run -filename=$cmdfile") == 0
        or warn "Errors in aptly task run\n";
    unlink($cmdfile);
}

#-------------------------------------------------------------------------------
# Process incoming packages.

sub process_incoming
{
    my ($incoming_dir, $target_repo, $distro, $prefix) = @_;

    chdir $incoming_dir or die "Failed to cd to $incoming_dir: $!\n";
    unless (my @files = glob("*.dsc *.udeb *.deb")) {
        warn "No files to process in $incoming_dir\n";
        return;
    }

    my $cmdfile = sprintf("/tmp/aptly_run_%s.cmd", $$);
    open(my $fh, '>', $cmdfile)
        or die "Failed to open command file $cmdfile: $!\n";

    print $fh "repo add -force-replace -remove-files $target_repo $incoming_dir\n"
        or die "Failed to update command file: $!, stopped";
    print $fh "publish update -force-overwrite $gpgopts $distro $prefix\n"
        or die "Failed to update command file: $!, stopped";

    close($fh);
    if ($dryrun == 1) {
        print <$fh> if open($fh, '<', $cmdfile);
        close($fh);
    }
    system("${comment}aptly task run -filename=$cmdfile") == 0
        or warn "Errors in aptly task run\n";
    unlink($cmdfile);
}
