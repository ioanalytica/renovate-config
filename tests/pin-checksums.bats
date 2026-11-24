#!/usr/bin/env bats
# scripts/pin-checksums.sh against the fixtures in tests/fixtures/mirror,
# served through PIN_CHECKSUMS_TEST_MIRROR: no network.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)
  SCRIPT="$ROOT/scripts/pin-checksums.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures"
  # shellcheck source=fixtures/keys.env
  source "$FIX/keys.env"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test.invalid
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test.invalid
  MIRROR="$BATS_TEST_TMPDIR/mirror"
  cp -R "$FIX/mirror" "$MIRROR"
  export PIN_CHECKSUMS_TEST_MIRROR="$MIRROR"
  REPO="$BATS_TEST_TMPDIR/repo"
  ERR="$BATS_TEST_TMPDIR/error"
  SUM="$BATS_TEST_TMPDIR/summary"
  make_repo
}

OLD64=0000000000000000000000000000000000000000000000000000000000000000

# The sum of an asset in a fixture's sums file.
fixture_sum() { awk -v a="$2" '{ n = $2; sub(/^\*/, "", n) } n == a { print $1 }' "$MIRROR/$1"; }

make_repo() {
  mkdir -p "$REPO/.github/actions/setup-oras" "$REPO/.github/actions/setup-hadolint" "$REPO/docker"
  cd "$REPO"
  git init -q -b main .
  cat >.github/actions/setup-oras/action.yml <<EOF
runs:
  using: composite
  steps:
    - shell: bash
      env:
        # renovate: datasource=github-releases depName=oras-project/oras
        ORAS_VERSION: 1.3.6
        ORAS_SHA256: $OLD64
      run: echo "\$ORAS_SHA256"
EOF
  cat >.github/actions/setup-hadolint/action.yml <<EOF
runs:
  using: composite
  steps:
    - shell: bash
      env:
        # renovate: datasource=github-releases depName=hadolint/hadolint
        HADOLINT_VERSION: "2.15.0"
        HADOLINT_SHA256: "$OLD64"
      run: echo "\$HADOLINT_SHA256"
EOF
  cat >docker/Dockerfile <<EOF
FROM alpine:3.24
# renovate: datasource=github-releases depName=s3fs-fuse/s3fs-fuse
ARG S3FS_VERSION=1.97
ARG S3FS_SHA512=${OLD64}${OLD64}
# renovate: datasource=github-releases depName=etcd-io/etcd
ARG ETCD_VERSION=3.6.16
ARG ETCD_SHA256_AMD64=$OLD64
ARG ETCD_SHA256_ARM64=$OLD64
RUN case "\${TARGETARCH}" in amd64) sum="\${ETCD_SHA256_AMD64}" ;; esac
# renovate: datasource=github-releases depName=rclone/rclone
ARG RCLONE_VERSION=1.75.0
ARG RCLONE_SHA256_AMD64=$OLD64
ARG RCLONE_SHA256_ARM64=$OLD64
RUN env -u RCLONE_SHA256_AMD64 true
# renovate: datasource=github-tags depName=nginx/nginx
ARG NGINX_VERSION=1.30.7
EOF
  cat >docker/rclone.env <<EOF
# renovate: datasource=github-releases depName=rclone/rclone
RCLONE_VERSION=1.75.0
RCLONE_SHA256_AMD64=$OLD64
RCLONE_SHA256_ARM64=$OLD64
EOF
  cat >CHANGELOG.md <<'EOF'
# Changelog

## Unreleased

* **Something else.**

## 1.0.0

* First release.
EOF
  write_table
  git add -A
  git commit -q -m base
  git tag base
}

