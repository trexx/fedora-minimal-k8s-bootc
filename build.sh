#!/usr/bin/env bash
# Build, publish and package the fedora-minimal bootc image.
#
#   ./build.sh build     build the image from the Containerfile; bootc lint runs as its last step
#   ./build.sh rechunk   re-layer :latest into :chunked for efficient bootc upgrades
#   ./build.sh push      push :chunked, the tag the installed host upgrades from
#   ./build.sh iso       build the Anaconda ISO from :chunked using config.toml -> output/bootiso/
#   ./build.sh all       all of the above, in order
#
# Every step runs podman under sudo: the image build needs capabilities and /dev/fuse, and
# rechunk and the ISO builder work on root's container storage. "sudo podman login ghcr.io"
# is a prerequisite for push. IMAGE, FEDORA and PODMAN_SECURITY_OPT can be overridden in the
# environment.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/trexx/fedora-minimal-bootc}"
FEDORA="${FEDORA:-44}"
BASE="quay.io/fedora/fedora-bootc:${FEDORA}"
BIB="quay.io/centos-bootc/bootc-image-builder:latest"

cd "$(dirname "$0")"

# Attach a terminal to the long-running steps when there is one, for progress output; stay
# usable from cron or CI when there is not.
tty=()
[ -t 0 ] && tty=(-it)

build() {
  # --pull=newer refreshes the fedora-bootc base each build; without it a cached base image
  # is reused indefinitely and "bootc upgrade" on the host never sees Fedora updates.
  # The SELinux label lets the builder stage run rpm-ostree under the host's policy. It means
  # nothing on a host without SELinux, such as the GitHub runner, where CI sets label=disable.
  sudo podman build --pull=newer --build-arg "FEDORA=${FEDORA}" \
    --cap-add=all --security-opt="${PODMAN_SECURITY_OPT:-label=type:container_runtime_t}" --device /dev/fuse \
    -t "${IMAGE}:latest" .
}

rechunk() {
  sudo podman run --rm "${tty[@]}" --privileged -v /var/lib/containers:/var/lib/containers \
    "${BASE}" /usr/libexec/bootc-base-imagectl rechunk "${IMAGE}:latest" "${IMAGE}:chunked"
}

push() {
  sudo podman push "${IMAGE}:chunked"
}

iso() {
  mkdir -p output
  sudo podman run --rm "${tty[@]}" --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./config.toml:/config.toml:ro -v ./output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "${BIB}" --type anaconda-iso --target-arch amd64 --rootfs xfs "${IMAGE}:chunked"
}

usage() {
  sed -n '2,/^set -euo/{/^set -euo/!s/^# \{0,1\}//p}' "$0" >&2
  exit 2
}

case "${1:-}" in
  build|rechunk|push|iso) "$1" ;;
  all) build; rechunk; push; iso ;;
  *) usage ;;
esac
