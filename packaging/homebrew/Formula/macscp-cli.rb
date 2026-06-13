class MacscpCli < Formula
  desc "Scriptable SFTP client CLI for MacSCP"
  homepage "https://github.com/ashutoshkumarsinha/macscp"
  url "https://github.com/ashutoshkumarsinha/macscp/archive/refs/heads/main.tar.gz"
  version "0.3.0"
  sha256 :no_check
  license "MIT"
  head "https://github.com/ashutoshkumarsinha/macscp.git", branch: "main"

  depends_on macos: :sequoia
  depends_on xcode: ["16.0", :build]

  def install
    system "swift", "build", "-c", "release", "--product", "macscp-cli"
    bin.install ".build/release/macscp-cli" => "macscp"
  end

  test do
    assert_match "Scriptable SFTP client", shell_output("#{bin}/macscp --help")
  end
end