write_table() {
  cat >.github/checksums.yaml <<EOF
- name: oras
  version: .github/actions/setup-oras/action.yml#ORAS_VERSION
  sums: https://github.com/oras-project/oras/releases/download/v{v}/oras_{v}_checksums.txt
  signature: "{sums}.asc"
  key: ${KEY_A}
  key_url: https://raw.githubusercontent.com/oras-project/oras/main/KEYS
  pins:
    - file: .github/actions/setup-oras/action.yml
      var: ORAS_SHA256
      asset: oras_{v}_linux_amd64.tar.gz
  changelog:
    file: CHANGELOG.md
    line: "* **oras {v}** for the release jobs (was {old})."
- name: etcd
  version: docker/Dockerfile#ETCD_VERSION
  sums: https://github.com/etcd-io/etcd/releases/download/v{v}/SHA256SUMS
  pins:
    - { file: docker/Dockerfile, var: ETCD_SHA256_AMD64, asset: "etcd-v{v}-linux-amd64.tar.gz" }
    - { file: docker/Dockerfile, var: ETCD_SHA256_ARM64, asset: "etcd-v{v}-linux-arm64.tar.gz" }
  changelog:
    file: CHANGELOG.md
    line: "* **etcd {v} in the agent image.**"
- name: rclone
  version: docker/rclone.env#RCLONE_VERSION
  sums: https://downloads.rclone.org/v{v}/SHA256SUMS
  signature: inline
  key: "${KEY_B:0:4} ${KEY_B:4:36}"
  pins:
    - { file: docker/rclone.env, var: RCLONE_SHA256_AMD64, asset: "rclone-v{v}-linux-amd64.zip" }
    - { file: docker/rclone.env, var: RCLONE_SHA256_ARM64, asset: "rclone-v{v}-linux-arm64.zip" }
    - { file: docker/Dockerfile, var: RCLONE_SHA256_AMD64, asset: "rclone-v{v}-linux-amd64.zip" }
    - { file: docker/Dockerfile, var: RCLONE_SHA256_ARM64, asset: "rclone-v{v}-linux-arm64.zip" }
- name: hadolint
  version: .github/actions/setup-hadolint/action.yml#HADOLINT_VERSION
  sums: https://github.com/hadolint/hadolint/releases/download/v{v}/checksums.sha256
  pins:
    - file: .github/actions/setup-hadolint/action.yml
      var: HADOLINT_SHA256
      asset: hadolint-linux-x86_64
- name: s3fs
  version: docker/Dockerfile#S3FS_VERSION
  algorithm: sha512
  pins:
    - file: docker/Dockerfile
      var: S3FS_SHA512
      url: https://github.com/s3fs-fuse/s3fs-fuse/archive/v{v}.tar.gz
- name: nginx
  version: docker/Dockerfile#NGINX_VERSION
  changelog:
    file: CHANGELOG.md
    line: "* **NGINX {v} in the image** (was {old})."
EOF
}

# Sets VAR to VALUE in FILE, as Renovate does, and commits.
bump() {
  local file=$1 var=$2 value=$3
  sed -E -i.bak "s/^([[:space:]]*(ARG )?${var}(: \"?|=))[^\"[:space:]]+/\\1${value}/" "$file"
  rm -f "$file.bak"
  git add -A
  git commit -q -m "update $var to $value"
}

pin() {
  run "$SCRIPT" -C "$REPO" --base base --table-ref base --error "$ERR" --summary "$SUM" "$@"
}

value_of() { grep -E "^[[:space:]]*(ARG )?$2(: |=)" "$1" | sed -E 's/.*(: |=)"?([^"]*)"?$/\2/'; }

@test "oras: the sum of a PGP-signed checksums.txt, and a changelog line" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"signature of https://github.com/oras-project/oras/releases/download/v1.4.0/oras_1.4.0_checksums.txt verified, made by $KEY_A"* ]] || false
  expected=$(fixture_sum github.com/oras-project/oras/releases/download/v1.4.0/oras_1.4.0_checksums.txt oras_1.4.0_linux_amd64.tar.gz)
  [ "$(value_of .github/actions/setup-oras/action.yml ORAS_SHA256)" = "$expected" ]
  [ "$(cat "$SUM")" = "oras 1.3.6 1.4.0" ]
  diff -u - CHANGELOG.md <<'EOF'
# Changelog

## Unreleased

* **oras 1.4.0** for the release jobs (was 1.3.6).
* **Something else.**

## 1.0.0

* First release.
EOF
  [ "$(git status --porcelain | sort)" = "$(printf ' M .github/actions/setup-oras/action.yml\n M CHANGELOG.md')" ]
}

@test "etcd: two architectures from SHA256SUMS" {
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  pin
  [ "$status" -eq 0 ]
  f=github.com/etcd-io/etcd/releases/download/v3.6.17/SHA256SUMS
  [ "$(value_of docker/Dockerfile ETCD_SHA256_AMD64)" = "$(fixture_sum $f etcd-v3.6.17-linux-amd64.tar.gz)" ]
  [ "$(value_of docker/Dockerfile ETCD_SHA256_ARM64)" = "$(fixture_sum $f etcd-v3.6.17-linux-arm64.tar.gz)" ]
  [ "$(value_of docker/Dockerfile ETCD_SHA256_AMD64)" != "$(value_of docker/Dockerfile ETCD_SHA256_ARM64)" ]
  grep -qF 'sum="${ETCD_SHA256_AMD64}"' docker/Dockerfile
  grep -qxF '* **etcd 3.6.17 in the agent image.**' CHANGELOG.md
}

