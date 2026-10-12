#!/usr/bin/env bash
# Fetch the pinned third-party binaries into the directory given as $1.
# Runs in the dockerfile's fetch stage, so curl and tar are needed only there, and the
# result is cached until this file changes. The final stage copies the binaries into
# /usr/bin: /usr/local would also be image content on current Fedora bootc bases, but
# /usr/bin keeps them alongside everything else the image manages.

set -xeuo pipefail

out="$1"

# k0s publishes sha256sums.txt with each release; K0S_SHA256 is its k0s-<version>-amd64
# entry. etcdctl is pinned to the etcd version k0s actually embeds -- check
# "k0s version --all" before bumping either, since a client newer than the server is a
# latent problem. v1.36.4+k0s.1 embeds etcd 3.6.14.
K0S_VERSION="v1.36.4+k0s.1"
K0S_SHA256="18c304d53cdd70095e99c6b859b269b4fef0bb84579d7e7185271a9135694a31"
ETCD_VERSION="v3.6.14"
ETCD_SHA256="ffe840ff9295808e88cce2794a18a5ac87f12a5203c8314d0bf6aa119b41bac5"

install -d -m0755 "$out"

curl -fsSL -o "$out/k0s" \
  "https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION//+/%2B}/k0s-${K0S_VERSION//+/%2B}-amd64"
echo "${K0S_SHA256}  $out/k0s" | sha256sum -c -
chmod 0755 "$out/k0s"

curl -fsSL -o /tmp/etcd.tar.gz \
  "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz"
echo "${ETCD_SHA256}  /tmp/etcd.tar.gz" | sha256sum -c -
tar -xzf /tmp/etcd.tar.gz -C "$out" --strip-components=1 --no-same-owner \
  "etcd-${ETCD_VERSION}-linux-amd64/etcdctl"
rm -f /tmp/etcd.tar.gz
