#!/bin/sh
# post-install script for mini-dinstall

set -e

# location of .changes file after
# stage2 import is done
log_dir=/srv/logs/changes/

changes_pathname=$1
basepath=$(dirname $changes_pathname)

# ensure installed files are owned by the
# (group) dinstall, and are group-writable
chown dinstall:dinstall $basepath/*
chmod 0664 $basepath/*

# as user aptly, perform stage2 import;
# requires a suitable sudoers spec (see
# /etc/sudoers.d/dinstall2aptly)
sudo -u aptly aptly-flow process incoming

# move the .changes file into logs
mv $changes_pathname $log_dir
