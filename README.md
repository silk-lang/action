# Set up Silk

A GitHub Action that installs [Silk](https://github.com/silk-lang/silk) for a job and keeps Silk's
build cache between runs, so a job checks, builds and tests only what changed since the last run.

```yaml
jobs:
  test:
    runs-on: ubuntu-26.04
    steps:
      - uses: actions/checkout@v4
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
