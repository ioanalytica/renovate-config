#!/usr/bin/env bats
# scripts/api-commit.sh (dry run) and scripts/pr-comment.sh against a fake gh.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test.invalid
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test.invalid
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/docker"
  cd "$REPO"
  git init -q -b main .
  printf 'ARG A_SHA256=0\n' >docker/Dockerfile
  printf '# Changelog\n' >CHANGELOG.md
  git add -A && git commit -qm base
  HEAD_SHA=$(git rev-parse HEAD)
  printf 'Pin the checksums of etcd 3.6.17\n\nVerified.\n\nSigned-off-by: app[bot] <1+app[bot]@users.noreply.github.com>\n' >"$BATS_TEST_TMPDIR/message"
}

commit() {
  run "$ROOT/scripts/api-commit.sh" --repo owner/name --branch renovate/etcd --expected-head "$HEAD_SHA" \
    --message-file "$BATS_TEST_TMPDIR/message" --dry-run "$@"
}

@test "api-commit: the request carries the modified files, the head and the message" {
  printf 'ARG A_SHA256=1\n' >docker/Dockerfile
  printf '# Changelog\n\n## Unreleased\n' >CHANGELOG.md
  commit
  [ "$status" -eq 0 ]
  input=$(jq '.variables.input' <<<"$output")
  [ "$(jq -r .expectedHeadOid <<<"$input")" = "$HEAD_SHA" ]
  [ "$(jq -r .branch.branchName <<<"$input")" = renovate/etcd ]
  [ "$(jq -r .branch.repositoryNameWithOwner <<<"$input")" = owner/name ]
  [ "$(jq -r .message.headline <<<"$input")" = "Pin the checksums of etcd 3.6.17" ]
  [ "$(jq -r .message.body <<<"$input")" = "$(printf 'Verified.\n\nSigned-off-by: app[bot] <1+app[bot]@users.noreply.github.com>')" ]
  [ "$(jq -r '.fileChanges.additions | map(.path) | join(" ")' <<<"$input")" = "CHANGELOG.md docker/Dockerfile" ]
  [ "$(jq -r '.fileChanges.additions[1].contents' <<<"$input" | base64 -d)" = "ARG A_SHA256=1" ]
  [[ "$(jq -r .query <<<"$output")" == *createCommitOnBranch* ]]
}

@test "api-commit: nothing modified, nothing to commit" {
  commit
  [ "$status" -eq 0 ]
  [ "$output" = "Nothing to commit." ]
}

@test "api-commit: a new file stops it" {
  printf 'x\n' >new.txt
  commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"only modified files can be committed, not '??' new.txt"* ]]
}

@test "api-commit: a work tree at another commit stops it" {
  git commit -q --allow-empty -m later
  printf 'ARG A_SHA256=1\n' >docker/Dockerfile
  commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"the work tree is not at $HEAD_SHA"* ]]
}

# A fake gh: logs each call, answers from $FAKE_GH_DIR.
fake_gh() {
  FAKE_GH_DIR="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$FAKE_GH_DIR/bin"
  cat >"$FAKE_GH_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_DIR/calls"
input=
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = --input ]; then j=$((i + 1)); input=${!j}; fi
done
if [ -n "$input" ]; then
  if [ "$input" = - ]; then cat >>"$FAKE_GH_DIR/inputs"; else cat "$input" >>"$FAKE_GH_DIR/inputs"; fi
  exit 0
fi
case "$*" in
  *"/issues/7/comments --jq"*) cat "$FAKE_GH_DIR/ids" 2>/dev/null || true ;;
  *"issues/comments/42 --jq .body"*) cat "$FAKE_GH_DIR/body" ;;
esac
SH
  chmod +x "$FAKE_GH_DIR/bin/gh"
  export FAKE_GH_DIR PATH="$FAKE_GH_DIR/bin:$PATH"
}

@test "pr-comment: a first report is a new comment with the marker" {
  fake_gh
  printf 'The signature does not verify.\n' >"$BATS_TEST_TMPDIR/body"
  run "$ROOT/scripts/pr-comment.sh" --repo owner/name --pr 7 --body-file "$BATS_TEST_TMPDIR/body"
  [ "$status" -eq 0 ]
  grep -q '^api --method POST repos/owner/name/issues/7/comments' "$FAKE_GH_DIR/calls"
  [ "$(jq -r .body "$FAKE_GH_DIR/inputs")" = "$(printf '<!-- pin-checksums -->\nThe signature does not verify.')" ]
}

@test "pr-comment: a later report replaces the earlier comment" {
  fake_gh
  echo 42 >"$FAKE_GH_DIR/ids"
  printf 'Still failing.\n' >"$BATS_TEST_TMPDIR/body"
  run "$ROOT/scripts/pr-comment.sh" --repo owner/name --pr 7 --body-file "$BATS_TEST_TMPDIR/body"
  [ "$status" -eq 0 ]
  grep -q '^api --method PATCH repos/owner/name/issues/comments/42' "$FAKE_GH_DIR/calls"
  ! grep -q 'POST' "$FAKE_GH_DIR/calls"
}

@test "pr-comment: resolve replaces an earlier comment once, and needs none" {
  fake_gh
  run "$ROOT/scripts/pr-comment.sh" --repo owner/name --pr 7 --resolve "Resolved."
  [ "$status" -eq 0 ]
  ! grep -q 'PATCH\|POST' "$FAKE_GH_DIR/calls"
  echo 42 >"$FAKE_GH_DIR/ids"
  printf '<!-- pin-checksums -->\nfailed\n' >"$FAKE_GH_DIR/body"
  run "$ROOT/scripts/pr-comment.sh" --repo owner/name --pr 7 --resolve "Resolved."
  [ "$status" -eq 0 ]
  [ "$(jq -r .body "$FAKE_GH_DIR/inputs")" = "$(printf '<!-- pin-checksums -->\nResolved.')" ]
  printf '<!-- pin-checksums -->\nResolved.\n' >"$FAKE_GH_DIR/body"
  : >"$FAKE_GH_DIR/calls"
  run "$ROOT/scripts/pr-comment.sh" --repo owner/name --pr 7 --resolve "Resolved."
  [ "$status" -eq 0 ]
  ! grep -q 'PATCH' "$FAKE_GH_DIR/calls"
}

@test "pr-comment: an author that is not a login is refused" {
  run "$ROOT/scripts/pr-comment.sh" --repo owner/name --pr 7 --resolve x --author 'a" or true'
  [ "$status" -eq 2 ]
}

@test "the example table has only known keys" {
  run yq -o=json '.' "$ROOT/examples/checksums.yaml"
  [ "$status" -eq 0 ]
  jq -e 'all(.[]; (keys - ["name","version","sums","signature","key","key_url","algorithm","pins","changelog"]) == []
         and all(.pins[]; (keys - ["file","var","asset","url"]) == []))' <<<"$output"
}
