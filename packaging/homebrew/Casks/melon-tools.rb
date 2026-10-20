cask "melon-tools" do
  version "2.2.3"
  sha256 "cbc3b87e3e389b9bce592d80f3a6f9a5a14a385f9443da1d7d6ac5a0972f97c9"

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
