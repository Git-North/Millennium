#!/bin/sh
# Adds MILLENNIUM_EXTRA_INSERT_LIBRARIES support to Millennium's macOS launcher and bootstrap library, so another
# DYLD_INSERT_LIBRARIES-based Steam mod (Proton-ish, NotProton) can load next to Millennium.
#
# The change is a small Rust crate (extra_inject/) plus a few insertions (edits/*.txt). It is generated again on top of
# the current upstream source every time, so an upstream update never means resolving merge conflicts.
#
#   millennium-extra-inject.sh branch --repo CLONE [ref]    commit the change to a branch of your git clone
#   millennium-extra-inject.sh build [--repo CLONE] [ref]   build it; a branch name as ref builds that branch as it is
#   millennium-extra-inject.sh fetch OWNER/REPO [release]   download the complete bundle the GitHub Action built
#   millennium-extra-inject.sh install [--from DIR]         copy the two files of a local build into the runtime (backup first)
#   millennium-extra-inject.sh patch-tree [DIR]             edit a source tree you already have, in place (the Action does this)
#   millennium-extra-inject.sh status | restore | apply     is it patched? | undo the install | export and edit, no build
#
# ref defaults to the release tag that matches the installed runtime. Without --repo (or MILLENNIUM_REPO) the source is
# downloaded with aria2c. A Millennium update replaces the runtime folder, so run "build" and "install" after each one.
# Needs: cargo, cmake, ninja, and git or aria2c.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
WORK="${WORK:-$HOME/.cache/millennium-extra-inject}"
RUNTIME="${RUNTIME:-$HOME/Library/Application Support/Millennium/runtime}"
TARGETS="${TARGETS:-macos-bootstrap SteamWrapper}"
UPSTREAM="${UPSTREAM:-Vadko/Millennium}"
RELEASE_BASE="${RELEASE_BASE:-https://github.com}"
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-13.3}"   # upstream's own minimum
BRANCH="${BRANCH:-extra-insert-libraries}"
SRC="$WORK/src"
BUILD="$SRC/build-bs"
MARKER="MILLENNIUM_EXTRA_INSERT_LIBRARIES"
# What the wrapper app's Info.plist sets MILLENNIUM_EXTRA_INSERT_LIBRARIES to: ':'-separated dylib paths.
LIBRARIES="${EXTRA_INJECT_DEFAULT_LIBRARIES:-/Applications/Steam.app/Contents/MacOS/protonish.dylib}"
TRAILER="Generated-by: millennium-extra-inject"
FILES="libmillennium_bootstrap.dylib steam_osx"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" > /dev/null 2>&1 || die "$1 is required ($2)"; }
steam_running() { pgrep -x steam_osx > /dev/null 2>&1; }

runtime_name() {
    if [ -L "$RUNTIME/current" ]; then basename "$(readlink "$RUNTIME/current")"; else echo ""; fi
}

# Tag names that could belong to the installed runtime.
candidates() {
    name=$(runtime_name)
    [ -z "$name" ] || printf '%s\n' "$name" "lbk-v$name" "lbk-$name" "v$name"
    return 0
}

cmd_status() {
    [ -d "$RUNTIME/current" ] || die "no runtime at $RUNTIME/current"
    echo "runtime: $(runtime_name)"
    ok=0
    for f in $FILES; do
        if [ ! -f "$RUNTIME/current/$f" ]; then
            echo "  $f: missing"; ok=1
        elif grep -q "$MARKER" "$RUNTIME/current/$f"; then
            echo "  $f: patched"
        else
            echo "  $f: NOT patched"; ok=1
        fi
    done
    return $ok
}

# ---- getting the source ---------------------------------------------------------------------------------------------------

parse_source_args() {
    CLONE="${MILLENNIUM_REPO:-}"; REF=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo) [ $# -ge 2 ] || die "--repo needs a path"; CLONE="$2"; shift 2 ;;
            *) REF="$1"; shift ;;
        esac
    done
}

