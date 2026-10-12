# The Fedora release to build. build.sh passes FEDORA_VERSION so the image and the ISO's
# installer environment always match; the default here is for building by hand.
ARG FEDORA_VERSION=44

# Pinned third-party binaries (k0s, etcdctl) are fetched in their own stage, so tar is not
# needed in the final image and the downloads stay cached until fetch.sh changes.
FROM quay.io/fedora/fedora-bootc:${FEDORA_VERSION} AS fetch
RUN --mount=type=bind,source=fetch.sh,target=/tmp/fetch.sh \
    bash /tmp/fetch.sh /out

# Build the root filesystem from the "minimal" manifest plus packages.txt. Installing the
# packages here, rather than with dnf in the final stage, means the initramfs is generated
# with lvm2 and cryptsetup already present (so it carries the lvm and crypt dracut
# modules), and the rootfs comes out clean -- no dnf caches, /run leftovers or initramfs
# regeneration to deal with afterwards.
#
# build-rootfs reads its repos from this builder's /etc/yum.repos.d, which is why the
# CRI-O repo is copied here; files/ carries the same file into the final image.
#
# This stage depends only on packages.txt and the repo file, so editing anything else
# under files/ does not re-run it. The cache mount keeps repo metadata and RPMs between
# builds.
FROM quay.io/fedora/fedora-bootc:${FEDORA_VERSION} AS builder
COPY files/etc/yum.repos.d/cri-o.repo /etc/yum.repos.d/cri-o.repo
RUN --mount=type=bind,source=packages.txt,target=/tmp/packages.txt \
    --mount=type=cache,target=/var/cache/bootc-rootfs \
    /usr/libexec/bootc-base-imagectl build-rootfs --manifest=minimal \
      --cachedir=/var/cache/bootc-rootfs \
      $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*/--install=/' /tmp/packages.txt) \
      /target-rootfs

# Create a new, empty image from scratch and copy the root file system into it.
FROM scratch
COPY --from=builder /target-rootfs/ /
COPY --from=fetch /out/k0s /out/etcdctl /usr/bin/

# Apply the config tree and the remaining customizations. These live in customize.sh
# rather than inline here, to keep this file to image structure. The script and files/
# are bind-mounted for the duration of the RUN, so neither becomes part of the built image.
# It is invoked via "bash" rather than executed directly so the build does not depend on
# its file mode.
RUN --mount=type=bind,source=customize.sh,target=/tmp/customize.sh \
    --mount=type=bind,source=files,target=/tmp/files \
    bash /tmp/customize.sh

# Required label for this image to be recognized as a bootc image.
LABEL containers.bootc=1
# https://pagure.io/fedora-kiwi-descriptions/pull-request/52
ENV container=oci
# Optional settings that only apply when running this image as a container. These keep
# the default entry point running under systemd.
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