@test "rclone: a clear-signed SHA256SUMS, the same pins in two files" {
  bump docker/rclone.env RCLONE_VERSION 1.76.0
  sed -i.bak 's/^ARG RCLONE_VERSION=.*/ARG RCLONE_VERSION=1.76.0/' docker/Dockerfile && rm docker/Dockerfile.bak
  git commit -qam "rclone in the Dockerfile"
  pin
  [ "$status" -eq 0 ]
  f=downloads.rclone.org/v1.76.0/SHA256SUMS
  amd=$(fixture_sum $f rclone-v1.76.0-linux-amd64.zip)
  arm=$(fixture_sum $f rclone-v1.76.0-linux-arm64.zip)
  [ "$(value_of docker/rclone.env RCLONE_SHA256_AMD64)" = "$amd" ]
  [ "$(value_of docker/rclone.env RCLONE_SHA256_ARM64)" = "$arm" ]
  [ "$(value_of docker/Dockerfile RCLONE_SHA256_AMD64)" = "$amd" ]
  [ "$(value_of docker/Dockerfile RCLONE_SHA256_ARM64)" = "$arm" ]
  grep -qF 'RUN env -u RCLONE_SHA256_AMD64 true' docker/Dockerfile
}

@test "hadolint: checksums.sha256 in binary mode, no signature, quoted values" {
  bump .github/actions/setup-hadolint/action.yml HADOLINT_VERSION 2.15.1
  pin
  [ "$status" -eq 0 ]
  expected=$(fixture_sum github.com/hadolint/hadolint/releases/download/v2.15.1/checksums.sha256 hadolint-linux-x86_64)
  grep -qxF "        HADOLINT_SHA256: \"$expected\"" .github/actions/setup-hadolint/action.yml
  grep -qxF '        HADOLINT_VERSION: "2.15.1"' .github/actions/setup-hadolint/action.yml
}

@test "s3fs: the sha512 of a download without published sums" {
  bump docker/Dockerfile S3FS_VERSION 1.98
  pin
  [ "$status" -eq 0 ]
  expected=$(shasum -a 512 "$MIRROR/github.com/s3fs-fuse/s3fs-fuse/archive/v1.98.tar.gz" | cut -d' ' -f1)
  [ "$(value_of docker/Dockerfile S3FS_SHA512)" = "$expected" ]
}

@test "unchanged versions: nothing downloaded, nothing written" {
  rm -rf "$MIRROR"
  pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"No version changed: nothing to do."* ]] || false
  [ -z "$(git status --porcelain)" ]
  [ ! -s "$SUM" ]
}

@test "a second run writes nothing" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin
  [ "$status" -eq 0 ]
  git commit -qam "pinned"
  pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"All values already in place: nothing written."* ]] || false
  [ -z "$(git status --porcelain)" ]
  [ ! -s "$SUM" ]
}

@test "a changelog line edited in review is not added again" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin
  [ "$status" -eq 0 ]
  sed -i.bak 's/for the release jobs (was 1.3.6)/for the release jobs, with a fix for CVE-0000-0001/' CHANGELOG.md && rm CHANGELOG.md.bak
  git commit -qam "pinned, line edited"
  pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHANGELOG.md already mentions oras 1.4.0 in this pull request"* ]] || false
  [ -z "$(git status --porcelain)" ]
  [ "$(grep -c 'oras 1.4.0' CHANGELOG.md)" -eq 1 ]
}

@test "a changelog without an Unreleased section gets one" {
  printf '# Changelog\n\n## 1.0.0\n\n* First release.\n' >CHANGELOG.md
  git commit -qam "no unreleased" && git tag -f base >/dev/null
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  pin
  [ "$status" -eq 0 ]
  diff -u - CHANGELOG.md <<'EOF'
# Changelog

## Unreleased

* **etcd 3.6.17 in the agent image.**

## 1.0.0

* First release.
EOF
}

@test "an empty Unreleased section keeps a blank line before the next heading" {
  printf '# Changelog\n\n## Unreleased\n\n## 1.0.0\n\n* First release.\n' >CHANGELOG.md
  git commit -qam "empty unreleased" && git tag -f base >/dev/null
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  pin
  [ "$status" -eq 0 ]
  diff -u - CHANGELOG.md <<'EOF'
# Changelog

## Unreleased

* **etcd 3.6.17 in the agent image.**

## 1.0.0

* First release.
EOF
}

