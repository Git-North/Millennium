# CLAUDE.md

Guidance for Claude Code working in this repository: the user's fork of Millennium (Steam client modding framework),
used on Apple Silicon macOS with Steam's publicbeta and Proton-ish.

## Repos and branches

- `origin` = `Git-North/Millennium` (public fork). **Default branch `lbk-macos`** ("main" in conversation). It is
  `Vadko/Millennium` `lbk-macos` (the macOS port, remote `vadko`) plus the user's commits. `upstream` = iFleey.
- `starlight-macos`: CI that builds `starlight` (the plugin packer) for Apple Silicon. Plugins in
  `~/.gits/Mill-Plugin` use that binary.
- Sync with Vadko by **merging, never resetting**: `git fetch vadko --tags && git merge vadko/lbk-macos`. GitHub's
  Sync button doesn't work for this branch.
- Other Claude sessions may share this checkout. Do branch work in a `git worktree` (e.g. `../Millennium-<topic>`)
  instead of switching branches here.

## macOS architecture (what matters for the fixes below)

- "Steam Millennium.app" (in /Applications) is a wrapper whose `MacOS/` entries are symlinks into
  `~/Library/Application Support/Millennium/runtime/current/` (a symlink to a versioned folder).
- `src/bootstrap/macos/steam_launcher.cc` builds the launcher `steam_osx`. It execs Steam's real `steam_osx` with
  `DYLD_INSERT_LIBRARIES` = `libmillennium_bootstrap.dylib`, `libmillennium_child_hook.dylib`, then the extras from
  `MILLENNIUM_EXTRA_INSERT_LIBRARIES` (Proton-ish's `/Applications/Steam.app/Contents/MacOS/protonish.dylib`).
- `src/bootstrap/macos/dylib_bootstrap.cc` builds `libmillennium_bootstrap.dylib`. Its constructor dlopens
  `libmillennium.dylib` and queues `StartMillennium` on the **main queue**, so the runtime thread starts only
  after every dyld initializer has run. Its `exit()` interposer calls `MillenniumBeforeExit` to stop the runtime
  **before** exit() runs static destructors. Both are crash fixes; don't move them back into
  constructors/destructors.
  - Startup crash (fixed, e3ac00a9): Proton-ish's `np_init` patches libsystem_kernel `__TEXT` pages while
    Millennium's thread runs syscalls there, which caused SIGBUS KERN_PROTECTION_FAILURE in `__bind`/`unlink`/`fcntl`.
  - Quit crash (fixed, ce78b23b): teardown ran after static destructors, which caused `mfm_free` SIGSEGV or
    `std::thread::join` abort.
- `src/platform/posix.cc`: `StartMillennium`, `StopMillennium`, `MillenniumBeforeExit`.
- `tier0_proxy.cc` is the legacy injection path and is not built by `src/bootstrap/macos/CMakeLists.txt`.

## Build, release, install

- **extra-inject** (`scripts/macos/extra-inject/`): `MILLENNIUM_EXTRA_INSERT_LIBRARIES` support, kept as a Rust
  crate plus anchored text edits that are applied to a source tree at build time. The branch itself does not
  contain the edits. If an edit's anchor stops matching after an upstream merge, the script names it.
  - `sh scripts/macos/extra-inject/millennium-extra-inject.sh build --repo ~/.gits/Millennium <ref>` builds
    `libmillennium_bootstrap.dylib` and `steam_osx` into `~/.cache/millennium-extra-inject/src/build-bs`. Needs
    cargo, cmake and ninja (Homebrew).
  - `... install [--from DIR]` (Steam must be quit) backs up `runtime/current` to
    `~/millennium-runtime-backup-<time>` and copies the two files in. `... restore` undoes it.
  - `libmillennium.dylib` is not built by this script. Build it with `scripts/macos/lbk/build.sh` and copy it in
    the same way.
- **Never overwrite a runtime binary in place with `cp`.** The kernel keeps the old code signature cached for that
  inode, and Steam gets killed at launch with "SIGKILL (Code Signature Invalid)". Use `rsync -a -I` (macOS ships
  openrsync), or copy to a temp name and `mv` it over. Check with `stat -f %i` that the inode changed.
- **CI**: `.github/workflows/extra-inject-bundle.yml` runs on every push to `lbk-macos`. It applies the edits,
  runs `scripts/macos/lbk/build.sh` + `bundle.sh` and republishes the release `latest-build` (assets include the
  stable name `millennium-darwin-arm64.tar.gz`). It takes about 4-6 min. **A push to lbk-macos therefore changes what
  users get.** Check `gh run list --repo Git-North/Millennium --branch lbk-macos` afterwards.
- **Homebrew**: `Casks/millennium.rb` on the default branch makes the repo a tap. It installs the newest
  `latest-build` with the bundle's `install_macos.sh --from-bundle`. Users run:
  `brew tap git-north/millennium https://github.com/Git-North/Millennium`, `brew trust git-north/millennium`,
  `brew install --cask git-north/millennium/millennium` (`brew upgrade --cask --greedy ...` to update). Uninstall
  keeps plugins/config, and `--zap` removes `~/Library/Application Support/Millennium`. Lint with `brew style --cask` and
  `brew audit --cask --strict` from a local tap. `brew style` on the whole tap flags upstream's workflow YAML,
  which can be ignored.

## Debugging Steam on this Mac

- Crash reports: `~/Library/Logs/DiagnosticReports/steam_osx-*.ips` (older ones move to `Retired/`). Hangs and
  shutdown stalls: `/Library/Logs/DiagnosticReports/*.hang|*.shutdownStall`, read with `spindump -i <file> -o out.txt`.
  `ExcUserFault_steam_osx-*` (EXC_GUARD in IconServices) appears at every start and is harmless.
- `.ips` files are one JSON header line followed by a JSON body. `usedImages` order shows the load order of
  inserted dylibs, and `vmRegionInfo` shows page protections.
- Millennium's own logger writes to stdout, which goes to /dev/null. Signs that Millennium is running:
  `libmillennium_luavm` child processes of `steam_osx`, and `%cMillennium` lines in
  `~/Library/Application Support/Steam/logs/webhelper_js.txt`.
- `~/Library/Application Support/protonish/protonish.log` has one `np_init: loaded into steam_osx (pid N)` per start
  and `np_fini` per clean quit, which is an easy way to count starts and quits.

## Working rules (from the user)

- **Ask before every Steam restart** (or have the user do it). A scripted restart has crashed Steam before.
- **Ask before pushing** or running anything that changes GitHub (branches, default branch, workflows, releases).
  Never open PRs unasked. No GitHub Actions on private repos (this fork is public, so its workflow is fine).
- Merge, never reset, when syncing. The user doesn't want to deal with merge conflicts.
- Prefer Rust for new compiled code where there is a choice. Use aria2c for downloads and Micro for editing. Don't
  put version numbers in descriptions of the setup.