# Finds the ref to start from in your clone: the one given, else the release tag of the installed runtime.
resolve_ref_in_clone() {
    git -C "$CLONE" rev-parse --git-dir > /dev/null 2>&1 || die "$CLONE is not a git clone"
    git -C "$CLONE" fetch --tags --quiet 2> /dev/null || echo "note: could not fetch; using what the clone already has"
    if [ -z "$REF" ]; then
        for c in $(candidates); do
            if git -C "$CLONE" rev-parse -q --verify "refs/tags/$c^{commit}" > /dev/null; then REF="$c"; break; fi
        done
        if [ -z "$REF" ]; then REF="origin/lbk-macos"; echo "no release tag matches the installed runtime; using $REF"; fi
    fi
    git -C "$CLONE" rev-parse -q --verify "$REF^{commit}" > /dev/null || die "$REF does not exist in $CLONE"
}

export_from_clone() {
    resolve_ref_in_clone
    echo "exporting $REF from $CLONE ..."
    git -C "$CLONE" archive "$REF" | tar -x -C "$SRC" || die "could not export $REF"
}

fetch_archive() {
    rm -f "$WORK/src.tar.gz"
    aria2c -q --allow-overwrite=true --auto-file-renaming=false -d "$WORK" -o src.tar.gz "https://codeload.github.com/$UPSTREAM/tar.gz/$1"
}

export_from_download() {
    need aria2c "brew install aria2"
    if [ -n "$REF" ]; then
        echo "downloading $REF ..."
        fetch_archive "$REF" || die "could not download $REF from github.com/$UPSTREAM"
    else
        for c in $(candidates); do
            echo "trying $c ..."
            if fetch_archive "$c" 2> /dev/null; then REF="$c"; break; fi
        done
        if [ -z "$REF" ]; then
            REF="lbk-macos"
            echo "no release tag matches the installed runtime; using the branch $REF"
            fetch_archive "$REF" || die "could not download $REF from github.com/$UPSTREAM"
        fi
    fi
    tar -xzf "$WORK/src.tar.gz" -C "$SRC" --strip-components=1 || die "could not unpack the download"
}

# ---- edits ----------------------------------------------------------------------------------------------------------------
# edit FILE MODE ANCHOR NAME: inserts edits/NAME.txt into FILE.
#   bottom / top: at the end / start of the file (no anchor needed, pass -)
#   after: below the one line that contains ANCHOR (that line must be a complete statement)
#   below: the same for any other kind of line (XML, for example)
#   body:  just inside the { that follows the one line that contains ANCHOR (a function signature)
# If an anchor is missing or appears more than once, nothing is changed and the build stops with an explanation.
edit() {
    file=$1; mode=$2; anchor=$3; text="$HERE/edits/$4.txt"
    [ -f "$text" ] || die "missing $text"
    case "$mode" in
        top) { cat "$text"; cat "$file"; } > "$file.new" ;;
        bottom) { cat "$file"; [ -z "$(tail -c1 "$file")" ] || echo; cat "$text"; } > "$file.new" ;;
        after | below | body)
            found=$(EDIT_ANCHOR="$anchor" awk 'index($0, ENVIRON["EDIT_ANCHOR"]) { n++; last = $0 } END { sub(/[ \t]+$/, "", last); print n + 0 ":" last }' "$file")
            count=${found%%:*}
            last=${found#*:}
            [ "$count" = 1 ] || die "edit $4 cannot be applied to $REF: found the anchor $count times in ${file#"$SRC"/}, expected once: $anchor"
            case "$mode:$last" in
                after:*\; | below:* | body:*) ;;
                *) die "edit $4 cannot be applied to $REF: the anchor in ${file#"$SRC"/} is no longer a one-line statement: $last" ;;
            esac
            EDIT_ANCHOR="$anchor" EDIT_TEXT="$text" EDIT_LIBS="$LIBRARIES" awk -v mode="$mode" '
                function subst(s, a, b,   i, out) {
                    out = ""
                    while ((i = index(s, a)) > 0) { out = out substr(s, 1, i - 1) b; s = substr(s, i + length(a)) }
                    return out s
                }
                function emit(   i) { for (i = 1; i <= n; i++) print subst(T[i], "@LIBRARIES@", libs) }
                BEGIN { anchor = ENVIRON["EDIT_ANCHOR"]; libs = ENVIRON["EDIT_LIBS"]; while ((getline l < ENVIRON["EDIT_TEXT"]) > 0) T[++n] = l; state = 0 }
                {
                    if (state == 1) {
                        print
                        t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t)
                        if (t == "{") { emit(); state = 2 }
                        next
                    }
                    if (state == 0 && index($0, anchor)) {
                        if (mode == "after" || mode == "below") { print; emit(); state = 2 }
                        else { print; state = 1 }
                        next
                    }
                    print
                }' "$file" > "$file.new" ;;
        *) die "unknown edit mode: $mode" ;;
    esac
    first=$(grep -v '^[[:space:]]*$' "$text" | head -n 1)
    grep -qF -- "$first" "$file.new" || die "edit $4 cannot be applied to $REF: its insertion point was not found in ${file#"$SRC"/}"
    mv "$file.new" "$file"
}

