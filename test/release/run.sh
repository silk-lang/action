#!/usr/bin/env bash
# Drives release/release.sh through a whole release against a local bare remote and a stand-in
# `gh`: nothing pending, the release pull request, its update, the publish after the merge, a
# rerun, a snapshot, publish: auto, and binaries from another job's artifacts.
#
#   test/release/run.sh        needs silk, git, jq and minisign on PATH
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../release/release.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export GH_STATE="$root/gh" GH_REMOTE="$root/remote.git" SILK_RELEASE_REMOTE="$root/remote.git"
export PATH="$here:$PATH" RUNNER_TEMP="$root/tmp" GITHUB_REF_NAME=main GITHUB_RUN_NUMBER=5
mkdir -p "$RUNNER_TEMP" "$GH_STATE"
git init --quiet --bare "$GH_REMOTE"

checks=0
check() { checks=$((checks + 1)); if ! "$@"; then echo "FAILED check $checks: $*" >&2; exit 1; fi; }
same() { checks=$((checks + 1)); if [ "$1" != "$2" ]; then echo "FAILED check $checks: expected '$2', found '$1'" >&2; exit 1; fi; }
out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1; }
release() { export GITHUB_OUTPUT="$root/output"; : > "$GITHUB_OUTPUT"; (cd "$1" && bash "$script") > "$root/log" 2>&1 || { cat "$root/log" >&2; return 1; }; }
commit() { git -C "$1" add -A && git -C "$1" -c user.name=test -c user.email=test@example.com commit --quiet -m "$2" && git -C "$1" push --quiet origin HEAD:main; }

# A signing key pair, the public half committed as the action expects.
export SILK_SIGNING_PASSWORD=secret
silk pack --new-key "$root/release.key" > /dev/null
unset SILK_SIGNING_PASSWORD
export INPUT_SIGNING_KEY INPUT_SIGNING_PASSWORD=secret INPUT_REQUIRE_SIGNATURE=true
INPUT_SIGNING_KEY=$(cat "$root/release.key")

lib="$root/lib"
mkdir -p "$lib/src"
git -C "$lib" init --quiet -b main
git -C "$lib" remote add origin "$GH_REMOTE"
printf '[package]\nname = "greeter"\nversion = "0.1.0"\nkind = "library"\nsource = "src"\n' > "$lib/silk.toml"
printf 'pub fn greet() -> i32 { return 42 }\n' > "$lib/src/lib.silk"
printf 'build\n' > "$lib/.gitignore"
cp "$root/release.pub" "$lib/minisign.pub"
commit "$lib" "Start"

echo "1. nothing pending, nothing prepared"
release "$lib"
same "$(out mode)" none
same "$(out has-changes)" false

echo "2. a pending change opens the release pull request"
(cd "$lib" && silk change minor "Add greet" > /dev/null)
commit "$lib" "Add greet"
release "$lib"
same "$(out mode)" version
same "$(out version)" 0.2.0
same "$(out pr-number)" 7
same "$(cat "$GH_STATE/pr-title")" "Release greeter 0.2.0"
check grep -q -- '- Add greet' "$GH_STATE/pr-body"
same "$(git --git-dir="$GH_REMOTE" log -1 --format=%s silk-release/main)" "Release greeter 0.2.0"
same "$(git --git-dir="$GH_REMOTE" rev-list --count main..silk-release/main)" 1
check test -z "$(git --git-dir="$GH_REMOTE" tag)"

echo "3. a second change updates the same pull request"
git -C "$lib" checkout --quiet main
(cd "$lib" && silk change major "Rename greet" --migration "Call hello instead of greet." > /dev/null)
commit "$lib" "Rename greet"
release "$lib"
same "$(out version)" 1.0.0
same "$(cat "$GH_STATE/pr-title")" "Release greeter 1.0.0"
check test -f "$GH_STATE/pr-edits"
same "$(git --git-dir="$GH_REMOTE" rev-list --count main..silk-release/main)" 1

echo "4. a branch someone else wrote to is not overwritten"
git -C "$lib" checkout --quiet -B other main
git -C "$lib" -c user.name=x -c user.email=x@example.com commit --quiet --allow-empty -m "Release by hand"
git -C "$lib" push --quiet --force origin HEAD:silk-release/main
git -C "$lib" checkout --quiet main
if release "$lib" 2> /dev/null; then echo "FAILED: overwrote a foreign branch" >&2; exit 1; fi
checks=$((checks + 1))
git -C "$lib" push --quiet origin --delete silk-release/main
git -C "$lib" checkout --quiet .
git -C "$lib" clean --quiet -fd
release "$lib"

echo "5. merging the pull request publishes a signed release"
git -C "$lib" fetch --quiet origin silk-release/main
git -C "$lib" checkout --quiet main
git -C "$lib" merge --quiet --ff-only FETCH_HEAD
git -C "$lib" push --quiet origin main
release "$lib"
same "$(out mode)" publish
same "$(out published)" true
same "$(out tag)" v1.0.0
published="$GH_STATE/releases/v1.0.0"
same "$(cat "$published/.draft")" false
same "$(cat "$published/.prerelease")" false
same "$(cat "$published/.target")" "$(git -C "$lib" rev-parse HEAD)"
check grep -q 'Rename greet' "$published/.notes"
for asset in greeter-1.0.0.tar.gz greeter-1.0.0.docs.json changes-snapshot.toml SHA256SUMS; do
  check test -f "$published/$asset"
  check minisign -Vm "$published/$asset" -p "$root/release.pub" -q
