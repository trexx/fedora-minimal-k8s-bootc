#!/usr/bin/env bash
# Final-stage customizations applied to the fedora-minimal bootc image.
# Invoked from the dockerfile via a bind mount, so this script is never part of the
# built image and does not need cleaning up afterwards. The config it installs lives
# in the files/ tree, bind-mounted alongside it at /tmp/files. Packages are installed
# earlier, by build-rootfs -- see packages.txt.

# Set pipefail to display failures within the script and avoid false-positive successful builds.
set -xeuo pipefail

# Lay down the config tree. Plain "cp -R", not "cp -a": -a also copies owner and mode onto
# directories that already exist -- / itself included -- so with rootful podman a checkout
# owned by a normal user would hand /, /etc and /usr to that UID. Without -a, existing
# directories keep the base image's metadata, everything copied is owned by root, and new
# entries take their mode from the source filtered by the umask, which drops any group or
# world write bit a checkout made under umask 002 would carry. Symlinks are copied as
# symlinks.
umask 022
cp -R /tmp/files/. /

# Unit enablement is declared in files/usr/lib/systemd/system-preset/50-k8s-node.preset.
# build-rootfs already applied the base presets; re-applying them all picks up ours.
systemctl preset-all

# Headless server: nothing should ever suspend it.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# Run the bootc linter to avoid encountering certain bugs and maintain content quality.
# Place this as the final command.
bootc container lint
