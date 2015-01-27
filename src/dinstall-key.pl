#!/usr/bin/perl

# Small utility to import uploader GPG publickeys to mini-dinstall's
# (first) extra keyring. Assumes vsFTPd and mini-dinstall are used,
# and that both have config files in /etc with default names.
#
# The given publickey pathname can be a relative path; if no path is
# given, the default upload queue directory is searched for the file.
# The default upload queue is $HOME("ftp")/UploadQueue/.

use strict;
use warnings;
use re '/aa';
use open qw< :encoding(UTF-8) >;

my $mini_dinstall_conf = "/etc/mini-dinstall.conf";
my $vsftpd_conf        = "/etc/vsftpd.conf";

my $publickey = shift
    or die "usage: $0 <gpg_publickey_pathname>\n";

#-------------------------------------------------------------------------------
# Read username (vsftpd_conf:chown_username) and
# keyring (mini_dinstall_conf:extra_keyrings).

my $fh;
my $username;
my $keyring;

open ($fh, '<', $vsftpd_conf)
    or die "Failed to open $vsftpd_conf: $!\n";
while (<$fh>) {
    $username = $1 if /^\s*chown_username\s*=\s*(.*)/;
}
close($fh);

open ($fh, '<', $mini_dinstall_conf)
    or die "Failed to open $mini_dinstall_conf: $!\n";
while (<$fh>) {
    $keyring = $1 if /^\s*extra_keyrings\s*=\s*(.*)[,\s].*/;
}
close($fh);

#-------------------------------------------------------------------------------
# Find the user-supplied publickey.

unless ($publickey =~ m!^/|^./|^../!) {
    my $ftphome = (getpwnam 'ftp')[-2];
    my $uploadqueue = "$ftphome/UploadQueue";
    $publickey = "$uploadqueue/$publickey";
}

die "Publickey '$publickey': $!\n" unless stat($publickey);

#-------------------------------------------------------------------------------
# Check if sudo is needed and run the appropriate gpg command.
# (The command 'sudo -u <user> ...' is not <user>'ish enough for GPG,
#  so 'sudo su -c ... <user>' is used instead.)

my $sudoprefix = '';
my $sudosuffix = '';

unless ($username eq getpwuid($<)) {
    print "Using sudo to run GPG as '$username'...\n";
    $sudoprefix = "sudo su -c '";
    $sudosuffix = "' $username";
}

my $gpgopts = '-v --no-tty --no-default-keyring';
system("${sudoprefix}gpg $gpgopts --keyring $keyring --import $publickey${sudosuffix}") == 0
    or die "Failed to import GPG publickey '$publickey'\n";

print "Publickey '$publickey' may now be removed.\n";
