#!/usr/bin/env bash
# The extra-inject workflow runs this before it replaces the release "latest-build". It keeps the build that is about
# to go:
#   - built from another Millennium version than the new build: the release itself is kept. It moves to the tag
#     v<its version>-extra.<sha7>, loses its .torrent files (their web seeds are latest-build URLs, which will serve
#     another file) and is not marked as the latest release.
#   - built from the same version: only the git tag v<version>-extra.<sha7> is made, so its source stays findable.
# It does not delete or publish "latest-build"; the workflow does that after this script succeeds. Any error ends the
# script with a failure, so the workflow never deletes a release that should have been kept.
# The tags must never start with lbk-v: lbk-macos-release.yml builds and releases on those.
#
# Usage: GH_REPO=OWNER/REPO [DRY_RUN=1] bash keep-previous-release.sh
#   DRY_RUN=1    only reads from GitHub, and prints what would change
#   NEW_VERSION  Millennium version of the new build (default: this checkout's scripts/version)
#   RELEASE_TAG  the release that is about to be replaced (default: latest-build; set it to try this on a test release)
set -euo pipefail

: "${GH_REPO:?set GH_REPO to OWNER/REPO}"
export GH_REPO
release_tag="${RELEASE_TAG:-latest-build}"
dry_run="${DRY_RUN:-0}"
retry_delay="${RETRY_DELAY:-5}" # seconds between tries of a GitHub request
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

die() {
    echo "::error::keep-previous-release: $*" >&2
    exit 1
}

# Strips comments, spaces and a leading v, like the workflow's "Resolve version" step.
parse_version() { grep -v '^#' | tr -d '[:space:]' | sed 's/^v//'; }

check_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+[0-9A-Za-z.+-]*$ ]] || die "'$1' ($2) is not a version number"
}

# Runs a command that changes GitHub, or only prints it in a dry run.
change() {
    if [[ "$dry_run" = 1 ]]; then
        printf 'dry run, would run:'
        printf ' %q' "$@"
        echo
    else
        "$@"
    fi
}

# GitHub API GET into $answer. Returns 1 only when GitHub says the thing does not exist. Any other failure is tried
# again, so that one passing error does not stop the run after the release has moved. If it keeps failing, the script
# ends: taking a network or rate limit error for "does not exist" could lose a release. Do not call it in $(...),
# where ending the script would only end the subshell.
answer=""
lookup() {
    local attempt
    for attempt in 1 2 3; do
        if answer=$(gh api "$@" 2> "$work/error"); then return 0; fi
        if grep -q 'HTTP 404' "$work/error"; then return 1; fi
        cat "$work/error" >&2
        if [[ "$attempt" -lt 3 ]]; then sleep "$retry_delay"; fi
    done
    die "gh api $1 failed"
}

# Puts the commit that git tag $1 points to into $answer. Returns 1 when there is no such tag.
tag_commit() {
    lookup "repos/$GH_REPO/git/ref/tags/$1" --jq '.object.type + " " + .object.sha' || return 1
    local type="${answer% *}" object="${answer#* }"
    if [[ "$type" = tag ]]; then # an annotated tag points to a tag object, which points to the commit
        lookup "repos/$GH_REPO/git/tags/$object" --jq .object.sha || die "cannot read the tag object of $1"
    else
        answer="$object"
    fi
}

create_tag() {
    change gh api --silent --method POST "repos/$GH_REPO/git/refs" -f "ref=refs/tags/$1" -f "sha=$2"
}

# A tag that outlives its release must go: "gh release create" would reuse it, at the old commit.
delete_release_tag() {
    local attempt
    for attempt in 1 2 3; do
        tag_commit "$release_tag" || return 0 # gone, perhaps through an earlier try whose answer got lost
        if change gh api --silent --method DELETE "repos/$GH_REPO/git/refs/tags/$release_tag"; then return 0; fi
        if [[ "$attempt" -lt 3 ]]; then sleep "$retry_delay"; fi
    done
    die "cannot delete the tag $release_tag"
}

# Whether the release at tag $1 has a bundle.
has_bundle() {
    lookup "repos/$GH_REPO/releases/tags/$1" --jq '.assets[].name' || return 1
    grep -q '\.tar\.gz$' <<< "$answer"
}

