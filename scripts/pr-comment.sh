#!/usr/bin/env bash
# Keeps one comment of the pin-checksums workflow on a pull request: a failed
# check writes or replaces it, a later successful run marks it resolved.
# The comment is found by a hidden marker and by its author, the token's user.
#
# Requires bash, jq and gh with GH_TOKEN.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: pr-comment.sh --repo OWNER/NAME --pr NUMBER (--body-file FILE | --resolve TEXT)
                     [--author LOGIN]

  --body-file FILE  Write the comment with this body (replacing an earlier one).
  --resolve TEXT    Replace an earlier comment, if there is one, with TEXT.
  --author LOGIN    The login the comments are made as
                    (default: github-actions[bot], the login of GITHUB_TOKEN).
EOF
}

repo=
pr=
body_file=
resolve=
author='github-actions[bot]'
marker='<!-- pin-checksums -->'

die_usage() { echo "pr-comment: $*" >&2; usage >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die_usage "--repo needs OWNER/NAME"; repo=$2; shift 2 ;;
    --pr) [ $# -ge 2 ] || die_usage "--pr needs a number"; pr=$2; shift 2 ;;
    --body-file) [ $# -ge 2 ] || die_usage "--body-file needs a file"; body_file=$2; shift 2 ;;
    --resolve) [ $# -ge 2 ] || die_usage "--resolve needs a text"; resolve=$2; shift 2 ;;
    --author) [ $# -ge 2 ] || die_usage "--author needs a login"; author=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown option: $1" ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die_usage "--repo must be OWNER/NAME"
[[ "$pr" =~ ^[0-9]+$ ]] || die_usage "--pr must be a number"
[[ "$author" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]] || die_usage "--author must be a login"
if [ -n "$body_file" ] && [ -n "$resolve" ]; then die_usage "--body-file and --resolve exclude each other"; fi
if [ -z "$body_file" ] && [ -z "$resolve" ]; then die_usage "give --body-file or --resolve"; fi

existing=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
  --jq ".[] | select(.user.login == \"$author\" and (.body | startswith(\"$marker\"))) | .id" | head -n 1)

if [ -n "$resolve" ]; then
  [ -n "$existing" ] || exit 0
  current=$(gh api "repos/$repo/issues/comments/$existing" --jq .body)
  new=$(printf '%s\n%s\n' "$marker" "$resolve")
  [ "$current" != "$new" ] || exit 0
  jq -n --arg body "$new" '{body: $body}' | gh api --method PATCH "repos/$repo/issues/comments/$existing" --input - >/dev/null
  echo "Marked comment $existing resolved."
  exit 0
fi

request=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pr-comment.XXXXXX")
trap 'rm -f "$request"' EXIT
jq -n --arg marker "$marker" --rawfile text "$body_file" '{body: ($marker + "\n" + $text)}' >"$request"
if [ -n "$existing" ]; then
  gh api --method PATCH "repos/$repo/issues/comments/$existing" --input "$request" >/dev/null
  echo "Updated comment $existing."
else
  gh api --method POST "repos/$repo/issues/$pr/comments" --input "$request" >/dev/null
  echo "Commented on #$pr."
fi
