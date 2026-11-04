# fedora-minimal-k8s-bootc

A customised Fedora distribution composed and deployed via bootc / OCI images. It builds a minimal Fedora bootc image that runs a single-node [k0s](https://k0sproject.io) Kubernetes controller, published as `ghcr.io/trexx/fedora-minimal-bootc`, plus an Anaconda installer ISO that installs it. The configuration is written for one specific machine (a single NVMe disk, Intel CPU and iGPU, a Zigbee USB dongle), not for general hardware.

## Overview

### Image build

- `dockerfile` has two stages. The builder stage starts from `quay.io/fedora/fedora-bootc` and runs `bootc-base-imagectl build-rootfs --manifest=minimal` to produce a minimal root filesystem. The final stage starts `FROM scratch`, copies that root filesystem in, and sets the bootc labels.
- `customize.sh` does all customisation in a single `RUN`. It and the `files/` tree are bind-mounted for that step, so neither becomes part of the image. The script:
  - installs the packages the host needs (CRI-O and crun, systemd-networkd/resolved, dropbear for SSH, thermald, nvme-cli, lvm2, cryptsetup and a few utilities) without weak dependencies;
  - regenerates the initramfs with the `ostree`, `lvm` and `crypt` dracut modules and fails the build if any of them is missing, since the installed system boots from LUKS-encrypted LVM;
  - downloads pinned, SHA-256-verified `k0s` and `etcdctl` binaries into `/usr/bin` (not `/usr/local/bin`, which is outside image management on bootc);
  - copies `files/` over the root filesystem, masks the sleep/suspend/hibernate targets, enables the host's units, cleans up, and finishes with `bootc container lint`.

### What the host runs

`k0scontroller.service` runs `k0s controller --single=true` against CRI-O, with k0s's own CoreDNS, kube-proxy, metrics-server, network provider, Helm and Konnectivity components disabled. Networking (Cilium, as the image's comments note), DNS and the rest of the cluster's workloads are deployed onto the cluster separately. The cluster configuration is in `files/etc/k0s/k0s.yaml`.

The `files/` tree is laid out as it lands on the host:

| Path | Purpose |
|---|---|
| `etc/k0s/k0s.yaml` | k0s ClusterConfig: API SAN, pod CIDR, kube-proxy disabled, custom network provider, etcd storage |
| `etc/yum.repos.d/cri-o.repo` | Upstream CRI-O repository, pinned to the stream matching the Kubernetes minor that k0s bundles |
| `etc/crio/crio.conf.d/20-crun.conf` | Makes crun the default CRI-O runtime |
| `usr/lib/bootc/kargs.d/10-server.toml` | Kernel arguments; part of the image, so they apply on every bootc upgrade and not only at install |
| `usr/lib/sysctl.d/` | Kubelet tuning, NMI watchdog off, larger UDP socket buffers for Traefik |
| `usr/lib/systemd/system/etcd-defrag.*` | Weekly etcd defragmentation (Sunday 03:00) |
| `usr/lib/systemd/system/nvme-health.*`, `usr/libexec/nvme-health-check` | Daily NVMe health report to the journal (used instead of smartd) |
| `usr/lib/systemd/system/power-tuning.service`, `usr/libexec/power-tuning` | CPU, iGPU, PCIe ASPM and USB autosuspend settings written directly to sysfs (used instead of TLP) |
| `usr/lib/systemd/system/data-relabel.service` | One-time SELinux relabel of `/data` |
| `usr/lib/systemd/system/selinux-booleans.service` | Sets the runtime SELinux booleans that give containers access to the GPU and the Zigbee dongle |
| `etc/selinux/targeted/contexts/files/file_contexts.local` | Labels `/data` as `container_file_t` |
| `usr/lib/systemd/network/89-ethernet.network` | DHCP on physical Ethernet interfaces only |
| `usr/lib/udev/rules.d/99-zigbee.rules` | Stable `/dev/zigbee` symlink for the Sonoff Zigbee 3.0 USB Dongle Plus |
| `etc/modules-load.d/sensors.conf` | Loads `coretemp` and `nct6775` for hardware monitoring |
| `usr/lib/systemd/journald.conf.d/10-retention.conf` | Seven-day journal retention |

