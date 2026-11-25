cask "labworker" do
  version "20261120"
  sha256 "a39d65dfbffb746fb4ab11fa092fc86a92b8493829c9a48703b3f406c6366e3f"

  url "https://github.com/xin67/Labworker/releases/download/v#{version}/Labworker-#{version}.dmg",
      verified: "github.com/xin67/Labworker/"
  name "Labworker"
  desc "Offline-first macOS molecular cloning, CRISPR, and gel electrophoresis workstation"
  homepage "https://github.com/xin67/Labworker"

  depends_on macos: ">= :sonoma"

  app "Labworker.app"

  postflight do
    # Remove macOS Gatekeeper quarantine attribute for ad-hoc signed community releases
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Labworker.app"],
                   must_succeed: false
  end

  uninstall quit: "com.labworker.mac"

  zap trash: [
    "~/Library/Application Support/Labworker",
    "~/Library/Application Support/CloneStudio",
    "~/Library/Preferences/com.labworker.mac.plist",
    "~/Library/Caches/com.labworker.mac",
  ]
end
