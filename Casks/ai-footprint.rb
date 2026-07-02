cask "ai-footprint" do
  version "2.7.0"
  # NOTE: pin this to the real hash of the uploaded release zip before publishing:
  #   shasum -a 256 "desktop/build/AI-Footprint-#{version}.zip"
  # Until a signed/notarized release exists, :no_check keeps the cask installable
  # from the GitHub release artifact produced by `bash desktop/build-app.sh --zip`.
  sha256 :no_check

  url "https://github.com/vinri2z/ai-footprint/releases/download/v#{version}/AI-Footprint-#{version}.zip"
  name "AI Footprint"
  desc "Menu-bar monitor for the carbon and water footprint of your AI coding agents"
  homepage "https://github.com/vinri2z/ai-footprint"

  # The footprint engine (bash + python + tokscale) is NOT bundled — it comes from
  # these formula deps. See desktop/README.md.
  depends_on formula: ["jq", "node"]
  depends_on macos: ">= :ventura" # macOS 13+ (SMAppService launch-at-login)

  app "AI Footprint.app"

  zap trash: [
    "~/.cache/ai-footprint",
    "~/Library/Preferences/com.vinri2z.ai-footprint.plist",
  ]

  caveats <<~EOS
    AI Footprint lives in the menu bar (no Dock icon). Click the leaf to see
    today's footprint or open the full dashboard.

    Usage data is read live via `npx tokscale@latest`, which needs Node (installed
    as a dependency). Python 3 ships with macOS Command Line Tools.
  EOS
end
