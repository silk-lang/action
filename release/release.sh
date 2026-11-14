#!/usr/bin/env bash
# The release action's one step. It runs in the package directory on a checkout of the pushed
# commit and does one of three things: maintains the release pull request, publishes a GitHub
# Release, or nothing. Every decision comes from `silk change` and `silk pack`; this script adds
# the Git and GitHub half those commands leave out on purpose.
#
# Inputs arrive as INPUT_* variables (see action.yml). SILK_RELEASE_REMOTE replaces the GitHub
# remote in tests.
set -euo pipefail

say() { printf '%s\n' "$*"; }
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi; say "$*"; }

mode=${INPUT_MODE:-auto}
publish=${INPUT_PUBLISH:-pull-request}
prerelease=${INPUT_PRERELEASE:-}
snapshot=${INPUT_SNAPSHOT:-false}
snapshot_number=${INPUT_SNAPSHOT_NUMBER:-${GITHUB_RUN_NUMBER:-0}}
binaries=${INPUT_BINARIES:-auto}
artifacts=${INPUT_ARTIFACTS:-}
tag_prefix=${INPUT_TAG_PREFIX:-}
pr_title=${INPUT_PR_TITLE:-}
pr_draft=${INPUT_PR_DRAFT:-false}
leave_draft=${INPUT_DRAFT:-false}
public_key=${INPUT_PUBLIC_KEY:-}
require_signature=${INPUT_REQUIRE_SIGNATURE:-false}
dry_run=${INPUT_DRY_RUN:-false}
user_name=${INPUT_GIT_USER_NAME:-github-actions[bot]}
user_email=${INPUT_GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}
signing_key=${INPUT_SIGNING_KEY:-}
signing_password=${INPUT_SIGNING_PASSWORD:-}
export GH_TOKEN=${INPUT_TOKEN:-${GH_TOKEN:-}}
# `silk pack` must not sign: every asset is signed in one place, below.
unset SILK_SIGNING_KEY SILK_SIGNING_PASSWORD

case "$mode" in auto|version|publish) ;; *) fail "mode must be auto, version or publish, not '$mode'" ;; esac
case "$publish" in pull-request|auto) ;; *) fail "publish must be pull-request or auto, not '$publish'" ;; esac
case "$binaries" in auto|true|false|artifacts) ;; *) fail "binaries must be auto, true, false or artifacts, not '$binaries'" ;; esac
[ -f silk.toml ] || fail "no silk.toml in $PWD; set the directory input to the package to release"

base=${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}
branch="silk-release/$base"
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/silk-release.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ -n "${SILK_RELEASE_REMOTE:-}" ]; then
  remote=$SILK_RELEASE_REMOTE
else
  remote="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi
# actions/checkout leaves its own token as an extra header, which would win over the remote's.
remote_git() { git -c "http.https://github.com/.extraheader=" "$@"; }

