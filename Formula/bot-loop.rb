class BotLoop < Formula
  desc "Autonomous loop and TUI that resolves GitHub issues with the Copilot CLI"
  homepage "https://github.com/AlienEngineer/bot-loop"
  # url and sha256 point at the prebuilt macOS release tarball and are rewritten on
  # every push to main by .github/workflows/release.yml, which also mirrors this
  # file to the alienengineer/homebrew-bot-loop tap that
  # `brew tap alienengineer/bot-loop` installs from.
  url "https://github.com/AlienEngineer/bot-loop/releases/download/v0.1.5/bot-loop-macos.tar.gz"
  sha256 "781ee1b692f4ebb84d7bb1712beb1db0d2f11342902b2bc7024d1a62260d8d61"
  version "0.1.5"

  depends_on "gh"
  depends_on "git"

  def install
    # Prebuilt universal (arm64 + x86_64) TUI binary and the bash loop, shipped in
    # the release tarball.
    libexec.install "bot-loop"

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
