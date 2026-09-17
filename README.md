# fedora-minimal

A [bootc](https://bootc-dev.github.io/bootc/) image and Anaconda installer ISO for one machine: a
headless, single-node [k0s](https://k0sproject.io) Kubernetes host built from the Fedora bootc
*minimal* manifest. The OS is an OCI image; the host upgrades by pulling a new one.

Most of the reasoning lives as comments next to the thing it explains. This file is the index.

## What is on the image

- Fedora bootc minimal plus CRI-O (upstream 1.36 stream, matching the Kubernetes k0s bundles) with
  crun, k0s and etcdctl pinned by checksum, dropbear for SSH, systemd-networkd/resolved/timesyncd,
  thermald, nvme-cli, lvm2 and cryptsetup. [`customize.sh`](customize.sh) lists what is installed
  and, more importantly, what is deliberately not.
- k0s runs as a single controller+worker with kube-proxy, CoreDNS, metrics-server, the network
  provider and Helm disabled. Cilium (as CNI and kube-proxy replacement) and CoreDNS are installed on
  top after first boot, not by k0s. See [`files/etc/k0s/k0s.yaml`](files/etc/k0s/k0s.yaml) and
  [`k0scontroller.service`](files/usr/lib/systemd/system/k0scontroller.service).
- Host services in `files/usr/lib/systemd/system/`: weekly etcd defrag, daily NVMe health check,
  boot-time power tuning (replaces TLP), SELinux booleans for device access, and a one-time `/data`
  relabel.
- Hardware assumptions: a single NVMe disk, Intel CPU and iGPU, a Nuvoton sensor chip, a Sonoff Zigbee
  dongle (exposed as `/dev/zigbee`) and a NanoKVM for the console. The hardware-specific bits are in
  `files/etc/modules-load.d/`, `files/usr/lib/udev/rules.d/` and `files/usr/libexec/power-tuning`.

## Build and publish

Prerequisites: rootful podman (every step runs under `sudo`), `/dev/fuse`, and a
`sudo podman login ghcr.io` for the push.

```
./build.sh build     # Containerfile -> ghcr.io/trexx/fedora-minimal-bootc:latest (bootc lint runs last)
./build.sh rechunk   # re-layers it for efficient upgrades -> :chunked
./build.sh push      # publishes :chunked, the tag the installed host upgrades from
./build.sh iso       # Anaconda ISO from :chunked -> output/bootiso/install.iso
./build.sh all       # all of the above, in order
```

`output/` is build output and is not tracked.

### CI

`.github/workflows/build.yml` runs `build.sh` on GitHub's hosted runner. Pull requests build, lint
and rechunk without pushing; merges to `master` and a weekly schedule (Sunday 04:00 UTC) publish
`:chunked`, so `bootc upgrade` on the host keeps receiving Fedora updates without a manual build.
Publishing needs a one-time grant: in the `fedora-minimal-bootc` package's settings, under "Manage
Actions access", add this repository with the Write role. `./build.sh iso` stays manual, since it
needs the real SSH key and produces a 2 GB file.

## Install

[`config.toml`](config.toml) carries the kickstart: UK keyboard, `en_GB`, Copenhagen time, hostname
`k0s`, root locked with key-only SSH, and this layout on `nvme0n1`:

```
/boot/efi   600M   plain
/boot       1G     plain
/           20G    plain, unencrypted: holds only the public OS image
LUKS2 container, one passphrase -> VG "fedora"
  /var      200G   container storage, /var/lib/k0s (etcd), journal
  /data     rest   host-provisioned PVC storage
```

Replace the placeholder SSH key in `config.toml` before building an ISO. The ISO installs the image
embedded in it and then points the host at `ghcr.io/trexx/fedora-minimal-bootc:chunked` for upgrades
(bootc-image-builder does both, which is why the kickstart has no `ostreecontainer` line of its own).

Test a new ISO in a UEFI VM with a virtual NVMe disk before reinstalling the real machine.

## First boot

1. The LUKS passphrase is asked on the console after the initramfs, by systemd, before `/var` mounts.
   Nothing else starts until it is entered.
2. SSH in as root with the key from the kickstart (dropbear, port 22).
3. Install Cilium (kube-proxy replacement mode; there is no kube-proxy) and CoreDNS. The admin
   kubeconfig is `/var/lib/k0s/pki/admin.conf`.
4. `/data` is relabelled `container_file_t` once by `data-relabel.service`; the SELinux booleans for
   `/dev/dri` and the Zigbee dongle are set on every boot by `selinux-booleans.service`.

## Upgrading

- OS: `bootc upgrade` (or `bootc upgrade --check` first), then reboot. `bootc rollback` returns to the
  previous deployment. `/etc` and `/var` persist; everything else comes from the image.
- Image: `./build.sh all` after changing anything here. For a new Fedora release bump `FEDORA` in
  `build.sh`; it is passed into the Containerfile.
- k0s: set `K0S_VERSION`/`K0S_SHA256` in `customize.sh` from the release's `sha256sums.txt`, then
  `ETCD_VERSION`/`ETCD_SHA256` to what `k0s version --all` reports, from etcd's `SHA256SUMS`, and the
  two `v1.36` path components in `files/etc/yum.repos.d/cri-o.repo` to the new Kubernetes minor.

## Accepted risks

Deliberate trade-offs, each documented where it is made:

- `mitigations=off` on the kernel command line (`files/usr/lib/bootc/kargs.d/10-server.toml`).
- No host firewall: the minimal manifest ships none, and every workload on the node is our own.
  Network policy is Cilium's job.
- `container_use_devices` is on, giving containers broad device access; needed for the Zigbee serial
  device (`selinux-booleans.service`).
- `/` and therefore `/etc` are unencrypted, so the dropbear host keys are readable from the disk.
  Everything secret lives in `/var` and `/data`, which are encrypted.
- Every boot needs the passphrase at the console. TPM2 auto-unlock is a possible later step and needs
  no initramfs work, since the unlock happens in the real root.
