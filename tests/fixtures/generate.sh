#!/usr/bin/env bash
# Regenerates tests/fixtures/mirror: release sums in the layouts of oras,
# etcd, rclone and hadolint, signed with two throwaway test keys. The sums are
# made up (sums of the asset names), the keys exist only here and their
# secret halves are deleted with the temporary keyring.
#
# Run it only to change the fixtures; the tests use the committed output.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
mirror="$here/mirror"
# A short keyring path: gpg-agent's socket lives in it.
home=$(mktemp -d)
trap 'gpgconf --homedir "$home" --kill all >/dev/null 2>&1 || true; rm -rf "$home"' EXIT
g() { gpg --batch --no-tty --homedir "$home" --pinentry-mode loopback --passphrase '' "$@"; }

g --quick-gen-key 'pin-checksums test key A <a@test.invalid>' ed25519 sign never 2>/dev/null
g --quick-gen-key 'pin-checksums test key B <b@test.invalid>' ed25519 sign never 2>/dev/null
fpr() { g --with-colons --fingerprint "$1" | awk -F: '$1 == "fpr" {print $10; exit}'; }
key_a=$(fpr a@test.invalid)
key_b=$(fpr b@test.invalid)

rm -rf "$mirror"
fake() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
sums() { for a in "$@"; do printf '%s  %s\n' "$(fake "$a")" "$a"; done; }

# oras: checksums.txt with a detached ASCII signature, key from a KEYS file
# that holds both test keys.
d="$mirror/github.com/oras-project/oras/releases/download/v1.4.0"
mkdir -p "$d"
sums oras_1.4.0_darwin_amd64.tar.gz oras_1.4.0_linux_amd64.tar.gz oras_1.4.0_linux_arm64.tar.gz >"$d/oras_1.4.0_checksums.txt"
g --local-user "$key_a" --armor --detach-sign --output "$d/oras_1.4.0_checksums.txt.asc" "$d/oras_1.4.0_checksums.txt"
g --local-user "$key_b" --armor --detach-sign --output "$d/signed-by-b.asc" "$d/oras_1.4.0_checksums.txt"
mkdir -p "$mirror/raw.githubusercontent.com/oras-project/oras/main"
g --armor --export "$key_a" "$key_b" >"$mirror/raw.githubusercontent.com/oras-project/oras/main/KEYS"

# etcd: SHA256SUMS, unsigned, several architectures.
d="$mirror/github.com/etcd-io/etcd/releases/download/v3.6.17"
mkdir -p "$d"
sums etcd-v3.6.17-darwin-arm64.zip etcd-v3.6.17-linux-amd64.tar.gz etcd-v3.6.17-linux-arm64.tar.gz etcd-v3.6.17-linux-ppc64le.tar.gz >"$d/SHA256SUMS"

# rclone: a clear-signed SHA256SUMS, key from keys.openpgp.org.
d="$mirror/downloads.rclone.org/v1.76.0"
mkdir -p "$d"
sums rclone-v1.76.0-linux-amd64.zip rclone-v1.76.0-linux-arm64.zip rclone-v1.76.0-osx-arm64.zip \
  | g --local-user "$key_b" --clearsign >"$d/SHA256SUMS"
mkdir -p "$mirror/keys.openpgp.org/vks/v1/by-fingerprint"
g --armor --export "$key_b" >"$mirror/keys.openpgp.org/vks/v1/by-fingerprint/$key_b"

# hadolint: checksums.sha256 in binary mode ("<sum> *<name>"), unsigned.
d="$mirror/github.com/hadolint/hadolint/releases/download/v2.15.1"
mkdir -p "$d"
for a in hadolint-linux-arm64 hadolint-linux-x86_64 hadolint-macos-arm64; do
  printf '%s *%s\n' "$(fake "$a")" "$a"
done >"$d/checksums.sha256"

# s3fs: a source archive without published sums.
d="$mirror/github.com/s3fs-fuse/s3fs-fuse/archive"
mkdir -p "$d"
printf 'not really a tarball\n' >"$d/v1.98.tar.gz"

printf 'KEY_A=%s\nKEY_B=%s\n' "$key_a" "$key_b" >"$here/keys.env"
echo "Fixtures written; key A $key_a, key B $key_b"
