# renovate-config

The shared Renovate setup of the ioanalytica repositories:

- **`default.json`**, a Renovate preset: one pull request per update, each with a
  review request, no update that waits on the Dependency Dashboard, and security
  fixes at any time.
- **`.github/workflows/pin-checksums.yml`**, a reusable workflow: on a Renovate
  pull request it fills the hash pins that go with a version pin, from the sums
  the release publishes and after checking their PGP signature, and adds a
  CHANGELOG line. It commits through a GitHub App, so the pull request is green
  and reviewable without a hand-made commit.

There is no automerge: every update stays a pull request that a person merges.

## The preset

A repository's `.github/renovate.json` (or `renovate.json`) extends it and keeps
its own managers, groups and notes:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>ioanalytica/renovate-config"],
  "packageRules": []
}
```

`github>ioanalytica/renovate-config` reads `default.json` from the default
branch; `github>ioanalytica/renovate-config#v1.0.0` reads it from a tag.

What it sets:

| Setting | Value | Why |
|---|---|---|
| `extends` | `config:recommended`, `helpers:pinGitHubActionDigestsToSemver` | Actions pinned by commit, with the version as a comment. |
| `schedule`, `timezone` | Mondays 0–5 h, Europe/Berlin | One batch a week. |
| `minimumReleaseAge` | 3 days, none for digests | A release that is pulled again in its first days never reaches a pull request. A digest has no release date, and with the default `minimumReleaseAgeBehaviour` its status `renovate/stability-days` would stay pending for good. |
| `rebaseWhen` | `conflicted` | No rebase and no new CI run for every commit on the base branch. |
| `semanticCommits` | `enabled` | A repository without them sets `"disabled"`. |
| `commitBody` | `Signed-off-by: {{{gitAuthor}}}` | DCO. |
| `configMigration` | `true` | Renovate proposes the migration of a config whose options it renamed. |
| `prConcurrentLimit`, `prHourlyLimit` | `0` (no limit) | No update waits as "rate-limited" on the dashboard. Groups and schedules keep the number of pull requests small. |
| `reviewers` | `ioanalytica` | Every pull request requests a review, which notifies on its own. |
| `osvVulnerabilityAlerts` | `true` | Fixes for vulnerabilities in the OSV database. |
| `vulnerabilityAlerts` | any time, no minimum age, label `security` | A security fix comes at once, not on the next Monday after three days. |
| label `decision` | majors; a new digest under an unchanged action tag | The updates that used to wait for approval on the dashboard now come as pull requests that say they need a decision. |

The Dependency Dashboard stays as an inventory, but nothing waits on it.

### What changed against the per-repository configs

- **No `dependencyDashboardApproval`.** A major, a new etcd minor, a new
  MariaDB, MySQL, NGINX or Alpine series, a moved action tag or an s3fs release
  used to appear only on the dashboard until someone ticked it. Now each is a
  pull request with the label `decision` (the preset adds it to majors and
  moved action tags; a repository adds it to its own deliberate moves with
  `"addLabels": ["decision"]` in place of `"dependencyDashboardApproval": true`).
  Closing the pull request declines that version; Renovate proposes the next one.
  The preset cannot remove a repository's own `dependencyDashboardApproval`
  rules: each repository drops them when it switches to the preset.
- **No limits.** The repositories had `prConcurrentLimit` 5 or 10, and Renovate's
  default hourly limit of 2 hid updates as "rate-limited" on the dashboard.
- **Review requests** for every pull request.
- **Security fixes at any time**, from GitHub's advisories (Dependabot alerts
  must be on in the repository's settings) and from OSV.
- **Hash pins are filled by the workflow below**, not by hand. The
  `prBodyNotes` that said which sum to copy from where move into the table
  `.github/checksums.yaml`.
- **The CHANGELOG line** of an image or tool update is written by the workflow
  when the table entry names a changelog.
- **The same baseline everywhere.** A repository that had only
  `config:recommended` gets the weekly schedule, the minimum age, the DCO
  sign-off and the review requests.

Repositories keep in their own config: their managers and custom managers,
`ignorePaths`, groups, monthly schedules, `prBodyNotes`, the rules that disable
a dependency, and `semanticCommits: "disabled"` where they do not use them.

## The pin-checksums workflow

### Use

Two files in the repository, plus the two secrets of the GitHub App below.

`.github/workflows/pin-checksums.yml`, the caller
([examples/pin-checksums-caller.yml](examples/pin-checksums-caller.yml)):

