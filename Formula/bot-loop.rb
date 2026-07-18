class BotLoop < Formula
  desc "Autonomous loop and TUI that resolves GitHub issues with the Copilot CLI"
  homepage "https://github.com/AlienEngineer/bot-loop"
  # url and sha256 are rewritten on every push to main by
  # .github/workflows/release.yml, which tags a new version and points these at
  # that tag's source tarball. Homebrew infers the version from the tag in the url.
  url "https://github.com/AlienEngineer/bot-loop/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  head "https://github.com/AlienEngineer/bot-loop.git", branch: "main"

  depends_on "rust" => :build
  depends_on "gh"
  depends_on "git"

  def install
    # Build the ratatui terminal UI.
    cd "tui" do
      system "cargo", "build", "--release", "--locked"
      libexec.install "target/release/copilot-loop-tui" => "bot-loop"
    end

    # The bash loop, exposed as `bot-loop-bash`.
    bin.install "copilot-loop.sh" => "bot-loop-bash"

    # `bot-loop` launches the TUI. Point it at the installed bash loop via
    # COPILOT_LOOP_SCRIPT so it can start background workers from any repository
    # (it otherwise looks for the script at the current repo root, which does not
    # exist for an arbitrary target repo).
    (bin/"bot-loop").write_env_script libexec/"bot-loop",
      COPILOT_LOOP_SCRIPT: bin/"bot-loop-bash"
  end

  def caveats
    <<~EOS
      bot-loop drives the GitHub Copilot CLI, which is not available in Homebrew.
      Install it separately and make sure `copilot` is on your PATH:
        https://github.com/github/copilot-cli

      `gh` must be authenticated for the repository you point bot-loop at:
        gh auth login

      Commands installed:
        bot-loop        the terminal UI (browse issues, start background workers)
        bot-loop-bash   the raw autonomous loop (run inside a target repo)
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/bot-loop --version")
    assert_match version.to_s, shell_output("#{bin}/bot-loop-bash --version")
  end
end
