# Silk actions

Three GitHub Actions for [Silk](https://github.com/silk-lang/silk) projects:

| Action | What it does |
| --- | --- |
| `silk-lang/action@v1` | [Sets up Silk](#set-up-silk): installs the pinned version and keeps the build cache between runs. |
| `silk-lang/action/release@v1` | [Releases a package](#release-a-package): keeps a release pull request for the pending `silk change` notes and publishes a signed GitHub Release when it merges. |
| `silk-lang/action/pack@v1` | [Packs binaries](#binaries-that-need-a-runner-per-platform) on one runner, for the release job to sign and publish. |

# Set up Silk

Installs [Silk](https://github.com/silk-lang/silk) for a job and keeps Silk's
build cache between runs, so a job checks, builds and tests only what changed since the last run.

```yaml
jobs:
  test:
    runs-on: ubuntu-26.04
    steps:
      - uses: actions/checkout@v5
      - uses: silk-lang/action@v1
      - run: silk check --workspace
      - run: silk test
```

## What it does

1. Installs the Silk version the project pins as `silk-version` in `silk.toml`, or the latest
   release when it pins none, and puts `silk` on `PATH`.
2. Installs Clang 22 and lld when the runner has none, and sets `SILK_CLANG`.
3. Restores the project's `build` directory and the git dependencies in `~/.silk/git` from the
   latest run of the same job, and saves them again when a job on the default branch passes.

## Why the cache is safe to restore

Silk names what it keeps in `build` by content: the digest of each source file, the compiler, the
target and the profile. A cache from another commit is never wrong, only partly useful. With it
restored:

- `silk check` checks again only the packages whose sources or dependencies changed.
- `silk build` links again only the programs whose inputs changed, and compiles only the changed
  parts of those.
- `silk test` does not run a test root again when nothing it reads changed since it passed. It
  prints `Not run again: nothing changed since these tests passed`.

So a workflow can run every command on every push. No path filters or hand-written cache keys are
needed.

Pull requests restore the cache the default branch saved. They do not save one of their own, so
they cannot fill the repository's cache quota.

## Inputs

| Input | Default | What it does |
| --- | --- | --- |
| `version` | the project's `silk-version` | The Silk release to install, such as `0.1.0-dev.74+205aea3f5b2e`. |
| `working-directory` | `.` | The directory of the project's `silk.toml`. |
| `clang` | `true` | Install Clang 22 and lld when the runner has none. |
| `cache` | `true` | Restore the build cache. |
| `cache-save` | `auto` | `auto` saves on the default branch only. `always` and `never` do what they say. |
| `cache-key` | the job id and matrix | Names this job's cache among the jobs of a workflow. |
| `cache-paths` | `build` | The directories to keep, one per line, relative to `working-directory`. |

## Outputs

| Output | What it is |
| --- | --- |
| `version` | The installed Silk version. |
| `cache-hit` | `true` when a cache was restored, from this commit or an earlier one. |

## Jobs that build different things

Each job keeps its own cache, named by the job id and its matrix values. Two jobs that run the same
commands can share one by giving both the same `cache-key`:

```yaml
- uses: silk-lang/action@v1
  with:
    cache-key: packages
```

## A project that writes somewhere else

If `[workspace].output-dir` or `[build].output-dir` names a directory other than `build`, list it:

```yaml
- uses: silk-lang/action@v1
  with:
    cache-paths: out
```

# Release a package

`silk change` records one-line release notes and cuts versions, and `silk pack` writes the
archives. Neither touches Git or GitHub. The release action adds that half: it runs on every push
to the release branch and does one of three things.

| The pushed commit has | The action |
| --- | --- |
| pending `.changes/*.md` files | runs `silk change version` on the branch `silk-release/<branch>` and opens or updates one pull request, `Release <name> <version>`, whose body is the release notes |
| no pending changes, and a version with no tag yet | runs `silk pack`, signs every file and publishes a GitHub Release with the tag `v<version>` |
| neither | nothing |

Merging the release pull request is a push with nothing pending and an untagged version, so the
same workflow publishes it. A failed publish is retried by running the workflow again, and a run
after a release does nothing.

```yaml
name: Release
on:
  push:
    branches: [main]
permissions:
  contents: write
  pull-requests: write
concurrency: release
jobs:
  release:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v5
      - uses: silk-lang/action@v1
      - uses: silk-lang/action/release@v1
        with:
          token: ${{ secrets.RELEASE_TOKEN }}
          signing-key: ${{ secrets.SILK_SIGNING_KEY }}
          signing-password: ${{ secrets.SILK_SIGNING_PASSWORD }}
```

The repository setting "Allow GitHub Actions to create and approve pull requests" must be on.
With the workflow's own token (the default) the release pull request does not start other
workflows, which is a GitHub rule. Pass a GitHub App token or a personal token as `token` when
the pull request must run CI.

## What a release holds

| Asset | Used for |
| --- | --- |
| `<name>-<version>.tar.gz` | The source archive. A consumer depends on it with `silk add <url>`, pinned by its SHA-256. |
| `<name>-<version>.docs.json` | The package's documentation. |
| `<name>-<version>-<target>.tar.gz` | One per target, for an executable package: `bin/<name>` with the README, license and changelog. |
| `changes-snapshot.toml` | Lets `silk change since <dependency>` list what changed for a consumer who upgrades. |
| `SHA256SUMS` | The checksum of every asset. |
| `*.minisig` | A minisign signature of every asset and of `SHA256SUMS`. |

The release is created as a draft, every asset is uploaded and downloaded again, and it becomes
public only when each signature verifies against the committed public key. The tag appears at
that moment, so a release that failed half way leaves no tag behind.

## Signing

1. Make a key pair once: `SILK_SIGNING_PASSWORD=... silk pack --new-key release.key`. It writes
   the encrypted secret key and `release.pub`.
2. Commit the public key as `minisign.pub` at the repository root.
3. Store the secret key's text as the secret `SILK_SIGNING_KEY` and its password as
   `SILK_SIGNING_PASSWORD`, best in an environment restricted to the release branch.

Each signature's trusted comment is `<name> <version> <file>`, so it cannot be moved to another
version or file. A consumer verifies with `minisign -Vm <file> -p minisign.pub`. Without a key
the action publishes unsigned and says so in the job summary; `require-signature: true` makes
that a failure. Signing and verifying use the `minisign` program, which the action installs with
apt or Homebrew when the runner has none.

## Channels

- **Prerelease line.** `prerelease: beta` makes the release pull request cut `<next>-beta.N`
  versions, published as GitHub prereleases. Removing the input promotes to stable.
- **Snapshots.** `snapshot: true` also publishes every push with pending changes as
  `<next>-dev.N+<commit>`, a prerelease that is never the latest release. Nothing is committed and
  the pending changes stay pending, so the release pull request carries on beside it.
- **No pull request.** `publish: auto` versions, commits to the pushed branch and publishes on
  every push with pending changes. The token must be allowed to push to that branch.

## Binaries that need a runner per platform

An executable package whose targets all build on one runner needs nothing more: the release
action packs `[build].targets` with `silk pack --bin`. When a target needs its own runner, a
matrix job packs with the pack action and the release job collects what the jobs uploaded:

```yaml
jobs:
  pack:
    strategy:
      matrix:
        include:
          - { os: ubuntu-24.04, targets: x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu }
          - { os: macos-26, targets: aarch64-apple-darwin }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v5
      - uses: silk-lang/action@v1
      - uses: silk-lang/action/pack@v1
        with:
          targets: ${{ matrix.targets }}
  release:
    needs: pack
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v5
      - uses: silk-lang/action@v1
      - uses: silk-lang/action/release@v1
        with:
          binaries: artifacts
          signing-key: ${{ secrets.SILK_SIGNING_KEY }}
          signing-password: ${{ secrets.SILK_SIGNING_PASSWORD }}
```

Only the release job holds the signing key. It refuses an archive that is not of the version it
is releasing. The pack jobs run on every push and build the version in the manifest, so with
`binaries: artifacts` the release pull request's merge commit is what they must have packed.

## Release inputs

| Input | Default | What it does |
| --- | --- | --- |
| `token` | the workflow's token | Pushes the release branch, opens the pull request and creates the release. |
| `directory` | `.` | The package to release. |
| `mode` | `auto` | `auto`, `version` or `publish`, to split the two halves into jobs with their own permissions. |
| `publish` | `pull-request` | `pull-request` waits for the merge; `auto` releases on every push with pending changes. |
| `prerelease` | none | A channel such as `beta`. |
| `snapshot` | `false` | Publish every push with pending changes as a dev snapshot. |
| `snapshot-number` | the run number | The N of a snapshot version. |
| `binaries` | `auto` | `auto` packs binaries for an executable package; `true`, `false`; `artifacts` collects the pack action's uploads. |
| `artifact-pattern` | `silk-pack-*` | The artifacts to collect. |
| `signing-key`, `signing-password` | none | The minisign secret key text and its password. |
| `public-key` | `minisign.pub` | The committed public key to verify against. |
| `require-signature` | `false` | Fail when the release cannot be signed and verified. |
| `tag-prefix` | none | Text before `v<version>`, such as `mylib-`. |
| `pr-title` | `Release {name} {version}` | The pull request's title. |
| `pr-draft` | `false` | Open the pull request as a draft. |
| `draft` | `false` | Leave the GitHub Release as a draft. |
| `git-user-name`, `git-user-email` | github-actions[bot] | The author of the version commit. |
| `dry-run` | `false` | Do everything except push, open the pull request and create the release. |

## Release outputs

| Output | What it is |
| --- | --- |
| `mode` | `version`, `publish` or `none`. |
| `has-changes` | Whether changes were pending. |
| `pr-number` | The release pull request. |
| `published` | Whether a release was published. |
| `version`, `tag`, `release-url` | The prepared or published release. |
| `assets` | What `silk pack --json` wrote. |
| `snapshot-version`, `snapshot-tag` | The snapshot, when one was published. |

The action rewrites the branch `silk-release/<branch>` on every push. It refuses to when the
branch's last commit is not one it wrote.

## Testing the release action

`test/release/run.sh` runs the whole flow against a local bare repository and a stand-in `gh`. It
needs `silk`, `git`, `jq` and `minisign`.