change_present() { grep -q millennium_extra_inject "$SRC/src/bootstrap/macos/dylib_bootstrap.cc" 2> /dev/null; }

apply_edits() {
    m="$SRC/src/bootstrap/macos"
    [ -f "$m/dylib_bootstrap.cc" ] || die "$REF has no macOS bootstrap sources"
    [ -f "$m/steam_launcher.cc" ] || die "$REF has no macOS bootstrap sources"
    [ -f "$m/Info.plist.xml" ] || die "$REF has no wrapper Info.plist.xml"
    case "$LIBRARIES" in *'<'* | *'>'* | *'&'*) die "EXTRA_INJECT_DEFAULT_LIBRARIES must not contain < > or &: $LIBRARIES" ;; esac
    edit "$m/dylib_bootstrap.cc" top    -                                                         bootstrap-declaration
    edit "$m/dylib_bootstrap.cc" after  'plan.dyldInsertLibraries = rewrite_injected_libraries(' bootstrap-plan
    edit "$m/dylib_bootstrap.cc" body   'static int call_execve_syscall('                         bootstrap-execve
    edit "$m/steam_launcher.cc"  bottom -                                                         launcher-bottom
    edit "$m/CMakeLists.txt"     bottom -                                                         cmake-append
    edit "$m/Info.plist.xml"     below  '<dict>'                                                      plist-environment
    cp -R "$HERE/extra_inject" "$m/extra_inject"
    rm -rf "$m/extra_inject/target"
    echo "applied 6 edits (3 of them anchored) and the extra_inject crate to $REF"
}

# Exports the source into $SRC and edits it, unless that source already contains the change (your branch).
get_source() {
    parse_source_args "$@"
    mkdir -p "$WORK"
    rm -rf "$SRC" && mkdir -p "$SRC"
    if [ -n "$CLONE" ]; then export_from_clone; else export_from_download; fi
    if change_present; then echo "$REF already contains the change; using it as it is"; else apply_edits; fi
}

# ---- commands -------------------------------------------------------------------------------------------------------------

cmd_apply() {
    get_source "$@"
    echo "source: $SRC"
}