@test "several changed entries in one run" {
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin
  [ "$status" -eq 0 ]
  [ "$(cat "$SUM")" = "$(printf 'oras 1.3.6 1.4.0\netcd 3.6.16 3.6.17')" ]
  [ "$(sed -n 5,7p CHANGELOG.md)" = "$(printf '* **oras 1.4.0** for the release jobs (was 1.3.6).\n* **etcd 3.6.17 in the agent image.**\n* **Something else.**')" ]
}

@test "a tampered checksums.txt fails its signature and nothing is written" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  f="$MIRROR/github.com/oras-project/oras/releases/download/v1.4.0/oras_1.4.0_checksums.txt"
  sed -i.bak "s/^[0-9a-f]\{64\}  oras_1.4.0_linux_amd64/${OLD64/0/1}  oras_1.4.0_linux_amd64/" "$f" && rm "$f.bak"
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "oras: the signature does not verify against $KEY_A" ]] || false
  [ -z "$(git status --porcelain)" ]
}

@test "a signature by another key of the KEYS file is refused" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  d="$MIRROR/github.com/oras-project/oras/releases/download/v1.4.0"
  cp "$d/signed-by-b.asc" "$d/oras_1.4.0_checksums.txt.asc"
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "oras: the signature is not made by $KEY_A" ]] || false
  [ -z "$(git status --porcelain)" ]
}

@test "a key that is not in the KEYS file is refused" {
  sed -i.bak "s/key: ${KEY_A}/key: ${KEY_A:0:39}0/" .github/checksums.yaml && rm .github/checksums.yaml.bak
  git commit -qam "other key" && git tag -f base >/dev/null
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "oras: the key ${KEY_A:0:39}0 is not in https://raw.githubusercontent.com/oras-project/oras/main/KEYS" ]] || false
}

@test "text outside a clear-signed message is refused" {
  bump docker/rclone.env RCLONE_VERSION 1.76.0
  bump docker/Dockerfile RCLONE_VERSION 1.76.0
  f="$MIRROR/downloads.rclone.org/v1.76.0/SHA256SUMS"
  { printf '%s  rclone-v1.76.0-linux-amd64.zip\n\n' "${OLD64/0/2}"; cat "$f"; } >"$f.new" && mv "$f.new" "$f"
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "rclone: https://downloads.rclone.org/v1.76.0/SHA256SUMS is not a single clear-signed message" ]] || false
  [ -z "$(git status --porcelain)" ]
}

@test "a changed line inside a clear-signed message fails its signature" {
  bump docker/rclone.env RCLONE_VERSION 1.76.0
  bump docker/Dockerfile RCLONE_VERSION 1.76.0
  f="$MIRROR/downloads.rclone.org/v1.76.0/SHA256SUMS"
  sed -i.bak "s/^[0-9a-f]\{64\}  rclone-v1.76.0-linux-arm64/${OLD64/0/3}  rclone-v1.76.0-linux-arm64/" "$f" && rm "$f.bak"
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "rclone: the signature does not verify against $KEY_B" ]] || false
}

@test "an asset missing from the sums fails" {
  bump .github/actions/setup-hadolint/action.yml HADOLINT_VERSION 2.15.1
  f="$MIRROR/github.com/hadolint/hadolint/releases/download/v2.15.1/checksums.sha256"
  grep -v 'linux-x86_64' "$f" >"$f.new" && mv "$f.new" "$f"
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "hadolint: no sum for hadolint-linux-x86_64 in the sums" ]] || false
}

@test "sums that cannot be downloaded fail" {
  bump docker/Dockerfile ETCD_VERSION 3.6.18
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "etcd: cannot download the sums from https://github.com/etcd-io/etcd/releases/download/v3.6.18/SHA256SUMS" ]] || false
}

@test "one failed entry stops the writes of all" {
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  # oras, the first entry, passes; etcd, the second, fails.
  f="$MIRROR/github.com/etcd-io/etcd/releases/download/v3.6.17/SHA256SUMS"
  grep -v 'linux-arm64' "$f" >"$f.new" && mv "$f.new" "$f"
  pin
  [ "$status" -eq 1 ]
  [[ "$output" == *"signature of https://github.com/oras-project"*"verified"* ]] || false
  [[ "$(cat "$ERR")" == "etcd: no sum for etcd-v3.6.17-linux-arm64.tar.gz in the sums" ]] || false
  [ -z "$(git status --porcelain)" ]
}

