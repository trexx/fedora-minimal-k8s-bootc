# Installer environment for the ISO. image-builder's "bootc-installer" type builds the ISO
# from two containers: this one, which supplies Anaconda, and the payload image built from
# dockerfile, which is embedded in the ISO and installed by the kickstart in config.toml.
# It replaces bootc-image-builder's "anaconda-iso" type, which is deprecated and cannot
# build Fedora 45 images.
#
# Only the ISO uses this image; it is never pushed or installed. Keep FEDORA_VERSION in
# step with the payload -- build.sh passes the same value to both.
ARG FEDORA_VERSION=44
FROM quay.io/fedora/fedora-bootc:${FEDORA_VERSION}

RUN dnf install -y --setopt=install_weak_deps=False \
      anaconda \
      anaconda-install-env-deps \
      anaconda-dracut \
      dracut-config-generic \
      dracut-network \
      net-tools \
      squashfs-tools \
      grub2-efi-x64-cdboot \
      python3-mako \
      'lorax-templates-*' \
      biosdevname \
      prefixdevname \
    && dnf clean all

# image-builder expects the EFI boot files under /boot/efi, where bootupd-era Fedora (43+)
# no longer puts them in the image.
RUN mkdir -p /boot/efi && cp -ra /usr/lib/efi/*/*/EFI/ /boot/efi

# lorax creates a /mnt symlink pointing at /var/mnt, which the base image does not ship.
RUN mkdir -p /var/mnt