# The checks upstream's bundle.sh applies to every binary it ships (macOS only): the right architecture, only system
# libraries, no build-machine rpath, a minimum macOS no newer than upstream's, and a valid signature.
verify_outputs() {
    [ "$(uname)" = Darwin ] || return 0
    arch=$(uname -m)
    bad=0
    for f in $FILES; do
        p="$BUILD/$f"
        archs=$(lipo -archs "$p")
        case " $archs " in *" $arch "*) ;; *) echo "  $f: architectures '$archs' lack '$arch'"; bad=1 ;; esac
        id=$(otool -D "$p" | tail -n +2)
        for dep in $(otool -L "$p" | tail -n +2 | awk '{print $1}' | grep -vxF "${id:-<none>}" || true); do
            case "$dep" in /usr/lib/* | /System/Library/* | @loader_path/* | @executable_path/*) ;; *) echo "  $f: depends on $dep"; bad=1 ;; esac
        done
        if otool -l "$p" | grep -A2 LC_RPATH | grep -E '^ +path ' > /dev/null; then echo "  $f: has a build-machine LC_RPATH"; bad=1; fi
        minos=$(vtool -show-build "$p" | awk '/minos/ {print $2}' | sort -V | tail -n 1)
        if [ -z "$minos" ] || [ "$(printf '%s\n%s\n' "$minos" "$MIN_MACOS" | sort -V | tail -n 1)" != "$MIN_MACOS" ]; then
            echo "  $f: minimum macOS '$minos' is newer than $MIN_MACOS"; bad=1
        fi
        codesign --verify --strict "$p" 2> /dev/null || { echo "  $f: invalid code signature"; bad=1; }
    done
    return $bad
}

build_runtime() {
    cd "$SRC"
    echo "testing the Rust crate ..."
    (cd src/bootstrap/macos/extra_inject && cargo test --quiet) || die "the crate tests failed"
    echo "building ($TARGETS) ..."
    flags=""
    if [ "$(uname)" = Darwin ]; then
        export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
        flags="-DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS -DCMAKE_OSX_ARCHITECTURES=$(uname -m)"
    fi
    # shellcheck disable=SC2086
    cmake -S src/bootstrap/macos -B build-bs -G Ninja -DCMAKE_BUILD_TYPE=Release $flags \
        -DMILLENNIUM_OUTPUT_NAME=libmillennium.dylib \
        -DMILLENNIUM_BOOTLOADER_OUTPUT_NAME=libmillennium_bootstrap.dylib \
        -DMILLENNIUM_HOOK_HELPER_OUTPUT_NAME=libmillennium_hhx64.dylib \
        -DMILLENNIUM_CHILD_HOOK_OUTPUT_NAME=libmillennium_child_hook.dylib > /dev/null || die "cmake configure failed"
    # shellcheck disable=SC2086
    cmake --build build-bs --target $TARGETS || die "build failed"
    if ! verify_outputs; then
        [ "${STRICT:-0}" != 1 ] || die "the built files do not meet upstream's release checks (see above)"
        echo "warning: the built files do not meet upstream's release checks (see above)"
    fi
    echo "$REF" > "$WORK/built-ref"
    echo "built from $REF: $BUILD"
}

cmd_build() {
    need cargo "install Rust from rustup.rs"; need cmake "brew install cmake"; need ninja "brew install ninja"
    get_source "$@"
    build_runtime
}

# Regenerates the change as one commit on $BRANCH, on top of the release (or ref) your runtime comes from. The commit is
# made in a temporary worktree, so your checked-out files are never touched, and it is made again from scratch each time.
cmd_branch() {
    need git "install the Xcode command line tools"
    parse_source_args "$@"
    [ -n "$CLONE" ] || die "branch needs your git clone: --repo PATH (or set MILLENNIUM_REPO)"
    resolve_ref_in_clone
    if git -C "$CLONE" rev-parse -q --verify "refs/heads/$BRANCH" > /dev/null; then
        git -C "$CLONE" log -1 --format=%B "$BRANCH" | grep -q "^$TRAILER" ||
            die "the branch $BRANCH exists and was not created by this script. Use another name: BRANCH=name $0 branch ..."
    fi
    mkdir -p "$WORK"
    SRC="$WORK/worktree"
    git -C "$CLONE" worktree prune
    rm -rf "$SRC"
    git -C "$CLONE" worktree add --detach --quiet "$SRC" "$REF" || die "could not check out $REF in a temporary worktree"
    # shellcheck disable=SC2064
    trap "git -C '$CLONE' worktree remove --force '$SRC' > /dev/null 2>&1 || rm -rf '$SRC'; git -C '$CLONE' worktree prune" EXIT
    if change_present; then die "$REF already contains this change; nothing to do"; fi
    apply_edits
    git -C "$SRC" add -A
    { cat "$HERE/edits/commit-message.txt"; printf '\n%s\n' "$TRAILER"; } |
        git -C "$SRC" commit --quiet -F - || die "git could not commit; check git config user.name and user.email"
    commit=$(git -C "$SRC" rev-parse HEAD)
    git -C "$CLONE" branch -f "$BRANCH" "$commit" ||
        die "could not update $BRANCH; if it is checked out in $CLONE, switch to another branch first"
    echo
    echo "$BRANCH is now one commit on top of $REF:"
    git -C "$CLONE" diff --stat "$REF" "$BRANCH" | sed 's/^/  /'
    echo
    echo "push it with: git -C $CLONE push -u <your-fork> $BRANCH"
    echo "after upstream changes run this command again; it regenerates the commit, so there is nothing to rebase."
}

# Downloads the complete bundle the GitHub Action built (its latest unless you name another release) and unpacks it.
cmd_fetch() {
    need aria2c "brew install aria2"
    repo="${1:-${KIT_REPO:-}}"
    [ -n "$repo" ] || die "fetch needs the GitHub repo that runs the Action: $0 fetch OWNER/REPO [release]"
    release="${2:-latest-build}"
    dest="$WORK/bundle"
    rm -rf "$dest" && mkdir -p "$dest"
    aria2c -q --allow-overwrite=true --auto-file-renaming=false -d "$dest" -o bundle.tar.gz \
        "$RELEASE_BASE/$repo/releases/download/$release/millennium-darwin-arm64.tar.gz" 2> /dev/null ||
        die "no release named $release in $RELEASE_BASE/$repo (has the Action finished? see its Releases page)"
    tar -xzf "$dest/bundle.tar.gz" -C "$dest" && rm -f "$dest/bundle.tar.gz"
    dir=$(find "$dest" -maxdepth 1 -type d -name 'millennium-*-darwin-arm64' | head -n 1)
    [ -n "$dir" ] || die "the download is not a Millennium bundle"
    [ -f "$dir/install_macos.sh" ] || die "the download is not a Millennium bundle"
    echo "bundle: $(basename "$dir")   (installed runtime: $(runtime_name))"
    echo "quit Steam, then install it with upstream's installer:"
    echo "  bash $dir/install_macos.sh --from-bundle $dir"
}

# Edits a source tree you already have, in place. The edits are made on a copy of the affected files first, so a failure
# leaves your tree untouched. The GitHub Action uses it on its checkout before building.
cmd_patch_tree() {
    dir="${1:-.}"
    [ -d "$dir/src/bootstrap/macos" ] || die "$dir is not a Millennium source tree"
    target=$(cd "$dir" && pwd)
    stage="$WORK/stage"
    rm -rf "$stage" && mkdir -p "$stage/src/bootstrap/macos" "$WORK"
    for f in dylib_bootstrap.cc steam_launcher.cc CMakeLists.txt Info.plist.xml; do
        if [ -f "$target/src/bootstrap/macos/$f" ]; then cp "$target/src/bootstrap/macos/$f" "$stage/src/bootstrap/macos/$f"; fi
    done
    SRC="$stage"
    REF="the tree in $target"
    ! change_present || die "$REF already contains this change"
    apply_edits
    cp -R "$stage/src/bootstrap/macos/." "$target/src/bootstrap/macos/"
    rm -rf "$stage"
}

cmd_install() {
    from="$BUILD"
    if [ "${1:-}" = "--from" ]; then
        [ $# -ge 2 ] || die "--from needs a folder"
        from="$2"
    fi
    for f in $FILES; do [ -f "$from/$f" ] || die "$from/$f not found; run: $0 build   (or: $0 fetch OWNER/REPO)"; done
    [ -d "$RUNTIME/current" ] || die "no runtime at $RUNTIME/current"
    ! steam_running || die "quit Steam first"
    backup="$HOME/millennium-runtime-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup" && cp -R "$RUNTIME/current/." "$backup/"
    # rsync (openrsync ships with macOS) writes each file to a temporary name and renames it, so it gets a new inode.
    # cp would overwrite the signed binary in place, and the kernel can then kill Steam at launch with "Code Signature
    # Invalid" because it still holds the old file's signature for that inode. -I copies even when size and time match.
    for f in $FILES; do
        rsync -a -I "$from/$f" "$RUNTIME/current/$f" || die "could not copy $f into $RUNTIME/current"
        xattr -d com.apple.quarantine "$RUNTIME/current/$f" 2> /dev/null || true
    done
    echo "installed the files from $from into $RUNTIME/current"
    echo "backup: $backup   (undo with: $0 restore)"
    cmd_status || true
}

cmd_restore() {
    latest=$(find "$HOME" -maxdepth 1 -name 'millennium-runtime-backup-*' 2> /dev/null | sort | tail -n 1)
    [ -n "$latest" ] || die "no backup found in $HOME"
    ! steam_running || die "quit Steam first"
    rsync -a -I "$latest/" "$RUNTIME/current/" || die "could not restore $latest"   # new inodes, see cmd_install
    echo "restored $latest"
}

case "${1:-}" in
    status) cmd_status ;;
    apply) shift; cmd_apply "$@" ;;
    branch) shift; cmd_branch "$@" ;;
    build) shift; cmd_build "$@" ;;
    install) shift; cmd_install "$@" ;;
    fetch) shift; cmd_fetch "$@" ;;
    patch-tree) shift; cmd_patch_tree "$@" ;;
    restore) cmd_restore ;;
    *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
esac
