#!/usr/bin/env bats
# scripts/pin-checksums.sh against the real release files: downloads from
# GitHub, downloads.rclone.org and keys.openpgp.org. The expected sums are the
# ones pinned by hand in the repositories that use these tools.
#
# Runs only with PIN_CHECKSUMS_LIVE=1.

setup() {
  [ "${PIN_CHECKSUMS_LIVE:-}" = 1 ] || skip "set PIN_CHECKSUMS_LIVE=1 to download the real release files"
  unset PIN_CHECKSUMS_TEST_MIRROR
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/pin-checksums.sh"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test.invalid
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test.invalid
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.github/actions/setup-oras" "$REPO/.github/actions/setup-hadolint" "$REPO/docker"
  cd "$REPO"
  git init -q -b main .
  z=0000000000000000000000000000000000000000000000000000000000000000
  printf '    env:\n      ORAS_VERSION: 1.3.6\n      ORAS_SHA256: %s\n' "$z" >.github/actions/setup-oras/action.yml
  printf '    env:\n      HADOLINT_VERSION: 2.15.0\n      HADOLINT_SHA256: %s\n' "$z" >.github/actions/setup-hadolint/action.yml
  printf 'ARG ETCD_VERSION=3.6.16\nARG ETCD_SHA256_AMD64=%s\nARG ETCD_SHA256_ARM64=%s\n' "$z" "$z" >docker/Dockerfile
  printf 'RCLONE_VERSION=1.75.0\nRCLONE_SHA256_AMD64=%s\nRCLONE_SHA256_ARM64=%s\n' "$z" "$z" >docker/rclone.env
  cat >.github/checksums.yaml <<'EOF'
- name: oras
  version: .github/actions/setup-oras/action.yml#ORAS_VERSION
  sums: https://github.com/oras-project/oras/releases/download/v{v}/oras_{v}_checksums.txt
  signature: "{sums}.asc"
  key: C6FC42F0DE84A345FAADB742F44418110791EF37
  key_url: https://raw.githubusercontent.com/oras-project/oras/main/KEYS
  pins:
    - { file: .github/actions/setup-oras/action.yml, var: ORAS_SHA256, asset: "oras_{v}_linux_amd64.tar.gz" }
- name: etcd
  version: docker/Dockerfile#ETCD_VERSION
  sums: https://github.com/etcd-io/etcd/releases/download/v{v}/SHA256SUMS
  pins:
    - { file: docker/Dockerfile, var: ETCD_SHA256_AMD64, asset: "etcd-v{v}-linux-amd64.tar.gz" }
    - { file: docker/Dockerfile, var: ETCD_SHA256_ARM64, asset: "etcd-v{v}-linux-arm64.tar.gz" }
- name: rclone
  version: docker/rclone.env#RCLONE_VERSION
  sums: https://downloads.rclone.org/v{v}/SHA256SUMS
  signature: inline
  key: FBF737ECE9F8AB18604BD2AC93935E02FF3B54FA
  pins:
    - { file: docker/rclone.env, var: RCLONE_SHA256_AMD64, asset: "rclone-v{v}-linux-amd64.zip" }
    - { file: docker/rclone.env, var: RCLONE_SHA256_ARM64, asset: "rclone-v{v}-linux-arm64.zip" }
- name: hadolint
  version: .github/actions/setup-hadolint/action.yml#HADOLINT_VERSION
  sums: https://github.com/hadolint/hadolint/releases/download/v{v}/checksums.sha256
  pins:
    - { file: .github/actions/setup-hadolint/action.yml, var: HADOLINT_SHA256, asset: hadolint-linux-x86_64 }
EOF
  git add -A && git commit -q -m base && git tag base
}

bump() {
  sed -E -i.bak "s/^([[:space:]]*(ARG )?$2(: |=))[^[:space:]]+/\\1$3/" "$1" && rm -f "$1.bak"
  git commit -qam "update $2 to $3"
}

value_of() { grep -E "^[[:space:]]*(ARG )?$2(: |=)" "$1" | sed -E 's/.*(: |=)//'; }

@test "oras 1.4.0: signed by the ORAS release key, the pinned sum" {
  bump .github/actions/setup-oras/action.yml ORAS_VERSION 1.4.0
  run "$SCRIPT" --base base --table-ref base
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified, made by C6FC42F0DE84A345FAADB742F44418110791EF37"* ]] || false
  [ "$(value_of .github/actions/setup-oras/action.yml ORAS_SHA256)" = d8e1dce2fd8ce996f1d901845b688eb0cf505a6082897606f053825bb47935d1 ]
}

@test "etcd 3.6.17: the pinned sums of both architectures" {
  bump docker/Dockerfile ETCD_VERSION 3.6.17
  run "$SCRIPT" --base base --table-ref base
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(value_of docker/Dockerfile ETCD_SHA256_AMD64)" = 5c6365e03d0c81f605458f3f9a115f6daaebca08d1fb42d3ab0f1a38fd30909c ]
  [ "$(value_of docker/Dockerfile ETCD_SHA256_ARM64)" = cb49ad3c3a722957c8ddfd77870539f7db89d00c2a970c014dead2cb62792814 ]
}

@test "rclone 1.76.0: clear-signed by the rclone release key, the pinned sums" {
  bump docker/rclone.env RCLONE_VERSION 1.76.0
  run "$SCRIPT" --base base --table-ref base
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified, made by FBF737ECE9F8AB18604BD2AC93935E02FF3B54FA"* ]] || false
  [ "$(value_of docker/rclone.env RCLONE_SHA256_AMD64)" = b00f00b3266c3764413afe599d3ec316f6f43b3e0ea8a0bc1d186d2133e46df7 ]
  [ "$(value_of docker/rclone.env RCLONE_SHA256_ARM64)" = ee169016675e23a69d77240565133ff7dbc9b33d16fa8f7053d4af39f1eaeb78 ]
}

@test "hadolint 2.15.1: the pinned sum" {
  bump .github/actions/setup-hadolint/action.yml HADOLINT_VERSION 2.15.1
  run "$SCRIPT" --base base --table-ref base
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(value_of .github/actions/setup-hadolint/action.yml HADOLINT_SHA256)" = c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507 ]
}
