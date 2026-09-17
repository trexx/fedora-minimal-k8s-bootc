#!/usr/bin/env bash
# Customizations applied to the fedora-minimal bootc image.
# Invoked from the Containerfile via a bind mount, so this script is never part of the
# built image and does not need cleaning up afterwards. The config it installs lives
# in the files/ tree, bind-mounted alongside it at /tmp/files.

# Set pipefail to display failures within the script and avoid false-positive successful builds.
set -xeuo pipefail

# Pinned third-party binaries. When bumping, take the digests from the upstream checksum
# files rather than computing them locally: sha256sums.txt on the k0s release page and
# SHA256SUMS on the etcd one (k0s also ships a cosign .sig, which is not needed here).
# etcdctl is pinned to the etcd version k0s actually embeds -- check "k0s version --all"
# before bumping either, since a client newer than the server is a latent problem.
K0S_VERSION="v1.36.3+k0s.0"
K0S_SHA256="cb15600575b0257e23bb24a01703293e9666694b09636320ac4326fe6edde6f2"
ETCD_VERSION="v3.6.14"
ETCD_SHA256="ffe840ff9295808e88cce2794a18a5ac87f12a5203c8314d0bf6aa119b41bac5"

# The CRI-O repo has to land before the dnf transaction, so it is copied ahead of the rest
# of the files/ tree (which must go down after dnf, to win over package-shipped config).
# The later "cp -a" re-copies it harmlessly.
install -D -m0644 /tmp/files/etc/yum.repos.d/cri-o.repo /etc/yum.repos.d/cri-o.repo

# Install required packages for our custom bootc image.
# Note that using a minimal manifest means we need to add critical components specific to our
# use case and environment. For example, install networking and SSH - not every use case will
# want SSH, so it's not included in minimal.
#
# Deliberately absent: systemd-timesyncd (no such package on F44 -- the binary ships in
# systemd-udev), and containernetworking-plugins (Cilium supplies its own CNI binary).
# util-linux is named explicitly because fstrim.timer lives there, not in util-linux-core.
#
# nvme-cli rather than smartmontools: this box is NVMe-only, and smartmontools pulls
# smartmontools-selinux via a rich dependency, which drags in policycoreutils-python-utils
# and ~55 MB of Python. nvme-health.timer replaces smartd -- see files/usr/libexec.
#
# No tlp either: it is Perl and requires usbutils, which requires python3, so between them
# perl-libs, python3-libs, hwdata and groff-base added ~80 MB. power-tuning.service writes
# the same sysfs values with no dependencies at all -- see files/usr/libexec/power-tuning.
#
# lvm2 and cryptsetup serve the real root, not the initramfs: / is a plain partition (see the
# kickstart in config.toml), while /var and /data are LVs inside a LUKS2 container that
# systemd-cryptsetup unlocks and lvm2's udev rules activate after switch-root.
dnf --setopt=install_weak_deps=False -y install \
  curl \
  vim-minimal \
  cri-o \
  crun \
  systemd-networkd \
  systemd-resolved \
  systemd-oomd-defaults \
  dropbear \
  thermald \
  nvme-cli \
  authselect \
  policycoreutils \
  lvm2 \
  cryptsetup \
  tar \
  util-linux

# No initramfs regeneration. The base image's initramfs carries no lvm module, but / is a
# plain xfs partition (see the kickstart in config.toml), which it boots as-is; the LUKS
# container holding /var and /data is unlocked by systemd-cryptsetup and activated by lvm2's
# udev rules in the real root. Should / ever move back onto LVM or LUKS, dracut has to be
# re-run here with "--add ostree --add lvm --add crypt" (bootc ships the image's initramfs
# unchanged), and the result checked with lsinitrd, since dracut can drop a module and still
# exit 0.

# Fetch k0s and etcdctl into /usr/bin. The upstream installer drops them in /usr/local/bin,
# which on bootc is a symlink to /var/usrlocal -- writable and persistent, but outside image
# management and invisible to rollback.
curl -fsSL -o /usr/bin/k0s \
  "https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION//+/%2B}/k0s-${K0S_VERSION//+/%2B}-amd64"
echo "${K0S_SHA256}  /usr/bin/k0s" | sha256sum -c -
chmod 0755 /usr/bin/k0s

curl -fsSL -o /tmp/etcd.tar.gz \
  "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz"
echo "${ETCD_SHA256}  /tmp/etcd.tar.gz" | sha256sum -c -
tar -xzf /tmp/etcd.tar.gz -C /usr/bin --strip-components=1 --no-same-owner \
  "etcd-${ETCD_VERSION}-linux-amd64/etcdctl"
rm -f /tmp/etcd.tar.gz

# Lay down the config tree. This runs after the dnf install so our files win over
# anything a package ships at the same path. --no-preserve=ownership matters: the bind mount
# carries the host checkout's uid/gid (the build is rootful, so nothing remaps it), and a
# plain "cp -a" would bake that into the image. Modes and timestamps are still preserved.
cp -a --no-preserve=ownership /tmp/files/. /

authselect select local --force

# The /data SELinux label rule ships as files/etc/selinux/.../file_contexts.local rather
# than being generated here with semanage -- see the comment in that file. Applying it to
# the real filesystem is data-relabel.service's job at runtime.

# Headless server: nothing should ever suspend it.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

systemctl enable \
  crio.service \
  k0scontroller.service \
  etcd-defrag.timer \
  data-relabel.service \
  selinux-booleans.service \
  systemd-networkd.service \
  systemd-resolved.service \
  systemd-timesyncd.service \
  power-tuning.service \
  thermald.service \
  nvme-health.timer \
  systemd-oomd.service \
  fstrim.timer \
  dropbear.service

# Remove leftover build artifacts from installing packages from the final built image.
dnf clean all
rm /var/{log,cache,lib}/* -rf

# /run and /tmp are runtime-only and must be empty in the image; package scriptlets leave
# state behind in /run during the build (dnf, lvm, selinux-policy), which the bootc linter
# flags. /tmp is left alone: the only things in it are this script and the files/ tree,
# both bind mounts that are not committed to the image and cannot be removed while mounted.
#
# The "|| true" is required, not defensive: podman bind-mounts /run/secrets and
# /run/systemd/resolve/stub-resolv.conf, so rm hits EBUSY on them. Those are mounts rather
# than image content and never get committed, so removing everything else is the goal.
rm -rf /run/* 2>/dev/null || true

# Run the bootc linter to avoid encountering certain bugs and maintain content quality.
# Place this as the final command. Warnings are fatal: a lint that fires here fails the build
# instead of surfacing on the host later.
bootc container lint --fatal-warnings