@test "a failed first entry stops the writes of all" {
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  d="$MIRROR/github.com/oras-project/oras/releases/download/v1.4.0"
  cp "$d/signed-by-b.asc" "$d/oras_1.4.0_checksums.txt.asc"
  pin
  [ "$status" -eq 1 ]
  [ -z "$(git status --porcelain)" ]
}

@test "the table comes from --table-ref, not from the pull request" {
  sed -i.bak "s/key: ${KEY_A}/key: ${KEY_B}/" .github/checksums.yaml && rm .github/checksums.yaml.bak
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  d="$MIRROR/github.com/oras-project/oras/releases/download/v1.4.0"
  cp "$d/signed-by-b.asc" "$d/oras_1.4.0_checksums.txt.asc"
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "oras: the signature is not made by $KEY_A" ]] || false
}

@test "a repository without a table has nothing to do" {
  git rm -q .github/checksums.yaml && git commit -qm "no table" && git tag -f base >/dev/null
  pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"No .github/checksums.yaml at base: nothing to do."* ]] || false
}

@test "--dry-run checks everything and writes nothing" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: all checks passed, nothing written."* ]] || false
  [ -z "$(git status --porcelain)" ]
}

@test "--all processes unchanged entries and adds no changelog line" {
  run "$SCRIPT" -C "$REPO" --all --error "$ERR"
  [ "$status" -eq 1 ]  # the base versions have no fixtures
  [[ "$(cat "$ERR")" == "oras: cannot download the sums from https://github.com/oras-project/oras/releases/download/v1.3.6/oras_1.3.6_checksums.txt" ]] || false
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  bump docker/rclone.env RCLONE_VERSION 1.76.0
  bump docker/Dockerfile RCLONE_VERSION 1.76.0
  bump .github/actions/setup-hadolint/action.yml HADOLINT_VERSION 2.15.1
  bump docker/Dockerfile S3FS_VERSION 1.98
  run "$SCRIPT" -C "$REPO" --all --error "$ERR"
  [ "$status" -eq 0 ]
  [ -z "$(git status --porcelain CHANGELOG.md)" ]
  [ "$(value_of docker/Dockerfile ETCD_SHA256_AMD64)" != "$OLD64" ]
}

# --- The table is checked before anything is downloaded ------------------------

table_error() {
  # $1: a command that changes the table at base
  eval "$1"
  git commit -qam "table" && git tag -f base >/dev/null
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin
  [ "$status" -eq 1 ]
  [ -z "$(git status --porcelain)" ]
}

edit_table() { sed -i.bak "$1" .github/checksums.yaml && rm .github/checksums.yaml.bak; }

@test "a path with .. is refused" {
  table_error "edit_table 's#- file: .github/actions/setup-oras/action.yml#- file: .github/../outside.yml#'"
  [[ "$(cat "$ERR")" == "oras: pin: the path '.github/../outside.yml' must be plain and relative, without ., .. or //" ]] || false
}

@test "a workflow file is refused" {
  table_error "edit_table 's#- file: .github/actions/setup-oras/action.yml#- file: .github/workflows/test.yml#'"
  [[ "$(cat "$ERR")" == *"is a workflow file, which the app cannot change"* ]] || false
}

@test "an http URL is refused" {
  table_error "edit_table 's#sums: https://github.com/oras-project#sums: http://github.com/oras-project#'"
  [[ "$(cat "$ERR")" == "oras: sums: 'http://github.com/oras-project/oras/releases/download/v1.4.0/oras_1.4.0_checksums.txt' is not an https URL of plain characters" ]] || false
}

@test "an unknown key in an entry is refused" {
  table_error "printf -- '- name: extra\n  version: docker/Dockerfile#ETCD_VERSION\n  signatur: inline\n  pins: []\n' >>.github/checksums.yaml"
  [[ "$(cat "$ERR")" == "extra: unknown keys: signatur" ]] || false
}

@test "a short key id is refused" {
  table_error "edit_table 's/key: ${KEY_A}/key: ${KEY_A:24:16}/'"
  [[ "$(cat "$ERR")" == "oras: the key '${KEY_A:24:16}' is not a full fingerprint (40 or 64 hex digits)" ]] || false
}

@test "a version with other characters is refused" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION '1.4.0\/..\/x'
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "oras: the version '1.4.0/../x' has characters other than letters, digits and ._+-" ]] || false
}

