#!/usr/bin/env bash
# Build the bootc image, rechunk it, and build the Anaconda installer ISO.
# Uses rootful podman, so run it as root:
#
#   sudo ./build.sh [image|rechunk|iso|all]     (default: all)

set -euo pipefail

IMAGE=ghcr.io/trexx/fedora-minimal-bootc
BASE=quay.io/fedora/fedora-bootc:44
# Pinned by digest rather than :latest. bootc-image-builder's sources have moved into
# osbuild/image-builder; this is the last multi-arch image published here (2026-06-18).
BIB=quay.io/centos-bootc/bootc-image-builder@sha256:2b52843ea2bfda73b0a08d97e76b734393b1d3a804681b9fabb26723bd3a2f0b

cd "$(dirname "$0")"

build_image() {
    # build-rootfs runs rpm-ostree inside the build, which needs the extra capabilities,
    # /dev/fuse and the container_runtime_t label.
    podman build --cap-add=all --security-opt=label=type:container_runtime_t --device /dev/fuse \
        -t "$IMAGE:latest" -f dockerfile .
}

rechunk() {
    # Split the image into content-based layers with normalized timestamps, so a bootc
    # upgrade only downloads layers whose content actually changed. chunkah writes an OCI
    # archive to stdout; CHUNKAH_CONFIG_STR carries the image's labels, environment and
    # command over to the result. chunkah's default of 64 layers is low for a bootable
    # image, hence 128.
    local loaded
    loaded=$(podman run --rm --mount=type=image,src="$IMAGE:latest",dest=/chunkah \
            -e CHUNKAH_CONFIG_STR="$(podman inspect "$IMAGE:latest")" \
            "$BASE" /usr/libexec/bootc-base-imagectl rechunk --chunkah --max-layers 128 \
        | podman load -q)
    # "Loaded image: <ref>" -- tag whatever ref it reports.
    podman tag "${loaded##* }" "$IMAGE:chunked"
}

iso() {
    # The kickstart in config.toml does the partitioning. The image embedded in the ISO is
    # what gets installed; bootc-image-builder then points the install at $IMAGE:chunked
    # in the registry for upgrades.
    mkdir -p output
    podman run --rm --privileged --security-opt label=type:unconfined_t \
        -v ./config.toml:/config.toml:ro -v ./output:/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "$BIB" --type anaconda-iso --rootfs xfs "$IMAGE:chunked"
}

case "${1:-all}" in
    image)   build_image ;;
    rechunk) rechunk ;;
    iso)     iso ;;
    all)     build_image; rechunk; iso ;;
    *)       echo "usage: $0 [image|rechunk|iso|all]" >&2; exit 2 ;;
esac