### Installer ISO

`config.toml` is a [bootc-image-builder](https://github.com/osbuild/bootc-image-builder) configuration for an `anaconda-iso`. Its kickstart:

- installs from `ghcr.io/trexx/fedora-minimal-bootc:chunked`;
- wipes `nvme0n1` and creates `/boot/efi`, `/boot`, and one LUKS2-encrypted LVM physical volume holding `/` (20 GiB), `/var` (200 GiB) and `/data` (the rest);
- prompts for the LUKS passphrase during the interactive install (none is stored in the file);
- locks the root password and installs one SSH public key for root, used by dropbear;
- sets a GB keyboard, `en_GB.UTF-8` and the `Europe/Copenhagen` timezone.

## Usage

1. Edit `config.toml`. Replace the placeholder `sshkey` line with your own public key: with the placeholder in place the installed host cannot be reached. Adjust the disk, locale and timezone if they do not match your machine.
2. Build the image, rechunk it and build the ISO with the three commands in [build.txt](build.txt). They need root and privileged podman. The ISO is written under `output/bootiso/`, which is git-ignored.
3. Boot the target machine from the ISO and enter a LUKS passphrase when Anaconda asks for one. The machine reboots into the installed image when installation finishes.
4. Log in as root over SSH (dropbear) with the key from step 1.

The installed system tracks the image reference from the kickstart, `ghcr.io/trexx/fedora-minimal-bootc:chunked`, so a newer image pushed to that tag is picked up by a bootc upgrade.

## Configuration

Most settings are host-specific and live in the files listed above. The ones most likely to need changing:

- `config.toml`: SSH key, target disk, partition sizes, keyboard, locale, timezone.
- `customize.sh`: `K0S_VERSION`/`K0S_SHA256` and `ETCD_VERSION`/`ETCD_SHA256`. Keep `etcdctl` at the etcd version k0s embeds (`k0s version --all`).
- `files/etc/yum.repos.d/cri-o.repo`: the CRI-O stream (both `v1.xx` path components), which should follow the Kubernetes minor that k0s ships.
- `files/etc/k0s/k0s.yaml`: API server SAN and pod CIDR.
- `files/usr/libexec/power-tuning`: the USB devices kept out of autosuspend, and the iGPU frequency cap (750 MHz, which also limits hardware transcode and ML inference).
- `files/usr/lib/udev/rules.d/99-zigbee.rules`: the dongle's USB serial number.
- `files/usr/lib/bootc/kargs.d/10-server.toml`: kernel arguments (`mitigations=off`, `workqueue.power_efficient=true`).

## Development

There is no CI build and no test suite: the image needs privileged podman, so it is built locally with the commands in [build.txt](build.txt). The build fails if the initramfs is missing a required dracut module, a downloaded binary does not match its pinned checksum, or `bootc container lint` reports a problem.

Repository layout:

| Path | Contents |
|---|---|
| `dockerfile` | Image structure (base, rootfs build, labels) |
| `customize.sh` | Package installation, initramfs, binaries, unit enablement |
| `files/` | Configuration copied into the image |
| `config.toml` | bootc-image-builder / kickstart configuration for the ISO |
| `build.txt` | Build, rechunk and ISO commands |
| `output/manifest-anaconda-iso.json` | osbuild manifest written by bootc-image-builder for the ISO build |
| `.github/renovate.json` | Renovate configuration (shared `trexx/actions` preset), which keeps the base image tag current |

## Releases

The image is published as `ghcr.io/trexx/fedora-minimal-bootc`. `build.txt` produces two tags: `latest`, the direct build, and `chunked`, the rechunked image that the installer and installed hosts use. Images are built outside CI and there are no git tags; pushing to the registry is not part of `build.txt`.
