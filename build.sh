#!/usr/bin/env bash
# Build the bootc image, rechunk it, and build the Anaconda installer ISO.
# Uses rootful podman, so run it as root:
#
#   sudo ./build.sh [image|rechunk|iso|all]     (default: all)
#
# FEDORA_VERSION selects the release for both the image and the ISO's installer, e.g.
#   sudo FEDORA_VERSION=45 ./build.sh image

set -euo pipefail

FEDORA_VERSION="${FEDORA_VERSION:-44}"
IMAGE=ghcr.io/trexx/fedora-minimal-bootc
BASE="quay.io/fedora/fedora-bootc:${FEDORA_VERSION}"
INSTALLER="localhost/fedora-minimal-bootc-installer:${FEDORA_VERSION}"
# Pinned by digest rather than :latest. This is image-builder, the successor to
# bootc-image-builder, whose own image stopped updating in June 2026 and cannot build
# Fedora 45 ISOs.
IMAGE_BUILDER=ghcr.io/osbuild/image-builder-cli@sha256:572972c40aca8fae7568cfc11f242c3062f01584a327352a11ccfbc03bf087d2

cd "$(dirname "$0")"

build_image() {
    # build-rootfs runs rpm-ostree inside the build, which needs the extra capabilities,
    # /dev/fuse and the container_runtime_t label.
    podman build --cap-add=all --security-opt=label=type:container_runtime_t --device /dev/fuse \
        --build-arg FEDORA_VERSION="$FEDORA_VERSION" -t "$IMAGE:latest" -f dockerfile .
}

rechunk() {
    # Split the image into content-based layers with normalized timestamps, so a bootc
    # upgrade only downloads layers whose content actually changed. chunkah writes an OCI
    # archive to stdout; CHUNKAH_CONFIG_STR carries the image's labels, environment and
    # command over to the result. chunkah's default of 64 layers is low for a bootable
    # image, hence 128.
    local loaded
    loaded=$(podman run --rm --mount=type=image,source="$IMAGE:latest",target=/chunkah \
            -e CHUNKAH_CONFIG_STR="$(podman inspect "$IMAGE:latest")" \
            "$BASE" /usr/libexec/bootc-base-imagectl rechunk --chunkah --max-layers 128 \
        | podman load -q)
    # "Loaded image: <ref>" -- tag whatever ref it reports.
    podman tag "${loaded##* }" "$IMAGE:chunked"
}

iso() {
    # A "bootc-installer" ISO is built from two containers: the installer environment from
    # installer.dockerfile, which supplies Anaconda, and the payload image, which is
    # embedded in the ISO and installed by the kickstart in config.toml. image-builder
    # then points the install at $IMAGE:chunked in the registry for upgrades. Fedora
    # bootc images declare no root filesystem type, hence --bootc-default-fs.
    podman build --build-arg FEDORA_VERSION="$FEDORA_VERSION" -t "$INSTALLER" \
        -f installer.dockerfile .
    mkdir -p output
    podman run --rm --privileged --security-opt label=type:unconfined_t \
        -v ./config.toml:/config.toml:ro -v ./output:/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "$IMAGE_BUILDER" build --bootc-ref "$INSTALLER" \
        --bootc-installer-payload-ref "$IMAGE:chunked" --bootc-default-fs xfs \
        --blueprint /config.toml --output-dir /output bootc-installer
}

case "${1:-all}" in
    image)   build_image ;;
    rechunk) rechunk ;;
    iso)     iso ;;
    all)     build_image; rechunk; iso ;;
    *)       echo "usage: $0 [image|rechunk|iso|all]" >&2; exit 2 ;;
esac
