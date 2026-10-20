cask "melon-tools" do
  version "1.7.4"
  sha256 "6c27060e7b8959c1078740f400e71088fff8f8149895a731e118e866d78c4e2c"

  url "https://github.com/ivankuprin/MelonTools/releases/download/v#{version}/MelonTools-#{version}.dmg"
  name "Melon Tools"
  desc "Codex account pool, local gateway, and Fleet workflows"
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