@test "a variable assigned twice is refused" {
  printf 'ARG ETCD_SHA256_AMD64=%s\n' "$OLD64" >>docker/Dockerfile
  git commit -qam "twice" && git tag -f base >/dev/null
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "etcd: pin: ETCD_SHA256_AMD64 is assigned 2 times in docker/Dockerfile, not once" ]] || false
}

@test "a pin file that is a symbolic link out of the work tree is refused" {
  printf 'X_VERSION=1\nX_SHA256=%s\n' "$OLD64" >"$BATS_TEST_TMPDIR/outside.env"
  ln -s "$BATS_TEST_TMPDIR/outside.env" docker/link.env
  git add -A && git commit -qm link
  sed -i.bak 's#{ file: docker/rclone.env#{ file: docker/link.env#' .github/checksums.yaml && rm .github/checksums.yaml.bak
  git commit -qam "table" && git tag -f base >/dev/null
  bump docker/rclone.env RCLONE_VERSION 1.76.0
  bump docker/Dockerfile RCLONE_VERSION 1.76.0
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "rclone: pin: docker/link.env is a symbolic link" ]] || false
}

@test "usage errors exit 2" {
  run "$SCRIPT" -C "$REPO"
  [ "$status" -eq 2 ]
  run "$SCRIPT" -C "$REPO" --all --base base
  [ "$status" -eq 2 ]
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "a changelog line keeps backslashes as they are" {
  edit_table "s|line: \"\* \*\*etcd {v} in the agent image.\*\*\"|line: '* etcd {v}: a\\\\nb \\\\\\\\ c'|"
  grep -qF "line: '* etcd {v}: a\\nb \\\\ c'" .github/checksums.yaml
  git commit -qam "table" && git tag -f base >/dev/null
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  pin
  [ "$status" -eq 0 ]
  grep -qxF '* etcd 3.6.17: a\nb \\ c' CHANGELOG.md
}

@test "an empty value before a comment keeps the comment apart" {
  sed -i.bak "s/^        ORAS_SHA256: $OLD64\$/        ORAS_SHA256: # filled by the workflow/" .github/actions/setup-oras/action.yml && rm .github/actions/setup-oras/action.yml.bak
  git commit -qam "empty pin" && git tag -f base >/dev/null
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin
  [ "$status" -eq 0 ]
  expected=$(fixture_sum github.com/oras-project/oras/releases/download/v1.4.0/oras_1.4.0_checksums.txt oras_1.4.0_linux_amd64.tar.gz)
  grep -qxF "        ORAS_SHA256: $expected # filled by the workflow" .github/actions/setup-oras/action.yml
}

@test "a revision that does not resolve is an error" {
  run "$SCRIPT" -C "$REPO" --base nosuchref --table-ref nosuchref --error "$ERR"
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "the revision nosuchref is not a commit in $REPO" ]] || false
  run "$SCRIPT" -C "$REPO" --base base --table-ref nosuchref --error "$ERR"
  [ "$status" -eq 1 ]
}

@test "a changelog line with a tab is refused" {
  table_error "edit_table 's|line: \"\* \*\*oras {v}\*\* for the release jobs (was {old}).\"|line: \"* oras {v}\\\\t(was {old})\"|'"
  [[ "$(cat "$ERR")" == "oras: the changelog line must be one line without tabs or other control characters" ]] || false
}

@test "a pin that is not an object is refused" {
  table_error "printf -- '- name: extra\\n  version: .github/actions/setup-oras/action.yml#ORAS_VERSION\\n  pins: [null]\\n' >>.github/checksums.yaml"
  [[ "$(cat "$ERR")" == "extra: pins must be a list of objects" ]] || false
}

@test "a symbolic link among the parent directories cannot reach the workflows" {
  mkdir -p .github/workflows && printf 'env:\n  ORAS_SHA256: %s\n' "$OLD64" >.github/workflows/build.yml
  ln -s .github/workflows wf
  git add -A && git commit -qm "link to workflows"
  table_error "edit_table 's#- file: .github/actions/setup-oras/action.yml#- file: wf/build.yml#'"
  [[ "$(cat "$ERR")" == "oras: pin: the path '.github/workflows/build.yml' is a workflow file, which the app cannot change; move the pin into a local action (.github/actions/)" ]] || false
}

@test "an empty YAML value with nothing after the colon is filled" {
  sed -i.bak "s/^        ORAS_SHA256: $OLD64\$/        ORAS_SHA256:/" .github/actions/setup-oras/action.yml && rm .github/actions/setup-oras/action.yml.bak
  git commit -qam "empty pin" && git tag -f base >/dev/null
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin
  [ "$status" -eq 0 ]
  expected=$(fixture_sum github.com/oras-project/oras/releases/download/v1.4.0/oras_1.4.0_checksums.txt oras_1.4.0_linux_amd64.tar.gz)
  grep -qxF "        ORAS_SHA256: $expected" .github/actions/setup-oras/action.yml
}

