# extra-inject

Lets another `DYLD_INSERT_LIBRARIES` mod (Proton-ish, NotProton) load next to Millennium on macOS. It adds
`MILLENNIUM_EXTRA_INSERT_LIBRARIES`, a list of dylib paths, to Millennium's launcher and bootstrap library, and sets it in
the wrapper app's `Info.plist` so an installed bundle needs no manual setup.

This folder and `.github/workflows/extra-inject-bundle.yml` are new files, so syncing upstream into your fork never
conflicts with them. On every push to the default branch the workflow adds the change to its own checkout and builds the
complete Millennium bundle with upstream's scripts. There is no schedule: it runs when your sync lands.

## Set up once

1. Push this branch to your fork and make it the fork's default branch. A push only starts a workflow that exists in
   the pushed commit, which is why these files ride on the branch you sync.
2. Enable Actions on the fork (they are off by default), then run the workflow once by hand: Actions, "extra-inject
   bundle", Run workflow. The push that created the branch was skipped because it was not the default branch yet.
3. Install Proton-ish on your Mac. The bundle expects its dylib at
   `/Applications/Steam.app/Contents/MacOS/protonish.dylib`. For another path or several (separated by `:`), set the
   repository variable `EXTRA_INJECT_LIBRARIES` (Settings, Secrets and variables, Actions, Variables) and run the
   workflow again.

## Every time you sync

Sync with a merge (the web button's "Update branch" does that, `git merge upstream/...` too). Do not reset the branch to
upstream, that would remove these files. When the run has finished, on your Mac, from a clone with this branch checked
out and with Steam quit:

```sh
sh scripts/macos/extra-inject/millennium-extra-inject.sh fetch YOU/YOUR-FORK
```

It downloads the bundle and prints the install command (upstream's own installer). Run it, then start Steam through
`Steam Millennium.app`. `sh scripts/macos/extra-inject/millennium-extra-inject.sh status` tells whether the installed
runtime has the change.

## Cost

Nothing, for a fork. A fork of a public repository is public, and GitHub's standard macOS runner is free and unlimited for
public repositories on every plan. Self-hosted runners are free too: GitHub announced a per-minute platform charge for
them in December 2025 and postponed it, so check GitHub's billing page now and then.

A private repository is different: your plan's included minutes apply (3,000 a month on GitHub Pro, which the Education
benefit includes), and macOS minutes count ten times, so a long build uses them up quickly. For a private repository run the
workflow on your own Mac:

1. Settings, Actions, Runners, New self-hosted runner, macOS, ARM64. Download the archive from the URL it shows with
   `aria2c`, then run the `config.sh` command it prints. Keep the default labels.
2. Make sure the Mac has Xcode, rustup, cmake and ninja (`brew install rustup cmake ninja`).
3. Settings, Secrets and variables, Actions, Variables: add `EXTRA_INJECT_RUNNER` = `["self-hosted","macOS","ARM64"]`.
4. Start the runner (`./run.sh`, or `./svc.sh install && ./svc.sh start` to keep it running).

This workflow only starts on pushes and manual runs, never on pull requests, so outsiders cannot make your Mac run
their code through it. Keep it that way if you add triggers.

## The first commits on this branch

The branch starts with upstream commits cherry-picked from Millennium's main branch (marked `cherry picked from
commit`). They fix the UI breaking on the latest Steam client. Once your fork contains them through a normal merge,
they are identical on both sides and merge without conflicts.

## Without GitHub

```sh
sh scripts/macos/extra-inject/millennium-extra-inject.sh build --repo .    # build the two files locally (cargo, cmake, ninja)
sh scripts/macos/extra-inject/millennium-extra-inject.sh branch --repo .   # the change as one commit, ready for a PR
```

`edits/` holds the text of every insertion and `extra_inject/` the Rust crate. If upstream changes the code around an
anchored edit, the run fails and says which one; update that anchor in `millennium-extra-inject.sh`.