```yaml
name: Pin checksums

on:
  pull_request:

permissions: {}

jobs:
  pin-checksums:
    if: startsWith(github.head_ref, 'renovate/')
    uses: ioanalytica/renovate-config/.github/workflows/pin-checksums.yml@<commit-sha> # v1.0.0
    permissions:
      contents: read
      id-token: write
      pull-requests: write
    secrets:
      RENOVATE_HELPER_APP_ID: ${{ secrets.RENOVATE_HELPER_APP_ID }}
      RENOVATE_HELPER_PRIVATE_KEY: ${{ secrets.RENOVATE_HELPER_PRIVATE_KEY }}
```

- `contents: read` checks out the pull request; the commit itself uses the
  app's token.
- `id-token: write` only lets the job read which commit of this repository it
  runs from (the OIDC token's `job_workflow_sha`), so that its scripts come from
  the same commit as the workflow. The token is not sent anywhere.
- `pull-requests: write` lets `GITHUB_TOKEN` comment when a check fails.

The workflow is not meant to be a required check: the repository's own checks
fail while a pin is wrong.

`.github/checksums.yaml`, the table
([examples/checksums.yaml](examples/checksums.yaml) has one entry of every kind):

```yaml
- name: oras
  version: .github/actions/setup-oras/action.yml#ORAS_VERSION
  sums: https://github.com/oras-project/oras/releases/download/v{v}/oras_{v}_checksums.txt
  signature: "{sums}.asc"
  key: C6FC42F0DE84A345FAADB742F44418110791EF37
  key_url: https://raw.githubusercontent.com/oras-project/oras/main/KEYS
  pins:
    - file: .github/actions/setup-oras/action.yml
      var: ORAS_SHA256
      asset: oras_{v}_linux_amd64.tar.gz
  changelog:
    file: CHANGELOG.md
    line: "* **oras {v}** for the release jobs (was {old})."
```

| Key | | Meaning |
|---|---|---|
| `name` | required | The tool's name, in messages and the commit. |
| `version` | required | `<file>#<VARIABLE>`: where the version is pinned. |
| `sums` | for `asset` pins | URL of the release's sums: lines `<sum>  <name>` or `<sum> *<name>`. |
| `signature` | optional | URL of a detached signature of the sums, or `inline` for clear-signed sums. |
| `key` | with `signature` | The full fingerprint (40 or 64 hex digits, spaces allowed) of the key that must have made the signature, primary key or subkey. |
| `key_url` | optional | Where to get the key, e.g. the project's KEYS file. Default: `https://keys.openpgp.org/vks/v1/by-fingerprint/<key>`. |
| `algorithm` | optional | `sha256` (default) or `sha512`. |
| `pins` | required | The variables to fill: `file`, `var`, and either `asset` (its sum in `sums`) or `url` (the sum of that download itself, for releases without published sums). |
| `changelog` | optional | `file` and `line`: the line to add under `## Unreleased`. |

Placeholders: `{v}` the new version, `{old}` the version on the base branch,
`{name}` the entry's name, and in `signature` `{sums}` the sums URL.

A variable is one assignment on one line: `VAR: value` (YAML), `VAR=value` (env
file), `ARG VAR=value` or `export VAR=value`, the value optionally quoted. Each
variable must be assigned exactly once in its file. A pin in another file
that pins the version as well (the same variable) must be at the new version
too, or its sums would not match what it installs.

### What it does

On every push to a `renovate/*` branch of a pull request opened by
`renovate[bot]` from the repository itself:

1. It reads the table **from the merge base**, not from the pull request, so a
   pull request cannot change the keys its own sums are checked against.
2. For each entry whose version differs from the merge base, it downloads the
   sums (https only), verifies the signature where one is configured, against
   only the configured key in an empty keyring, and takes the sum of each pin's
   asset. A clear-signed file must be a single signed message with nothing
   around it, and only the signed text is read.
3. Only when every check of every entry passes does it write: the new sums, and
   the changelog line as the first item under `## Unreleased` (a new section
   above the first `## ` heading when there is none). An entry gets no line
   when the pull request has already added one that names the tool and its new
   version, so a line edited in review is not added again, while a second
   update in the same pull request still gets its own.
4. It commits the changed files to the branch through the GraphQL API
   (`createCommitOnBranch`) with a token of the GitHub App, on top of the head it
   checked out; if the branch has moved, GitHub refuses the commit and the run
   for the new head takes over. GitHub signs the commit, it starts the checks
   again, and the app is the branch's last pusher, so the owner's approval
   counts under "require approval of the most recent push".
5. When a check fails, it commits nothing and writes the reason into a comment
   on the pull request; a later passing run marks that comment resolved.

A run whose values are already in place commits nothing, so the run started by
its own commit ends there.

The status `renovate/stability-days` does not move to the app's commit: Renovate
sets it on its own commit, so it disappears from the pull request, as it does
after any push by someone else. The workflow does not copy it, which would need
a token with the `statuses` permission. Nothing is lost: Renovate creates the
branch only once the minimum release age has passed (`internalChecksFilter`
`strict`, the default), so the status was green, and it is not a required
check.

Limits:

- **No workflow files.** A pin in `.github/workflows/` is refused: the app has no
  permission to change workflows, on purpose. Move such a pin into a local
  action under `.github/actions/`, as `setup-oras` does.
- **No new keys by itself.** A release signed with another key fails until the
  table names it; a new signing key is a decision.
- **Without a signature** the sums are as trustworthy as the release page,
  as when copied by hand.

### Security notes

- **Who triggers it.** The workflow runs only for pull requests opened by
  `renovate[bot]`, only on a push by `renovate[bot]` itself, and only while
  every commit of the pull request is the bot's or an app's. A push by anyone
  else gets no app commit on top, so nobody can make the app the last pusher
  of their own code and then approve it. A manual re-run counts as a run by
  whoever starts it and does nothing; to run it again after a failed download,
  tick the rebase checkbox in the pull request, and Renovate pushes anew.
- **One key, several repositories.** The app's private key is a secret in each
  repository that uses the workflow. Whoever can push a workflow to one of them
  can read it and get a token for every repository the app is installed on,
  limited to the app's permission (contents). Keep the app's permissions and
  its list of repositories as small as below; with collaborators, consider one
  app per repository.
- **Signed sums name the version.** Each asset of signed sums must contain
  `{v}`, so validly signed sums of an older release cannot be passed off as the
  new version's.

### Locally

```sh
scripts/pin-checksums.sh --base origin/main --table-ref origin/main   # changed entries
scripts/pin-checksums.sh --all --dry-run                              # check every entry
```

It needs bash, git, curl, gpg, jq, shasum and [yq](https://github.com/mikefarah/yq) v4.

## The GitHub App

One app, owned by the ioanalytica account, commits the sums in all
repositories that use the workflow.

1. **Create it**: <https://github.com/settings/apps/new>
   - GitHub App name: `ioanalytica-renovate-helper` (any free name).
   - Homepage URL: `https://github.com/ioanalytica/renovate-config`.
   - Webhook: untick **Active**.
   - Repository permissions: **Contents: Read and write**. Metadata: Read-only
     is added by GitHub. Nothing else: no Pull requests, no Workflows, no
     organization or account permissions.
   - Where can this GitHub App be installed: **Only on this account**.
2. **Note its App ID** on the app's page (General), and **generate a private
   key** there (Private keys → Generate a private key); a `.pem` file is
   downloaded.
3. **Install it** (Install App → ioanalytica → **Only select repositories**):
   `k8s-borg`, `nginx-static`, `wordpress-nginx`, `wordpress-idx`,
   `seafile-helm`.
4. **Add the secrets** to each of those repositories (Settings → Secrets and
   variables → Actions → New repository secret; ioanalytica is a user account,
   so there are no organization secrets):
   - `RENOVATE_HELPER_APP_ID`: the App ID.
   - `RENOVATE_HELPER_PRIVATE_KEY`: the whole content of the `.pem` file.

   Or with `gh`, per repository:

   ```sh
   gh secret set RENOVATE_HELPER_APP_ID --repo ioanalytica/<repo> --body '<app-id>'
   gh secret set RENOVATE_HELPER_PRIVATE_KEY --repo ioanalytica/<repo> < <key>.pem
   ```

   Then delete the `.pem` file, or keep it only in a password manager.
5. **Tell Renovate to ignore the app's commits.** Otherwise Renovate treats a
   branch with the app's commit as edited by someone else and stops updating and
   rebasing it. The app's commits are authored by
   `<user-id>+<app-slug>[bot]@users.noreply.github.com`, where `<user-id>` is
   what `gh api 'users/<app-slug>[bot]' --jq .id` prints. Add that address to
   `default.json`:

   ```json
   "gitIgnoredAuthors": ["<user-id>+<app-slug>[bot]@users.noreply.github.com"]
   ```

   Renovate then rebases and updates the branch as before (its new commit
   replaces the app's), and the workflow fills the sums again.

The app pushes only to `renovate/*` branches, so it needs no bypass in the
rulesets; its commits are signed, so it passes a "require signed commits" rule.

## Tests

```sh
bats tests/pin-checksums.bats tests/helpers.bats    # against tests/fixtures, no network
PIN_CHECKSUMS_LIVE=1 bats tests/live.bats           # against the real releases
```

The fixtures are made up and signed with throwaway keys;
`tests/fixtures/generate.sh` regenerates them. The live test checks oras 1.4.0,
etcd 3.6.17, rclone 1.76.0 and hadolint 2.15.1 against the sums pinned by hand
in the repositories that use them. CI (`.github/workflows/test.yml`) runs both,
shellcheck, and the Renovate config validator on the preset.

## License

[Apache License 2.0](LICENSE).