@test "the same line under a released version does not stop the Unreleased one" {
  printf '# Changelog\n\n## Unreleased\n\n## 1.0.0\n\n* **etcd 3.6.17 in the agent image.**\n' >CHANGELOG.md
  git commit -qam "released" && git tag -f base >/dev/null
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  pin
  [ "$status" -eq 0 ]
  [ "$(grep -c 'etcd 3.6.17' CHANGELOG.md)" -eq 2 ]
  [ "$(sed -n 5p CHANGELOG.md)" = '* **etcd 3.6.17 in the agent image.**' ]
}

@test "a pin file that pins another version is refused" {
  bump docker/rclone.env RCLONE_VERSION 1.76.0
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "rclone: RCLONE_VERSION in docker/Dockerfile is 1.75.0, not 1.76.0 as in docker/rclone.env" ]] || false
  [ -z "$(git status --porcelain)" ]
}

@test "a second update in the same pull request gets its own changelog line" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin
  [ "$status" -eq 0 ]
  git commit -qam "pinned oras"
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  pin
  [ "$status" -eq 0 ]
  grep -qxF '* **etcd 3.6.17 in the agent image.**' CHANGELOG.md
  [ "$(grep -c 'oras 1.4.0' CHANGELOG.md)" -eq 1 ]
}

@test "a pin file at another version is refused when only it moved" {
  sed -i.bak 's/^ARG RCLONE_VERSION=.*/ARG RCLONE_VERSION=1.76.0/' docker/Dockerfile && rm docker/Dockerfile.bak
  git commit -qam "rclone in the Dockerfile only"
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "rclone: RCLONE_VERSION in docker/Dockerfile is 1.76.0, not 1.75.0 as in docker/rclone.env" ]] || false
}

@test "a prerelease line does not count as the release's line" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0-rc.1
  printf '# Changelog\n\n## Unreleased\n\n* oras 1.4.0-rc.1 for testing.\n' >CHANGELOG.md
  git commit -qam "rc line"
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  pin
  [ "$status" -eq 0 ]
  grep -qxF '* **oras 1.4.0** for the release jobs (was 1.3.6).' CHANGELOG.md
}

@test "a line ending with the version and a full stop counts" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  printf '# Changelog\n\n## Unreleased\n\n* Moved oras to 1.4.0.\n' >CHANGELOG.md
  git commit -qam "own line"
  pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHANGELOG.md already mentions oras 1.4.0 in this pull request"* ]] || false
  [ "$(grep -c 'oras' CHANGELOG.md)" -eq 1 ]
}

@test "an asset of signed sums without {v} is refused" {
  table_error "edit_table 's#      asset: oras_{v}_linux_amd64.tar.gz#      asset: oras_linux_amd64.tar.gz#'"
  [[ "$(cat "$ERR")" == "oras: pin ORAS_SHA256: the asset of signed sums must contain {v}" ]] || false
}

# --- Entries without pins: only the changelog line -----------------------------

@test "nginx: an entry without pins gets its changelog line, nothing downloaded" {
  rm -rf "$MIRROR"
  bump docker/Dockerfile NGINX_VERSION 1.30.8
  pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"nginx 1.30.7 -> 1.30.8"*"no pins: only the changelog line"* ]] || false
  [ "$(cat "$SUM")" = "nginx 1.30.7 1.30.8 changelog" ]
  diff -u - CHANGELOG.md <<'EOF'
# Changelog

## Unreleased

* **NGINX 1.30.8 in the image** (was 1.30.7).
* **Something else.**

## 1.0.0

* First release.
EOF
  [ "$(git status --porcelain)" = " M CHANGELOG.md" ]
}

@test "an entry without pins: a second run adds no second line" {
  bump docker/Dockerfile NGINX_VERSION 1.30.8
  pin
  [ "$status" -eq 0 ]
  git commit -qam "line added"
  pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHANGELOG.md already mentions nginx 1.30.8 in this pull request"* ]] || false
  [[ "$output" == *"All values already in place: nothing written."* ]] || false
  [ -z "$(git status --porcelain)" ]
  [ ! -s "$SUM" ]
  [ "$(grep -c 'NGINX 1.30.8' CHANGELOG.md)" -eq 1 ]
}

