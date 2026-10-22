cask "melon-tools" do
  version "2.3.1"
  sha256 "bb5d3e0b2ad026249c2846a676879607eeb2f58e40d9e539cb06e0b1113ad0aa"

  url "https://github.com/ivankuprin/MelonTools/releases/download/v#{version}/MelonTools-#{version}.dmg"
  name "Melon Tools"
  desc "Codex account pool, local gateway, and scheduled model tasks"
  homepage "https://github.com/ivankuprin/MelonTools"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Melon Tools.app"

  zap trash: [
    "~/Library/Application Support/MelonTools",
    "~/Library/Caches/dev.melontools.app",
    "~/Library/Logs/MelonTools",
    "~/Library/Preferences/dev.melontools.app.plist",
  ]
end