done
check grep -q 'trusted comment: greeter 1.0.0 greeter-1.0.0.tar.gz' "$published/greeter-1.0.0.tar.gz.minisig"
(cd "$published" && check sha256sum --quiet -c SHA256SUMS)
same "$(git --git-dir="$GH_REMOTE" rev-parse v1.0.0)" "$(git -C "$lib" rev-parse HEAD)"
check test "$(out assets | jq -r '.archives[0].name')" = greeter

echo "6. a rerun does nothing"
release "$lib"
same "$(out mode)" none
same "$(out published)" false

echo "7. a snapshot publishes the pending changes and commits nothing"
(cd "$lib" && silk change patch "Fix greet" > /dev/null)
commit "$lib" "Fix greet"
INPUT_SNAPSHOT=true INPUT_DRY_RUN=false release "$lib"
snapshot_tag=$(out snapshot-tag)
check test -n "$snapshot_tag"
case "$snapshot_tag" in v1.0.1-dev.5+*) ;; *) echo "FAILED: snapshot tag $snapshot_tag" >&2; exit 1 ;; esac
same "$(cat "$GH_STATE/releases/$snapshot_tag/.prerelease")" true
same "$(cat "$GH_STATE/releases/$snapshot_tag/.latest")" false
check test -f "$GH_STATE/releases/$snapshot_tag/greeter-${snapshot_tag#v}.tar.gz"
same "$(out mode)" version
git -C "$lib" checkout --quiet main
same "$(sed -n 's/^version = "\(.*\)"/\1/p' "$lib/silk.toml")" 1.0.0

echo "8. publish: auto versions on the pushed branch and publishes"
INPUT_PUBLISH=auto release "$lib"
same "$(out mode)" publish
same "$(out tag)" v1.0.1
same "$(git --git-dir="$GH_REMOTE" log -1 --format=%s main)" "Release greeter 1.0.1"
same "$(git --git-dir="$GH_REMOTE" rev-parse v1.0.1)" "$(git --git-dir="$GH_REMOTE" rev-parse main)"

echo "9. a prerelease channel"
git -C "$lib" checkout --quiet main
(cd "$lib" && silk change minor "Add farewell" > /dev/null)
commit "$lib" "Add farewell"
INPUT_PUBLISH=auto INPUT_PRERELEASE=beta release "$lib"
same "$(out tag)" v1.1.0-beta.1
same "$(cat "$GH_STATE/releases/v1.1.0-beta.1/.prerelease")" true

echo "10. binaries packed by another job are collected and signed"
tool="$root/tool"
mkdir -p "$tool/src"
git -C "$tool" init --quiet -b main
git --git-dir="$GH_REMOTE" update-ref -d refs/heads/main
git -C "$tool" remote add origin "$GH_REMOTE"
printf '[package]\nname = "hi"\nversion = "0.1.0"\nkind = "executable"\nsource = "src"\nmain = "main.silk"\n' > "$tool/silk.toml"
printf 'pub fn main() -> i32 { return 0 }\n' > "$tool/src/main.silk"
printf 'build\n' > "$tool/.gitignore"
cp "$root/release.pub" "$tool/minisign.pub"
(cd "$tool" && silk change minor "Say hi" > /dev/null)
commit "$tool" "Start"
rm -f "$GH_STATE/pr-number"
INPUT_PUBLISH=auto INPUT_BINARIES=false INPUT_TAG_PREFIX=hi- INPUT_DRY_RUN=true release "$tool"
git -C "$tool" push --quiet origin HEAD:main
mkdir "$root/artifacts"
(cd "$tool" && silk pack --bin --target aarch64-unknown-linux-gnu --output "$root/packed" > /dev/null 2>&1)
cp "$root/packed/hi-0.2.0-aarch64-unknown-linux-gnu.tar.gz" "$root/artifacts/"
INPUT_BINARIES=artifacts INPUT_ARTIFACTS="$root/artifacts" INPUT_TAG_PREFIX=hi- release "$tool"
same "$(out tag)" hi-v0.2.0
check minisign -Vm "$GH_STATE/releases/hi-v0.2.0/hi-0.2.0-aarch64-unknown-linux-gnu.tar.gz" -p "$root/release.pub" -q
check grep -q 'hi-0.2.0-aarch64-unknown-linux-gnu.tar.gz' "$GH_STATE/releases/hi-v0.2.0/SHA256SUMS"
echo "wrong" > "$root/artifacts/other-9.9.9-x.tar.gz"
git --git-dir="$GH_REMOTE" tag -d hi-v0.2.0 > /dev/null
if INPUT_BINARIES=artifacts INPUT_ARTIFACTS="$root/artifacts" INPUT_TAG_PREFIX=hi- release "$tool" 2> /dev/null; then
  echo "FAILED: accepted an archive of another package" >&2; exit 1
fi
checks=$((checks + 1))

echo "release action: $checks checks passed"
