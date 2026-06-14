# Homebrew Cask for Dustpan — ready to submit to a tap the moment a notarized,
# Developer-ID-signed DMG is published to GitHub Releases.
#
# The sha256 below is for the CURRENT dist/ DMG; regenerate it (and bump the
# version) from the real release artifact with `scripts/update-cask.sh` before
# submitting. Homebrew Cask requires a notarized app — an unsigned DMG will be
# rejected by `brew install` on other Macs (Gatekeeper), so this ships only
# after P0-6's signing/notarization is in place.
cask "dustpan" do
  version "0.1.0"
  sha256 "c8c6b6dc1760ab2cf4a81ad501f3cb4c343057b205ce8e5f261ee6f7b472ff11"

  url "https://github.com/contactdharsan-blip/Dustpan/releases/download/v#{version}/Dustpan-#{version}.dmg",
      verified: "github.com/contactdharsan-blip/Dustpan/"
  name "Dustpan"
  desc "Free, open-source, trust-first macOS storage cleaner"
  homepage "https://github.com/contactdharsan-blip/Dustpan"

  # No appcast/auto-update yet; releases are manual. Bump version + sha on release.
  depends_on macos: ">= :sonoma" # MACOSX_DEPLOYMENT_TARGET 14.0

  app "Dustpan.app"

  # Everything Dustpan writes lives under its own bundle id / support dir — the
  # undo journal and the community cleaning-rules manifest included.
  zap trash: [
    "~/Library/Application Support/Dustpan",
    "~/Library/Preferences/app.dustpan.Dustpan.plist",
    "~/Library/Saved Application State/app.dustpan.Dustpan.savedState",
    "~/Library/Caches/app.dustpan.Dustpan",
  ]
end
