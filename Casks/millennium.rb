cask "millennium" do
  version :latest
  sha256 :no_check

  url "https://github.com/Git-North/Millennium/releases/download/latest-build/millennium-darwin-arm64.tar.gz"
  name "Millennium"
  desc "Steam client modding framework (build with extra-inject support)"
  homepage "https://github.com/Git-North/Millennium"

  depends_on arch: :arm64
  depends_on macos: :ventura

  # The archive holds one version-named folder; run upstream's installer from it. The installer refuses to run
  # while Steam is open, installs the runtime under ~/Library/Application Support/Millennium/runtime and creates
  # "Steam Millennium.app" in /Applications (or ~/Applications).
  installer script: {
    executable: "/bin/sh",
    args:       [
      "-c",
      'd=$(dirname "$1"/*/install_macos.sh) && exec /bin/bash "$d/install_macos.sh" --from-bundle "$d"',
      "--",
      staged_path.to_s,
    ],
  }

  # Removes the wrapper app and the runtime folder only; plugins, themes and config.json stay.
  uninstall script: {
    executable: "/bin/sh",
    args:       [
      "-c",
      'd=$(dirname "$1"/*/install_macos.sh) && exec /bin/bash "$d/install_macos.sh" --from-bundle "$d" --uninstall',
      "--",
      staged_path.to_s,
    ],
  }

  zap trash: "~/Library/Application Support/Millennium"

  caveats <<~EOS
    Quit Steam before installing, upgrading or uninstalling; the installer stops if Steam is running.
    Start Steam through "Steam Millennium.app".

    This cask always installs the newest "latest-build" release. To update:
      brew upgrade --cask --greedy git-north/millennium/millennium
  EOS
end
