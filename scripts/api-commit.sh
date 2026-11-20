#!/usr/bin/env bash
# Commits the modified files of a work tree to a branch through GitHub's
# GraphQL API (createCommitOnBranch). GitHub signs such a commit, it starts
# the branch's workflows like any push, and the token's app becomes its
# author and the branch's last pusher.
#
# The commit is made only on top of --expected-head: when the branch moved in
# the meantime, GitHub refuses it and the next run on the new head takes over.
# Only modified tracked files are committed; a new, deleted or renamed file
# stops it.
#
# Requires bash, git, jq, base64 and, without --dry-run, gh with GH_TOKEN.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: api-commit.sh --repo OWNER/NAME --branch BRANCH --expected-head SHA
                     --message-file FILE [-C DIR] [--dry-run]

  --message-file FILE  First line: the headline; after a blank line: the body.
  --dry-run            Print the GraphQL request instead of sending it.
EOF
}

workdir=.
repo=
branch=
head=
message_file=
dry_run=false

die_usage() { echo "api-commit: $*" >&2; usage >&2; exit 2; }
fail() { echo "api-commit: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -C) [ $# -ge 2 ] || die_usage "-C needs a directory"; workdir=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || die_usage "--repo needs OWNER/NAME"; repo=$2; shift 2 ;;
    --branch) [ $# -ge 2 ] || die_usage "--branch needs a name"; branch=$2; shift 2 ;;
    --expected-head) [ $# -ge 2 ] || die_usage "--expected-head needs a commit"; head=$2; shift 2 ;;
    --message-file) [ $# -ge 2 ] || die_usage "--message-file needs a file"; message_file=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown option: $1" ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die_usage "--repo must be OWNER/NAME"
[ -n "$branch" ] || die_usage "--branch is missing"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || die_usage "--expected-head must be a full commit SHA"
[ -f "$message_file" ] || die_usage "--message-file is missing"

headline=$(head -n 1 "$message_file")
body=$(tail -n +3 "$message_file")
[ -n "$headline" ] || fail "the message has no headline"

cd "$workdir"
[ "$(git rev-parse HEAD)" = "$head" ] || fail "the work tree is not at $head"

tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/api-commit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Porcelain v1 with -z: "XY path\0"; only " M" (modified, not staged) is fine.
echo '[]' >"$tmp/additions.json"
count=0
while IFS= read -r -d '' entry; do
  status=${entry:0:2}
  path=${entry:3}
  [ "$status" = " M" ] || fail "only modified files can be committed, not '$status' $path"
  [ -f "$path" ] && [ ! -L "$path" ] || fail "$path is not a regular file"
  base64 <"$path" | tr -d '\n' >"$tmp/contents"
  jq --arg path "$path" --rawfile contents "$tmp/contents" \
    '. + [{path: $path, contents: $contents}]' "$tmp/additions.json" >"$tmp/next.json"
  mv "$tmp/next.json" "$tmp/additions.json"
  count=$((count + 1))
done < <(git status --porcelain=v1 -z --untracked-files=all)

if [ "$count" -eq 0 ]; then
  echo "Nothing to commit."
  exit 0
fi

jq -n \
  --arg query 'mutation ($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }' \
  --arg repo "$repo" --arg branch "$branch" --arg head "$head" \
  --arg headline "$headline" --arg body "$body" \
  --slurpfile additions "$tmp/additions.json" \
  '{query: $query, variables: {input: {
      branch: {repositoryNameWithOwner: $repo, branchName: $branch},
      expectedHeadOid: $head,
      message: ({headline: $headline} + (if $body == "" then {} else {body: $body} end)),
      fileChanges: {additions: $additions[0]}
    }}}' >"$tmp/request.json"

if [ "$dry_run" = true ]; then
  cat "$tmp/request.json"
  exit 0
fi

gh api graphql --input "$tmp/request.json" >"$tmp/response.json" \
  || fail "GitHub refused the commit (the branch may have moved since $head): $(jq -c '.errors // .' "$tmp/response.json" 2>/dev/null || true)"
oid=$(jq -r '.data.createCommitOnBranch.commit.oid // empty' "$tmp/response.json")
[ -n "$oid" ] || fail "no commit in GitHub's answer: $(jq -c . "$tmp/response.json")"
echo "Committed $count file(s) to $branch as $oid"