pending=false
for file in .changes/*.md; do
  if [ -f "$file" ]; then pending=true; fi
done
output has-changes "$pending"

# The prepared release's field `$1`, from `silk change release --json`.
release_json=
load_release() { release_json=$(silk change release --json 2>"$work/release.err") || return 1; }
field() { printf '%s' "$release_json" | jq -r ".$1"; }

manifest_kind() {
  sed -n 's/^[[:space:]]*kind[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' silk.toml | head -n 1
}

tag_exists() {
  [ -n "$(remote_git ls-remote --tags "$remote" "refs/tags/$1")" ]
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

need_minisign() {
  command -v minisign >/dev/null 2>&1 && return 0
  say "Installing minisign"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update >/dev/null && sudo apt-get install -y minisign >/dev/null
  elif command -v brew >/dev/null 2>&1; then
    brew install minisign >/dev/null
  fi
  command -v minisign >/dev/null 2>&1 || fail "minisign is needed to sign and verify a release and could not be installed on this runner"
}

# The committed public key the release must verify against, or nothing.
find_public_key() {
  if [ -n "$public_key" ]; then
    [ -f "$public_key" ] || fail "public-key '$public_key' does not exist"
    say "$public_key"
    return
  fi
  local top
  top=$(git rev-parse --show-toplevel)
  if [ -f minisign.pub ]; then say "$PWD/minisign.pub"; elif [ -f "$top/minisign.pub" ]; then say "$top/minisign.pub"; fi
}

# Writes SHA256SUMS over every asset in `$1` and signs each file and the sums, as `silk pack`
# does: the trusted comment is `<name> <version> <file>`, and `SHA256SUMS` for the sums.
checksum_and_sign() {
  local directory=$1 name=$2 version=$3 file
  (
    cd "$directory"
    rm -f SHA256SUMS ./*.minisig
    : > "$work/sums"
    for file in *; do
      [ -f "$file" ] && sha256 "$file" >> "$work/sums"
    done
    mv "$work/sums" SHA256SUMS
  )
  if [ -z "$signing_key" ]; then
    if [ "$require_signature" = true ]; then fail "require-signature is set and no signing-key was given"; fi
    summary "This release is not signed: no signing-key was given."
    return
  fi
  need_minisign
  local key="$work/signing.key" comment
  (umask 077; printf '%s\n' "$signing_key" > "$key")
  for file in "$directory"/*; do
    [ -f "$file" ] || continue
    comment="$name $version $(basename "$file")"
    if [ "$(basename "$file")" = SHA256SUMS ]; then comment=SHA256SUMS; fi
    printf '%s\n' "$signing_password" | minisign -S -s "$key" -m "$file" -t "$comment" >/dev/null 2>"$work/sign.err" \
      || { rm -f "$key"; fail "signing $(basename "$file") failed: $(tail -n 1 "$work/sign.err")"; }
  done
  rm -f "$key"
}

# Verifies every signature in `$1` against the committed public key.
verify() {
  local directory=$1 key file
  [ -n "$signing_key" ] || return 0
  key=$(find_public_key)
  if [ -z "$key" ]; then
    if [ "$require_signature" = true ]; then fail "require-signature is set and the repository has no minisign.pub to verify against"; fi
    summary "The signatures were not verified: commit the public key as minisign.pub."
    return 0
  fi
  need_minisign
  for file in "$directory"/*; do
    case "$file" in *.minisig) continue ;; esac
    [ -f "$file" ] || continue
    [ -f "$file.minisig" ] || fail "$(basename "$file") has no signature"
    minisign -Vm "$file" -p "$key" >/dev/null 2>&1 \
      || fail "$(basename "$file") does not verify against $key; the signing key and the committed public key differ"
  done
  (cd "$directory" && sha256 -c SHA256SUMS >/dev/null) || fail "SHA256SUMS does not match the assets"
}

# Packs the package at its current manifest version into `$1`.
pack() {
  local out=$1 name=$2 version=$3 with_binaries=$binaries flags=()
  if [ "$with_binaries" = auto ]; then
    with_binaries=false
    if [ "$(manifest_kind)" = executable ]; then with_binaries=true; fi
  fi
  if [ "$with_binaries" = true ]; then flags+=(--bin); fi
  silk pack --json --output "$out" ${flags[@]+"${flags[@]}"} > "$work/pack.json"
  if [ "$with_binaries" = artifacts ]; then
    [ -d "$artifacts" ] || fail "binaries is artifacts and the directory '$artifacts' does not exist"
    local found=false file
    while IFS= read -r file; do
      case "$(basename "$file")" in
        "$name-$version-"*) cp "$file" "$out/"; found=true ;;
        *) fail "$(basename "$file") is not an archive of $name $version" ;;
      esac
    done < <(find "$artifacts" -type f ! -name SHA256SUMS ! -name '*.minisig' ! -name '*.json' | sort)
    [ "$found" = true ] || fail "no binary archives of $name $version in '$artifacts'"
  fi
}

# Publishes the assets in `$1` as the release `$2`: a draft first, public once everything is
# uploaded and verifies.
publish_release() {
  local out=$1 tag=$2 title=$3 notes=$4 commit=$5 pre=$6
  if [ "$dry_run" = true ]; then
    verify "$out"
    summary "Dry run: would publish $tag with $(find "$out" -type f | wc -l | tr -d ' ') assets."
    return
  fi
  # A draft an earlier failed run left behind has no tag yet; start it again.
  if gh release view "$tag" --json isDraft --jq .isDraft 2>/dev/null | grep -q true; then
    gh release delete "$tag" --yes
  fi
  local flags=(--draft --target "$commit" --title "$title" --notes-file "$notes")
  if [ "$pre" = true ]; then flags+=(--prerelease); fi
  gh release create "$tag" ${flags[@]+"${flags[@]}"} "$out"/*
  mkdir "$work/uploaded"
  gh release download "$tag" --dir "$work/uploaded"
  verify "$work/uploaded"
  rm -rf "$work/uploaded"
  if [ "$leave_draft" = true ]; then
    summary "Release $tag is a draft; publish it on GitHub when it is ready."
  else
    local edit=(--draft=false)
    if [ "$pre" = true ]; then edit+=(--latest=false); fi
    gh release edit "$tag" ${edit[@]+"${edit[@]}"} >/dev/null
    summary "Published $tag."
  fi
  output published true
  output release-url "$(gh release view "$tag" --json url --jq .url)"
}

# Publishes the prepared release when its tag does not exist yet.
publish_prepared() {
  local commit=$1
  if ! load_release; then
    say "No prepared release: $(tail -n 1 "$work/release.err")"
    return 1
  fi
  local name version tag pre out="$work/assets"
  name=$(field package); version=$(field version); pre=$(field prerelease)
  tag="$tag_prefix$(field tag)"
  if tag_exists "$tag"; then
    say "$tag is already released."
    return 1
  fi
  say "Publishing $name $version as $tag"
  pack "$out" "$name" "$version"
  silk change snapshot --commit "$commit" > "$out/changes-snapshot.toml"
  checksum_and_sign "$out" "$name" "$version"
  field notes > "$work/notes.md"
  publish_release "$out" "$tag" "$name $version" "$work/notes.md" "$commit" "$pre"
  output mode publish
  output version "$version"
  output tag "$tag"
  output assets "$(jq -c . "$work/pack.json")"
}

# Publishes the pending changes as a dev snapshot of the next version, changing nothing in Git.
publish_snapshot() {
  local commit=$1 json name version tag out="$work/snapshot"
  json=$(silk change snapshot --commit "$commit" --dev "$snapshot_number" --json)
  name=$(printf '%s' "$json" | jq -r .package)
  version=$(printf '%s' "$json" | jq -r .version)
  tag="$tag_prefix$(printf '%s' "$json" | jq -r .tag)"
  if tag_exists "$tag"; then
    say "$tag is already released."
    return
  fi
  say "Publishing the snapshot $name $version as $tag"
  # The archives carry the snapshot's version, so the manifest holds it while they are packed.
  cp silk.toml "$work/silk.toml"
  printf '%s' "$json" | jq -j .manifest > silk.toml
  pack "$out" "$name" "$version" || { cp "$work/silk.toml" silk.toml; exit 1; }
  cp "$work/silk.toml" silk.toml
  printf '%s' "$json" | jq -j .toml > "$out/changes-snapshot.toml"
  checksum_and_sign "$out" "$name" "$version"
  printf '%s' "$json" | jq -j .notes > "$work/snapshot-notes.md"
  publish_release "$out" "$tag" "$name $version" "$work/snapshot-notes.md" "$commit" true
  output snapshot-version "$version"
  output snapshot-tag "$tag"
}

# Consumes the pending changes and commits the result.
version_commit() {
  local flags=()
  if [ -n "$prerelease" ]; then flags+=(--tag "$prerelease"); fi
  silk change version ${flags[@]+"${flags[@]}"}
  load_release || fail "silk change version left no prepared release: $(tail -n 1 "$work/release.err")"
  git add -u .
  git add CHANGELOG.md .changes/releases
  local version_file
  version_file=$(sed -n 's/^[[:space:]]*version-file[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' silk.toml | head -n 1)
  if [ -n "$version_file" ] && [ -f "$version_file" ]; then git add "$version_file"; fi
  git -c user.name="$user_name" -c user.email="$user_email" commit --quiet -m "Release $(field package) $(field version)"
}

# Maintains the release pull request: one commit on the managed branch, cut from the pushed commit.
version_pull_request() {
  # The managed branch is rewritten on every push, so it may hold only what this action wrote.
  if [ -n "$(remote_git ls-remote --heads "$remote" "refs/heads/$branch")" ]; then
    remote_git fetch --quiet --depth=1 "$remote" "refs/heads/$branch"
    local subject committer
    subject=$(git log -1 --format=%s FETCH_HEAD)
    committer=$(git log -1 --format=%ce FETCH_HEAD)
    case "$subject" in
      "Release "*) [ "$committer" = "$user_email" ] || fail "the branch $branch holds a commit by $committer; move it away, the release action rewrites that branch" ;;
      *) fail "the branch $branch holds the commit '$subject', which the release action did not write; move it away" ;;
    esac
  fi
  git checkout --quiet -B "$branch"
  version_commit
  local name version title
  name=$(field package); version=$(field version)
  title=${pr_title:-Release $name $version}
  title=${title//\{name\}/$name}
  title=${title//\{version\}/$version}
  {
    field notes
    say "Merging this pull request publishes $name $version."
  } > "$work/pr.md"
  output mode version
  output version "$version"
  if [ "$dry_run" = true ]; then
    summary "Dry run: would open the pull request '$title' from $branch."
    return
  fi
  remote_git push --quiet --force "$remote" "HEAD:refs/heads/$branch"
  local number
  number=$(gh pr list --head "$branch" --base "$base" --state open --json number --jq '.[0].number // empty')
  if [ -n "$number" ]; then
    gh pr edit "$number" --title "$title" --body-file "$work/pr.md" >/dev/null
    summary "Updated the release pull request #$number: $title"
  else
    local flags=(--head "$branch" --base "$base" --title "$title" --body-file "$work/pr.md")
    if [ "$pr_draft" = true ]; then flags+=(--draft); fi
    number=$(gh pr create ${flags[@]+"${flags[@]}"} | sed -n 's|.*/pull/\([0-9][0-9]*\).*|\1|p' | tail -n 1)
    summary "Opened the release pull request #$number: $title"
  fi
  output pr-number "$number"
}

output mode none
output published false
commit=$(git rev-parse HEAD)

if [ "$pending" = true ] && [ "$mode" != publish ]; then
  if [ "$snapshot" = true ]; then publish_snapshot "$commit"; fi
  if [ "$publish" = auto ]; then
    version_commit
    commit=$(git rev-parse HEAD)
    if [ "$dry_run" != true ]; then remote_git push --quiet "$remote" "HEAD:refs/heads/$base"; fi
    publish_prepared "$commit" || true
  else
    version_pull_request
  fi
elif [ "$pending" = false ] && [ "$mode" != version ]; then
  publish_prepared "$commit" || say "Nothing to release."
else
  say "Nothing to do in $mode mode."
fi