# Release notes from stdin, without their BitTorrent section.
without_bittorrent() {
    tr -d '\r' | awk '/^\*\*.*\*\*$/ { skip = ($0 == "**Download with BitTorrent**") } !skip'
}

if ! lookup "repos/$GH_REPO/releases/tags/$release_tag" --jq .target_commitish; then
    echo "no $release_tag release: just publish"
    delete_release_tag
    exit 0
fi
sha="$answer"
# The workflow creates the release with a commit as its target. One made by hand can name a branch instead.
if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    tag_commit "$release_tag" || die "the $release_tag release has no git tag"
    sha="$answer"
fi

lookup "repos/$GH_REPO/contents/scripts/version?ref=$sha" -H "Accept: application/vnd.github.raw+json" ||
    die "no scripts/version at $sha"
old_version=$(parse_version <<< "$answer")
check_version "$old_version" "scripts/version at $sha"
new_version="${NEW_VERSION:-$(parse_version < "$(dirname "$0")/../../version")}"
check_version "$new_version" "the new build"
kept="v${old_version}-extra.${sha:0:7}"

if [[ "$old_version" = "$new_version" ]]; then
    echo "same version $old_version: tag $kept, replace $release_tag"
    if ! tag_commit "$kept"; then
        create_tag "$kept" "$sha"
    elif [[ "$answer" = "$sha" ]]; then
        echo "the tag $kept already exists; skipping"
    else
        echo "::warning::the tag $kept already exists at $answer, not at $sha; leaving it as it is"
    fi
    exit 0
fi

echo "different version ($old_version, the new build is $new_version): keep the release as $kept, replace $release_tag"
if lookup "repos/$GH_REPO/releases/tags/$kept" --jq .tag_name; then
    # The workflow deletes the old release next, so make sure this one really keeps it.
    if ! tag_commit "$kept" || [[ "$answer" != "$sha" ]]; then
        die "the release $kept exists, but its tag is not on $sha, so it does not keep this build"
    fi
    has_bundle "$kept" || die "the release $kept exists, but has no bundle, so it does not keep this build"
    echo "the release $kept already exists; skipping"
    exit 0
fi

# The tag first, so the release can only end up on the right commit.
if ! tag_commit "$kept"; then
    create_tag "$kept" "$sha"
elif [[ "$answer" != "$sha" ]]; then
    # Going on would delete the release without having kept it.
    die "the tag $kept exists at $answer, not at $sha, so the release cannot be kept under that name"
fi

# The torrents go before the move: if the run stops in between, the next one finds the release still in place. Their
# part of the notes goes first, so the notes never offer a download that is gone.
lookup "repos/$GH_REPO/releases/tags/$release_tag" --jq '.body // ""' || die "the $release_tag release is gone"
without_bittorrent <<< "$answer" > "$work/stripped.md"
change gh release edit "$release_tag" --notes-file "$work/stripped.md"

lookup "repos/$GH_REPO/releases/tags/$release_tag" --jq '.assets[].name' || die "the $release_tag release is gone"
while IFS= read -r asset; do
    case "$asset" in
        *.torrent) change gh release delete-asset "$release_tag" "$asset" --yes ;;
    esac
done <<< "$answer"

# The kept release's notes: the stripped ones, marked as older, with the manual fetch command pointed at this release.
notes="$work/notes.md"
{
    # shellcheck disable=SC2016 # the backticks are Markdown
    printf '**This is an older Millennium version (%s).** Homebrew installs the current `latest-build` release, not this one.\n\n' \
        "$old_version"
    sed "s|\(millennium-extra-inject\.sh fetch $GH_REPO\)\$|\1 $kept|" "$work/stripped.md"
} > "$notes"
if [[ "$dry_run" = 1 ]]; then
    echo "--- new notes ---"
    cat "$notes"
    echo "--- end of notes ---"
fi

change gh release edit "$release_tag" --tag "$kept" --target "$sha" \
    --title "Millennium $old_version (older version, build ${sha:0:7})" --notes-file "$notes" --latest=false

if [[ "$dry_run" != 1 ]]; then
    has_bundle "$kept" || die "there is no release with a bundle at $kept after the move"
fi

delete_release_tag