@test "an entry without pins: a line edited in review is not added again" {
  bump docker/Dockerfile NGINX_VERSION 1.30.8
  pin
  [ "$status" -eq 0 ]
  sed -i.bak 's/in the image\*\* (was 1.30.7)/in the image**, with the fix for CVE-0000-0002/' CHANGELOG.md && rm CHANGELOG.md.bak
  git commit -qam "line edited"
  pin
  [ "$status" -eq 0 ]
  [ -z "$(git status --porcelain)" ]
  [ "$(grep -c 'NGINX 1.30.8' CHANGELOG.md)" -eq 1 ]
}

@test "an entry without pins writes nothing when another entry fails" {
  bump docker/Dockerfile NGINX_VERSION 1.30.8
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  f="$MIRROR/github.com/etcd-io/etcd/releases/download/v3.6.17/SHA256SUMS"
  grep -v 'linux-arm64' "$f" >"$f.new" && mv "$f.new" "$f"
  pin
  [ "$status" -eq 1 ]
  [[ "$(cat "$ERR")" == "etcd: no sum for etcd-v3.6.17-linux-arm64.tar.gz in the sums" ]] || false
  [ -z "$(git status --porcelain)" ]
  [ ! -s "$SUM" ]
}

@test "entries with and without pins in one run, lines in the table's order" {
  bump docker/Dockerfile NGINX_VERSION 1.30.8
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  pin
  [ "$status" -eq 0 ]
  [ "$(cat "$SUM")" = "$(printf 'etcd 3.6.16 3.6.17\nnginx 1.30.7 1.30.8 changelog')" ]
  [ "$(sed -n 5,7p CHANGELOG.md)" = "$(printf '* **etcd 3.6.17 in the agent image.**\n* **NGINX 1.30.8 in the image** (was 1.30.7).\n* **Something else.**')" ]
  [ "$(value_of docker/Dockerfile ETCD_SHA256_AMD64)" != "$OLD64" ]
}

@test "an entry without pins and with an unchanged version adds nothing" {
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"nginx 1.30.7: unchanged since base, skipped."* ]] || false
  ! grep -q NGINX CHANGELOG.md
}

# The table at base gets one more entry, and the version it names moves.
nopins_error() {
  printf -- "$1" >>.github/checksums.yaml
  git commit -qam "table" && git tag -f base >/dev/null
  bump docker/Dockerfile S3FS_VERSION 1.98
  pin
  [ "$status" -eq 1 ]
  [ -z "$(git status --porcelain)" ]
}

@test "an entry without pins and without a changelog is refused" {
  nopins_error '- name: extra\n  version: docker/Dockerfile#S3FS_VERSION\n'
  [[ "$(cat "$ERR")" == "extra: an entry needs pins or a changelog" ]] || false
}

@test "an entry without pins that names sums or a key is refused" {
  nopins_error '- name: extra\n  version: docker/Dockerfile#S3FS_VERSION\n  sums: https://example.com/v{v}/SHA256SUMS\n  signature: inline\n  changelog: { file: CHANGELOG.md, line: "* extra {v}" }\n'
  [[ "$(cat "$ERR")" == "extra: an entry without pins verifies nothing, but it has: signature, sums" ]] || false
}

@test "an empty list of pins is still refused" {
  nopins_error '- name: extra\n  version: docker/Dockerfile#S3FS_VERSION\n  pins: []\n  changelog: { file: CHANGELOG.md, line: "* extra {v}" }\n'
  [[ "$(cat "$ERR")" == "extra: no pins" ]] || false
}

@test "a changelog of null or false is refused, with and without pins" {
  nopins_error '- name: extra\n  version: docker/Dockerfile#S3FS_VERSION\n  changelog:\n'
  [[ "$(cat "$ERR")" == "extra: changelog must have a file and a line, nothing else" ]] || false
  # Back to the table without the first entry.
  git reset -q --hard base~1
  nopins_error '- name: other\n  version: docker/Dockerfile#S3FS_VERSION\n  changelog: false\n'
  [[ "$(cat "$ERR")" == "other: changelog must have a file and a line, nothing else" ]] || false
}

@test "a changelog of null stops an entry with pins as well" {
  table_error "edit_table '/oras {v}/d' && edit_table '/etcd {v}/d' && edit_table '/NGINX {v}/d' && edit_table '/^    file: CHANGELOG.md/d' && edit_table 's/^  changelog:/  changelog: null/'"
  [[ "$(cat "$ERR")" == "oras: changelog must have a file and a line, nothing else" ]] || false
}
