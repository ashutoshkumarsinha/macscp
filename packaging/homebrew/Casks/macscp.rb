cask "macscp" do
  version "0.3.0"
  sha256 :no_check

  # Local development: run `make package-dmg` first, then:
  #   brew install --cask ./packaging/homebrew/Casks/macscp.rb
  #
  # Release builds: replace url/sha256 with the GitHub release asset, e.g.:
  #   url "https://github.com/ashutoshkumarsinha/macscp/releases/download/v0.3.0/MacSCP-0.3.0.dmg"
  url "file://#{File.expand_path('../../../dist/MacSCP-0.3.0.dmg', __dir__)}"

  name "MacSCP"
  desc "WinSCP-inspired SFTP client for macOS"
  homepage "https://github.com/ashutoshkumarsinha/macscp"

  app "MacSCP.app"

  zap trash: [
    "~/.macscp",
    "~/Library/Application Support/MacSCP",
  ]
end
