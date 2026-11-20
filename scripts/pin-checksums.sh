#!/usr/bin/env bash
# Fills the hash pins that go with a version pin, from the sums a release
# publishes, after checking their PGP signature where the table names a key.
#
# The table (.github/checksums.yaml by default) lists, per tool, where its
# version is pinned, where its sums are published and which variables hold
# which asset's sum; README.md describes the format. For every entry whose
# version differs from the one at --base, the script downloads the sums,
# verifies them, and writes the new values. With a changelog in the entry it
# adds a line under "## Unreleased".
#
# Every check runs before the first write: a failed check leaves the work tree
# as it was, exits 1 and names the reason in --error. A run whose values are
# already in place writes nothing.
#
# Requires bash, git, curl, gpg, jq, shasum and yq (mikefarah, v4).

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true  # bash 4.4+

usage() {
  cat <<'EOF'
Usage: pin-checksums.sh [options]

  -C DIR             The work tree to update (default: the current directory).
  --table PATH       The table, relative to the work tree
                     (default: .github/checksums.yaml).
  --table-ref REV    Read the table from this git revision instead of the
                     work tree, e.g. the base of a pull request.
  --base REV         Process only the entries whose version differs from the
                     one at REV, and add changelog lines only to changelogs
                     that do not differ from REV.
  --all              Process every entry and add no changelog lines.
  --summary FILE     Write one line "<name> <old> <new>" per entry whose pins
                     or changelog changed.
  --error FILE       Write the reason of a failed check to FILE.
  --dry-run          Download and check everything, write nothing.
  -h, --help         Show this help.

Exit status: 0 done (with or without changes), 1 a check failed, 2 usage.
EOF
}

workdir=.
table=.github/checksums.yaml
table_ref=
base=
all=false
summary_file=
error_file=
dry_run=false

die_usage() { echo "pin-checksums: $*" >&2; usage >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -C) [ $# -ge 2 ] || die_usage "-C needs a directory"; workdir=$2; shift 2 ;;
    --table) [ $# -ge 2 ] || die_usage "--table needs a path"; table=$2; shift 2 ;;
    --table-ref) [ $# -ge 2 ] || die_usage "--table-ref needs a revision"; table_ref=$2; shift 2 ;;
    --base) [ $# -ge 2 ] || die_usage "--base needs a revision"; base=$2; shift 2 ;;
    --all) all=true; shift ;;
    --summary) [ $# -ge 2 ] || die_usage "--summary needs a file"; summary_file=$2; shift 2 ;;
    --error) [ $# -ge 2 ] || die_usage "--error needs a file"; error_file=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown option: $1" ;;
  esac
done

if [ -n "$base" ] && [ "$all" = true ]; then die_usage "--base and --all exclude each other"; fi
if [ -z "$base" ] && [ "$all" = false ]; then die_usage "give --base REV or --all"; fi

# Output files given relative to the caller's directory stay there after cd.
abspath() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac; }
[ -z "$summary_file" ] || summary_file=$(abspath "$summary_file")
[ -z "$error_file" ] || error_file=$(abspath "$error_file")
[ -z "$summary_file" ] || : >"$summary_file"
[ -z "$error_file" ] || : >"$error_file"

log() { printf '%s\n' "$*"; }

# Reports a failed check and stops. Called in a command substitution it ends
# only that subshell; every caller checks the status (set -e does it for
# plain assignments).
fail() {
  printf 'pin-checksums: %s\n' "$*" >&2
  [ -z "$error_file" ] || printf '%s\n' "$*" >>"$error_file"
  exit 1
}

for tool in git curl gpg jq shasum yq awk; do
  command -v "$tool" >/dev/null 2>&1 || fail "the tool $tool is missing"
done
yq --version 2>/dev/null | grep -q 'mikefarah' || fail "yq must be mikefarah's yq v4"

cd "$workdir" || fail "no directory $workdir"
root=$(pwd -P)

# A revision that does not resolve is an error, not an empty table or a
# changed version: a mistyped ref or a shallow clone would skip every check.
for rev in "$table_ref" "$base"; do
  [ -z "$rev" ] || git rev-parse --verify --quiet "$rev^{commit}" >/dev/null \
    || fail "the revision $rev is not a commit in $workdir"
done

tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pin-checksums.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- Validation --------------------------------------------------------------

# A path in the table: relative, inside the work tree, no ".." and no
# workflow files (the app that commits has no permission to change them).
check_path() {
  local what=$1 p=$2
  [[ "$p" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "$what: the path '$p' has characters other than letters, digits and ._/-"
  case "/$p/" in
    *//*|*/../*|*/./*) fail "$what: the path '$p' must be plain and relative, without ., .. or //" ;;
  esac
  case "$p" in
    /*) fail "$what: the path '$p' must be relative" ;;
    .git/*) fail "$what: the path '$p' is inside .git" ;;
    .github/workflows/*) fail "$what: the path '$p' is a workflow file, which the app cannot change; move the pin into a local action (.github/actions/)" ;;
  esac
}

# A file the script reads from or writes to: a regular file, no symbolic link,
# and its real path inside the work tree.
check_file() {
  local what=$1 p=$2 real dir
  [ -e "$p" ] || fail "$what: no file $p"
  [ ! -L "$p" ] || fail "$what: $p is a symbolic link"
  [ -f "$p" ] || fail "$what: $p is not a regular file"
  dir=$(cd "$(dirname "$p")" && pwd -P) || fail "$what: cannot resolve $p"
  real="$dir/$(basename "$p")"
  case "$real" in
    "$root"/*) ;;
    *) fail "$what: $p resolves outside the work tree" ;;
  esac
}

check_var() {
  [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "$1: '$2' is not a variable name"
}

# A version as it goes into URLs, asset names and changelog lines.
check_version() {
  [[ "$2" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]] || fail "$1: the version '$2' has characters other than letters, digits and ._+-"
}

# A URL after its placeholders are filled in: https only, plain characters.
check_url() {
  local what=$1 u=$2
  [[ "$u" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/%+=:@,-]*$ ]] || fail "$what: '$u' is not an https URL of plain characters"
  case "$u" in
    *//*//*|*/../*|*/./*) fail "$what: '$u' must not contain //, . or .. segments" ;;
  esac
}

check_fingerprint() {
  [[ "$2" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] || fail "$1: the key '$2' is not a full fingerprint (40 or 64 hex digits)"
}

# Fills {v}, {old}, {name} and {sums} into a template.
fill() {
  local s=$1
  s=${s//\{v\}/$2}
  s=${s//\{old\}/$3}
  s=${s//\{name\}/$4}
  s=${s//\{sums\}/$5}
  printf '%s\n' "$s"
}

# --- Reading and writing a variable ------------------------------------------

# The assignment of a variable on one line: "VAR: value" (YAML), "VAR=value"
# (env file) or "ARG VAR=value" / "export VAR=value"; the value may be quoted.
# Prints line number and value; fails unless there is exactly one.
read_var() {
  local what=$1 file=$2 var=$3 out n
  out=$(awk -v var="$var" '
    {
      if (match($0, "^[[:space:]]*((ARG|export)[[:space:]]+)?" var "[[:space:]]*(=|:[[:space:]])[[:space:]]*[\"\047]?")) {
        rest = substr($0, RSTART + RLENGTH)
        if (match(rest, "^[^\"\047[:space:]#]+")) print NR " " substr(rest, 1, RLENGTH)
        else print NR " "
      }
    }' "$file")
  n=$(printf '%s' "$out" | grep -c . || true)
  [ "$n" -eq 1 ] || fail "$what: $var is assigned $n times in $file, not once"
  printf '%s\n' "$out"
}

# The same for a file at a git revision; prints the value or nothing when the
# file or the variable is not there.
read_var_at() {
  local rev=$1 file=$2 var=$3
  git show "$rev:$file" 2>/dev/null | awk -v var="$var" '
    {
      if (match($0, "^[[:space:]]*((ARG|export)[[:space:]]+)?" var "[[:space:]]*(=|:[[:space:]])[[:space:]]*[\"\047]?")) {
        rest = substr($0, RSTART + RLENGTH)
        if (match(rest, "^[^\"\047[:space:]#]+")) { print substr(rest, 1, RLENGTH); exit }
      }
    }' || true
}

# Replaces the value on line $3 of $1 with $4, keeping everything around it.
write_var() {
  local file=$1 var=$2 line=$3 value=$4
  awk -v var="$var" -v ln="$line" -v value="$value" '
    NR == ln && match($0, "^[[:space:]]*((ARG|export)[[:space:]]+)?" var "[[:space:]]*(=|:[[:space:]])[[:space:]]*[\"\047]?") {
      head = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
      if (match(rest, "^[^\"\047[:space:]#]+")) rest = substr(rest, RLENGTH + 1)
      else if (rest ~ /^#/) rest = " " rest  # an empty value before a comment
      $0 = head value rest
    }
    { print }' "$file" >"$tmp/write" && cat "$tmp/write" >"$file"
}

# --- Downloads and checks ------------------------------------------------------

# PIN_CHECKSUMS_TEST_MIRROR serves https://host/path from DIR/host/path, for
# the tests; the workflow never sets it.
fetch() {
  local url=$1 dest=$2 max=${3:-10485760}
  if [ -n "${PIN_CHECKSUMS_TEST_MIRROR:-}" ]; then
    cp "$PIN_CHECKSUMS_TEST_MIRROR/${url#https://}" "$dest" 2>/dev/null
    return
  fi
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
    --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 \
    --max-filesize "$max" -o "$dest" "$url" 2>"$tmp/curl.err"
}

hash_file() { shasum -a "${2#sha}" "$1" | awk '{print tolower($1)}'; }

gpg_() { gpg --batch --no-tty --no-autostart --no-auto-key-retrieve --homedir "$tmp/gnupg" "$@"; }

# Imports the key into an empty keyring and checks the fingerprint is in it.
import_key() {
  local what=$1 key=$2 key_url=$3 url
  rm -rf "$tmp/gnupg"; mkdir -m 700 "$tmp/gnupg"
  url=${key_url:-https://keys.openpgp.org/vks/v1/by-fingerprint/$key}
  check_url "$what: key" "$url"
  fetch "$url" "$tmp/key" 1048576 || fail "$what: cannot download the key from $url"
  gpg_ --import "$tmp/key" >/dev/null 2>&1 || fail "$what: $url holds no OpenPGP key"
  gpg_ --with-colons --fingerprint --fingerprint 2>/dev/null | awk -F: '$1 == "fpr" {print $10}' | grep -qx "$key" \
    || fail "$what: the key $key is not in $url"
}

# Checks the status lines of a verification: a good signature, none bad, made
# by the key (primary or subkey) the table names.
check_status() {
  local what=$1 key=$2 status=$3
  if grep -qE '^\[GNUPG:\] (BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY)( |$)' "$status" \
     || ! grep -q '^\[GNUPG:\] GOODSIG ' "$status"; then
    fail "$what: the signature does not verify against $key"
  fi
  awk '$2 == "VALIDSIG" { print $3; if ($12 != "") print $12 }' "$status" | grep -qx "$key" \
    || fail "$what: the signature is not made by $key"
}

# Downloads the sums and leaves their verified text in $tmp/sums.txt.
get_sums() {
  local what=$1 sums_url=$2 sig=$3 key=$4 key_url=$5
  fetch "$sums_url" "$tmp/sums" || fail "$what: cannot download the sums from $sums_url"
  if [ -z "$sig" ]; then
    cp "$tmp/sums" "$tmp/sums.txt"
    return
  fi
  import_key "$what" "$key" "$key_url"
  if [ "$sig" = inline ]; then
    # One clear-signed message and nothing around it: text outside the
    # signature would not be covered by it.
    [ "$(sed -n '/./{p;q;}' "$tmp/sums" | tr -d '\r')" = "-----BEGIN PGP SIGNED MESSAGE-----" ] \
      && [ "$(grep -c '^-----BEGIN PGP SIGNED MESSAGE-----' "$tmp/sums")" -eq 1 ] \
      && [ "$(grep -c '^-----END PGP SIGNATURE-----' "$tmp/sums")" -eq 1 ] \
      && [ "$(grep -v '^[[:space:]]*$' "$tmp/sums" | tail -n 1 | tr -d '\r')" = "-----END PGP SIGNATURE-----" ] \
      || fail "$what: $sums_url is not a single clear-signed message"
    rm -f "$tmp/sums.txt"
    gpg_ --status-file "$tmp/status" --output "$tmp/sums.txt" --decrypt "$tmp/sums" >/dev/null 2>&1 || true
    check_status "$what" "$key" "$tmp/status"
  else
    check_url "$what: signature" "$sig"
    fetch "$sig" "$tmp/sig" 1048576 || fail "$what: cannot download the signature from $sig"
    gpg_ --status-file "$tmp/status" --verify "$tmp/sig" "$tmp/sums" >/dev/null 2>&1 || true
    check_status "$what" "$key" "$tmp/status"
    cp "$tmp/sums" "$tmp/sums.txt"
  fi
}

# The sum of one asset in "<sum>  <name>" or "<sum> *<name>" lines.
sum_of() {
  local what=$1 asset=$2 len=$3 found n
  found=$(tr -d '\r' <"$tmp/sums.txt" | awk -v asset="$asset" -v len="$len" '
    NF == 2 && length($1) == len && $1 ~ /^[0-9a-fA-F]+$/ {
      n = $2; sub(/^\*/, "", n); sub(/^\.\//, "", n)
      if (n == asset) print tolower($1)
    }' | sort -u)
  n=$(printf '%s' "$found" | grep -c . || true)
  [ "$n" -eq 1 ] || {
    if [ "$n" -eq 0 ]; then fail "$what: no sum for $asset in the sums"; fi
    fail "$what: different sums for $asset in the sums"
  }
  printf '%s\n' "$found"
}

# --- The table -----------------------------------------------------------------

check_path "table" "$table"
if [ -n "$table_ref" ]; then
  git cat-file -e "$table_ref:$table" 2>/dev/null || { log "No $table at $table_ref: nothing to do."; exit 0; }
  git show "$table_ref:$table" >"$tmp/table.yaml"
else
  [ -e "$table" ] || { log "No $table: nothing to do."; exit 0; }
  check_file "table" "$table"
  cp "$table" "$tmp/table.yaml"
fi
yq -o=json '.' "$tmp/table.yaml" >"$tmp/table.json" 2>/dev/null || fail "$table is not valid YAML"
jq -e 'type == "array" and all(.[]; type == "object")' "$tmp/table.json" >/dev/null \
  || fail "$table must be a list of entries"

known='["name","version","sums","signature","key","key_url","algorithm","pins","changelog"]'
count=$(jq length "$tmp/table.json")

# Planned writes: "<file>\t<var>\t<value>\t<entry>" and "<file>\t<line>\t<entry>".
: >"$tmp/plan"
: >"$tmp/changelog-plan"
: >"$tmp/entries"

for ((i = 0; i < count; i++)); do
  e=$(jq -c ".[$i]" "$tmp/table.json")
  name=$(jq -r '.name // empty | strings' <<<"$e")
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "entry $((i + 1)): name must be letters, digits and ._-"
  what=$name
  extra=$(jq -r --argjson known "$known" 'keys - $known | join(", ")' <<<"$e")
  [ -z "$extra" ] || fail "$what: unknown keys: $extra"

  version_spec=$(jq -r '.version // empty | strings' <<<"$e")
  [[ "$version_spec" == *'#'* ]] || fail "$what: version must be <file>#<variable>"
  vfile=${version_spec%%#*}
  vvar=${version_spec#*#}
  check_path "$what: version" "$vfile"
  check_var "$what: version" "$vvar"
  check_file "$what: version" "$vfile"
  new=$(read_var "$what: version" "$vfile" "$vvar" | cut -d' ' -f2)
  check_version "$what" "$new"

  old=
  if [ -n "$base" ]; then
    old=$(read_var_at "$base" "$vfile" "$vvar")
    if [ "$old" = "$new" ]; then
      log "$what $new: unchanged since $base, skipped."
      continue
    fi
    [ -z "$old" ] || check_version "$what (at $base)" "$old"
  fi

  algorithm=$(jq -r '.algorithm // "sha256" | strings' <<<"$e")
  case "$algorithm" in
    sha256) len=64 ;;
    sha512) len=128 ;;
    *) fail "$what: algorithm must be sha256 or sha512" ;;
  esac

  sums_t=$(jq -r '.sums // empty | strings' <<<"$e")
  sig_t=$(jq -r '.signature // empty | strings' <<<"$e")
  key=$(jq -r '.key // empty | strings' <<<"$e" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
  key_url=$(jq -r '.key_url // empty | strings' <<<"$e")
  sums_url=
  if [ -n "$sums_t" ]; then
    sums_url=$(fill "$sums_t" "$new" "$old" "$name" "")
    check_url "$what: sums" "$sums_url"
  fi
  sig=
  if [ -n "$sig_t" ]; then
    [ -n "$sums_url" ] || fail "$what: a signature needs sums"
    check_fingerprint "$what" "$key"
    if [ "$sig_t" = inline ]; then sig=inline; else sig=$(fill "$sig_t" "$new" "$old" "$name" "$sums_url"); fi
    [ -z "$key_url" ] || check_url "$what: key_url" "$key_url"
  else
    [ -z "$key" ] && [ -z "$key_url" ] || fail "$what: a key needs a signature"
  fi

  pins=$(jq -c '.pins // [] | if type == "array" then . else error("pins") end' <<<"$e" 2>/dev/null) \
    || fail "$what: pins must be a list"
  npins=$(jq length <<<"$pins")
  [ "$npins" -gt 0 ] || fail "$what: no pins"

  log "$what ${old:-(new)} -> $new"
  [ -z "$sums_url" ] || get_sums "$what" "$sums_url" "$sig" "$key" "$key_url"
  if [ -n "$sig" ]; then log "  signature of $sums_url verified, made by $key"; fi

  for ((j = 0; j < npins; j++)); do
    p=$(jq -c ".[$j]" <<<"$pins")
    extra=$(jq -r 'keys - ["file","var","asset","url"] | join(", ")' <<<"$p")
    [ -z "$extra" ] || fail "$what: pin $((j + 1)): unknown keys: $extra"
    pfile=$(jq -r '.file // empty | strings' <<<"$p")
    pvar=$(jq -r '.var // empty | strings' <<<"$p")
    asset_t=$(jq -r '.asset // empty | strings' <<<"$p")
    url_t=$(jq -r '.url // empty | strings' <<<"$p")
    check_path "$what: pin $pvar" "$pfile"
    check_var "$what: pin" "$pvar"
    check_file "$what: pin $pvar" "$pfile"
    read_var "$what: pin" "$pfile" "$pvar" >/dev/null
    if [ -n "$asset_t" ] && [ -z "$url_t" ]; then
      [ -n "$sums_url" ] || fail "$what: pin $pvar names an asset, but the entry has no sums"
      asset=$(fill "$asset_t" "$new" "$old" "$name" "")
      [[ "$asset" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "$what: pin $pvar: the asset '$asset' has characters other than letters, digits and ._+-"
      value=$(sum_of "$what" "$asset" "$len")
      log "  $pvar in $pfile: $asset"
    elif [ -n "$url_t" ] && [ -z "$asset_t" ]; then
      # No published sums: the sum of the download itself, as by hand.
      url=$(fill "$url_t" "$new" "$old" "$name" "")
      check_url "$what: pin $pvar" "$url"
      fetch "$url" "$tmp/download" 524288000 || fail "$what: cannot download $url"
      value=$(hash_file "$tmp/download" "$algorithm")
      log "  $pvar in $pfile: $algorithm of $url"
    else
      fail "$what: pin $pvar needs either asset or url"
    fi
    [[ "$value" =~ ^[0-9a-f]+$ ]] && [ "${#value}" -eq "$len" ] || fail "$what: pin $pvar: no $algorithm sum"
    printf '%s\t%s\t%s\t%s\n' "$pfile" "$pvar" "$value" "$name" >>"$tmp/plan"
  done

  cl=$(jq -c '.changelog // empty' <<<"$e")
  if [ -n "$cl" ]; then
    jq -e 'type == "object" and (keys - ["file","line"] | length == 0) and (.file|type) == "string" and (.line|type) == "string"' <<<"$cl" >/dev/null \
      || fail "$what: changelog must have a file and a line, nothing else"
    cfile=$(jq -r .file <<<"$cl")
    check_path "$what: changelog" "$cfile"
    check_file "$what: changelog" "$cfile"
    cline=$(fill "$(jq -r .line <<<"$cl")" "$new" "$old" "$name" "")
    case "$cline" in *$'\n'*|*$'\r'*|'') fail "$what: the changelog line must be one line" ;; esac
    [ "${#cline}" -le 500 ] || fail "$what: the changelog line is longer than 500 characters"
    if [ "$all" = true ]; then
      log "  changelog: --all adds no lines"
    else
      printf '%s\t%s\t%s\n' "$cfile" "$cline" "$name" >>"$tmp/changelog-plan"
    fi
  fi
  printf '%s %s %s\n' "$name" "${old:--}" "$new" >>"$tmp/entries"
done

# Two pins of the same variable must agree.
conflict=$(awk -F'\t' '{ k = $1 "\t" $2; if (k in v && v[k] != $3) print $2 " in " $1; v[k] = $3 }' "$tmp/plan" | head -n 1)
[ -z "$conflict" ] || fail "two entries set different values for $conflict"

if [ ! -s "$tmp/entries" ]; then
  log "No version changed: nothing to do."
  exit 0
fi

if [ "$dry_run" = true ]; then
  log "Dry run: all checks passed, nothing written."
  exit 0
fi

# --- Writing -------------------------------------------------------------------

: >"$tmp/changed-entries"

# Changelogs changed in the pull request already have their line, written by an
# earlier run or by hand; decided before anything is written.
: >"$tmp/changelog-skip"
if [ -n "$base" ]; then
  cut -f1 "$tmp/changelog-plan" | sort -u | while IFS= read -r f; do
    [ -n "$f" ] || continue
    git diff --quiet "$base" -- "$f" 2>/dev/null || printf '%s\n' "$f" >>"$tmp/changelog-skip"
  done
fi

while IFS=$'\t' read -r pfile pvar value entry; do
  current=$(read_var "$entry: pin" "$pfile" "$pvar")
  line=${current%% *}
  if [ "${current#* }" = "$value" ]; then
    log "$pvar in $pfile is already $value"
    continue
  fi
  write_var "$pfile" "$pvar" "$line" "$value"
  log "$pvar in $pfile set to $value"
  printf '%s\n' "$entry" >>"$tmp/changed-entries"
done < <(sort -u "$tmp/plan")

# Inserts a line as the first item under "## Unreleased", or a new section with
# it above the first "## " heading (at the end when there is none).
add_changelog_line() {
  local file=$1 text=$2 has=0
  if grep -q '^## Unreleased[[:space:]]*$' "$file"; then has=1; fi
  PIN_TEXT=$text awk -v has="$has" '
    BEGIN { text = ENVIRON["PIN_TEXT"] }
    # After the new item: a list item follows directly, anything else after a
    # blank line.
    function follow(l) {
      if (l !~ /^[[:space:]]*$/ && l !~ /^[*+-] /) print ""
      print l
    }
    !done && has && /^## Unreleased[[:space:]]*$/ {
      print; print ""; print text
      if ((getline l) > 0 && l ~ /^[[:space:]]*$/) {
        if ((getline l) > 0) follow(l)
      } else if (l != "") follow(l)
      done = 1; next
    }
    !done && !has && /^## / { print "## Unreleased"; print ""; print text; print ""; print; done = 1; next }
    { print }
    END { if (!done) { print ""; print "## Unreleased"; print ""; print text } }' "$file" >"$tmp/changelog" && cat "$tmp/changelog" >"$file"
}

while IFS=$'\t' read -r cfile cline entry; do
  [ -n "$cfile" ] || continue
  if grep -qxF "$cfile" "$tmp/changelog-skip"; then
    log "$cfile already changed in this pull request: no line for $entry"
    continue
  fi
  if grep -qxF -- "$cline" "$cfile"; then
    log "$cfile already has the line for $entry"
    continue
  fi
  add_changelog_line "$cfile" "$cline"
  log "$cfile: added \"$cline\""
  printf '%s\n' "$entry" >>"$tmp/changed-entries"
# Each line goes on top: in reverse, so that they end up in the table's order.
done < <(awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' "$tmp/changelog-plan")

if [ -n "$summary_file" ]; then
  while read -r name old new; do
    if grep -qxF "$name" "$tmp/changed-entries"; then printf '%s %s %s\n' "$name" "$old" "$new"; fi
  done <"$tmp/entries" >"$summary_file"
fi

if [ -s "$tmp/changed-entries" ]; then
  log "Done: $(sort -u "$tmp/changed-entries" | tr '\n' ' ')"
else
  log "All values already in place: nothing written."
fi
