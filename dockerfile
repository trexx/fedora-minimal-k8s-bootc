# Begin with a standard bootc base image that is reused as a "builder" for the custom image.
FROM quay.io/fedora/fedora-bootc:44 as builder
# Configure and override source RPM repositories, if necessary. This step is not required when building up from minimal unless referencing specific content views or target mirrored/snapshotted/pinned versions of content.
# Add additional repositories to apply customizations to the image. However, referencing a custom manifest in this step is not currently supported without forking the code.
# Build the root file system using the specified repositories and non-RPM content from the "builder" base image.
# If no repositories are defined, the default build will be used. You can modify the scope of packages in the base image by changing the manifest between the "standard" and "minimal" sets.
RUN /usr/libexec/bootc-base-imagectl build-rootfs --manifest=minimal /target-rootfs

# Create a new, empty image from scratch.
FROM scratch
# Copy the root file system built in the previous step into this image.
COPY --from=builder /target-rootfs/ /

# Apply customizations to the image. These live in customize.sh rather than inline here, to
# keep this file to image structure. The script is bind-mounted for the duration of the RUN,
# so it never becomes part of the built image and needs no cleanup. It is invoked via "bash"
# rather than executed directly so the build does not depend on its file mode.
#
# The files/ tree is bind-mounted the same way and copied into place by the script, which
# keeps this to a single layer and lets the bootc linter run last.
RUN --mount=type=bind,source=customize.sh,target=/tmp/customize.sh \
    --mount=type=bind,source=files,target=/tmp/files \
    bash /tmp/customize.sh

# Define required labels for this bootc image to be recognized as such.
LABEL containers.bootc 1
LABEL ostree.bootable 1
# https://pagure.io/fedora-kiwi-descriptions/pull-request/52
ENV container=oci
# Optional labels that only apply when running this image as a container. These keep the default entry point running under systemd.
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
