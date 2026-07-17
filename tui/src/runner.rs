//! Background `copilot-loop.sh` process management for the TUI.
//!
//! Lets the TUI start one or more workers that work through ready issues while
//! the user keeps browsing, mirroring the bash TUI's detached-bot model: each
//! worker is an ordinary `copilot-loop.sh` run in its own process group with its
//! output captured to a log, and it keeps running after the TUI exits (dropping
//! the child handle never kills it). Running several workers against one repo is
//! safe because the loop claims issues under a GitHub lock (and isolates each in
//! its own git worktree), so workers always pick *different* issues (#134).

use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
#[cfg(unix)]
use std::time::Duration;

use anyhow::{Context, Result};

/// Filename of the loop script, expected at the repository root.
pub const LOOP_SCRIPT_NAME: &str = "copilot-loop.sh";

/// Environment variable that overrides the loop script path.
pub const LOOP_SCRIPT_ENV: &str = "COPILOT_LOOP_SCRIPT";

/// Ordered candidate paths for the loop script: an explicit override first,
/// then the repo root, then the current and parent directories (the TUI is
/// often run from `tui/`). Pure for testing.
pub fn loop_script_candidates(env_override: Option<String>, repo_root: &Path) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = env_override.filter(|s| !s.is_empty()) {
        candidates.push(PathBuf::from(path));
    }
    candidates.push(repo_root.join(LOOP_SCRIPT_NAME));
    candidates.push(PathBuf::from(LOOP_SCRIPT_NAME));
    candidates.push(PathBuf::from("..").join(LOOP_SCRIPT_NAME));
    candidates
}

/// Arguments passed to the background loop, mirroring the bash TUI's `spawn_bot`:
/// point it at the repo and keep its log to clean status lines (the full Copilot
/// transcript still lands under `<repo>/.copilot-loop/logs/`). When a `model` is
/// given it is forwarded as `--model` so the loop runs on the user's choice;
/// `None` (auto) leaves it off so Copilot picks. Pure for testing.
pub fn loop_args(repo_dir: &Path, model: Option<&str>) -> Vec<String> {
    let mut args = vec![
        "--repo-dir".to_string(),
        repo_dir.display().to_string(),
        "--quiet".to_string(),
    ];
    if let Some(model) = model.map(str::trim).filter(|m| !m.is_empty()) {
        args.push("--model".to_string());
        args.push(model.to_string());
    }
    args
}

/// Where a background worker's captured output is written. Each worker gets its
/// own file (`loop-<id>.log`) so concurrent workers never clobber a shared log.
pub fn log_path(repo_root: &Path, worker_id: usize) -> PathBuf {
    repo_root
        .join(".copilot-loop")
        .join("tui")
        .join(format!("loop-{worker_id}.log"))
}

/// The first candidate path that exists as a file, if any.
fn first_existing(candidates: Vec<PathBuf>) -> Option<PathBuf> {
    candidates.into_iter().find(|p| p.is_file())
}

/// Resolve the loop script, honouring `COPILOT_LOOP_SCRIPT` then falling back to
/// the repo root and nearby directories. `None` when no candidate exists.
pub fn resolve_loop_script(repo_root: &Path) -> Option<PathBuf> {
    first_existing(loop_script_candidates(
        std::env::var(LOOP_SCRIPT_ENV).ok(),
        repo_root,
    ))
}

/// The repository root (`git rev-parse --show-toplevel`), or the current
/// directory when git cannot tell.
pub fn repo_root() -> PathBuf {
    if let Ok(output) = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        && output.status.success()
    {
        let root = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !root.is_empty() {
            return PathBuf::from(root);
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Manages the background `copilot-loop.sh` workers for the TUI session.
///
/// Holds a handle per running worker. Several may run at once; the loop's own
/// GitHub-lock claiming keeps them on different issues (#134).
#[derive(Default)]
pub struct LoopRunner {
    workers: Vec<Child>,
}

impl LoopRunner {
    /// A runner with no workers started yet.
    pub fn new() -> Self {
        Self::default()
    }

    /// Drop the handles of workers that have exited so counts stay accurate.
    /// An errored wait means we can no longer track that worker, so it too is
    /// dropped (treated as stopped).
    fn reap(&mut self) {
        self.workers
            .retain_mut(|child| matches!(child.try_wait(), Ok(None)));
    }

    /// How many workers are currently running. Reaps exited workers first.
    pub fn running_count(&mut self) -> usize {
        self.reap();
        self.workers.len()
    }

    /// Whether any background worker is currently running.
    pub fn is_running(&mut self) -> bool {
        self.running_count() > 0
    }

    /// Start another worker against `repo_dir`, capturing output to `log` and
    /// running on `model` (`None` = auto). Errors when the process cannot be
    /// spawned. Returns the new process id.
    ///
    /// Unlike a single-loop model, this never refuses because one is already
    /// running: the loop keeps workers on different issues, so more can be added
    /// (#134).
    pub fn start(
        &mut self,
        script: &Path,
        repo_dir: &Path,
        log: &Path,
        model: Option<&str>,
    ) -> Result<u32> {
        let child = spawn_detached(script, &loop_args(repo_dir, model), log)?;
        let pid = child.id();
        self.workers.push(child);
        Ok(pid)
    }

    /// Stop every running worker (TERM each process group, escalating to KILL
    /// after a grace period that matches the bash TUI's `stop_bot`). A no-op when
    /// nothing is running.
    pub fn stop_all(&mut self) {
        for mut child in std::mem::take(&mut self.workers) {
            terminate(&mut child);
            let _ = child.wait();
        }
    }
}

/// Spawn `program` detached from the TUI: its own process group (so the whole
/// tree can be signalled), stdin from `/dev/null`, and stdout/stderr appended to
/// `log`. Dropping the returned [`Child`] does not kill the process, so the loop
/// keeps running after the TUI exits.
fn spawn_detached(program: &Path, args: &[String], log: &Path) -> Result<Child> {
    if let Some(dir) = log.parent() {
        fs::create_dir_all(dir)
            .with_context(|| format!("failed to create log directory {}", dir.display()))?;
    }
    let out = File::create(log)
        .with_context(|| format!("failed to create log file {}", log.display()))?;
    let err = out.try_clone().context("failed to clone log file handle")?;

    let mut cmd = Command::new(program);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::from(out))
        .stderr(Stdio::from(err));

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // A fresh process group whose leader is the child, so signalling the
        // negative pid reaches the loop and everything it spawns.
        cmd.process_group(0);
    }

    cmd.spawn()
        .with_context(|| format!("failed to start {}", program.display()))
}

/// How long to wait for a TERMed loop to exit before escalating to KILL. Matches
/// the bash TUI's `stop_bot`, which polls for up to 3s (15 × 0.2s) so
/// `copilot-loop.sh` has time to run its cleanup trap — releasing the GitHub lock
/// so the next run is not blocked — before being force-killed. A shorter window
/// risks KILLing the loop mid-cleanup and leaking the lock file.
#[cfg(unix)]
const TERM_GRACE_POLLS: u32 = 30;
#[cfg(unix)]
const TERM_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Terminate a spawned child: TERM its process group, wait up to the grace period
/// (matching the bash TUI's `stop_bot`), then KILL.
fn terminate(child: &mut Child) {
    #[cfg(unix)]
    {
        let pid = child.id();
        signal_group(pid, libc::SIGTERM);
        for _ in 0..TERM_GRACE_POLLS {
            if let Ok(Some(_)) = child.try_wait() {
                return;
            }
            std::thread::sleep(TERM_POLL_INTERVAL);
        }
        signal_group(pid, libc::SIGKILL);
    }
    #[cfg(not(unix))]
    {
        let _ = child.kill();
    }
}

/// Send `sig` to the whole process group led by `pid`, falling back to the lone
/// process when it is not a group leader (best effort). The negative pid targets
/// the group, matching the bash TUI's `stop_bot`. Uses `kill(2)` directly rather
/// than shelling out to `kill`, whose negative-pid parsing differs between the
/// BSD and util-linux implementations and left the group unsignalled on Linux.
#[cfg(unix)]
fn signal_group(pid: u32, sig: i32) {
    let pid = pid as libc::pid_t;
    // SAFETY: `kill(2)` only delivers `sig` to the target process/group; it never
    // touches this process's memory and reports a missing target via its result.
    unsafe {
        if libc::kill(-pid, sig) == -1 {
            libc::kill(pid, sig);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_prefer_env_override() {
        let candidates =
            loop_script_candidates(Some("/custom/loop.sh".to_string()), Path::new("/repo"));
        assert_eq!(candidates[0], PathBuf::from("/custom/loop.sh"));
        assert_eq!(candidates[1], PathBuf::from("/repo/copilot-loop.sh"));
    }

    #[test]
    fn candidates_ignore_empty_override() {
        let candidates = loop_script_candidates(Some(String::new()), Path::new("/repo"));
        assert_eq!(candidates[0], PathBuf::from("/repo/copilot-loop.sh"));
        assert_eq!(candidates[1], PathBuf::from("copilot-loop.sh"));
        assert_eq!(candidates[2], PathBuf::from("../copilot-loop.sh"));
    }

    #[test]
    fn loop_args_target_repo_and_quiet() {
        assert_eq!(
            loop_args(Path::new("/work/repo"), None),
            vec!["--repo-dir", "/work/repo", "--quiet"]
        );
    }

    #[test]
    fn loop_args_forward_the_model_when_set() {
        assert_eq!(
            loop_args(Path::new("/work/repo"), Some("gpt-5.4")),
            vec!["--repo-dir", "/work/repo", "--quiet", "--model", "gpt-5.4"]
        );
    }

    #[test]
    fn loop_args_skip_blank_models() {
        assert_eq!(
            loop_args(Path::new("/work/repo"), Some("   ")),
            vec!["--repo-dir", "/work/repo", "--quiet"]
        );
    }

    #[test]
    fn log_path_is_under_the_state_dir() {
        assert_eq!(
            log_path(Path::new("/repo"), 3),
            PathBuf::from("/repo/.copilot-loop/tui/loop-3.log")
        );
    }

    #[test]
    fn first_existing_finds_the_real_file() {
        let mut path = std::env::temp_dir();
        path.push(format!("copilot-loop-candidate-{}.sh", std::process::id()));
        std::fs::write(&path, "#!/bin/sh\n").unwrap();

        let found = first_existing(vec![
            PathBuf::from("/no/such/copilot-loop.sh"),
            path.clone(),
        ]);

        assert_eq!(found, Some(path.clone()));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn first_existing_none_when_all_missing() {
        assert_eq!(
            first_existing(vec![PathBuf::from("/no/such/file.sh")]),
            None
        );
    }

    #[test]
    fn runner_is_not_running_by_default() {
        let mut runner = LoopRunner::new();
        assert!(!runner.is_running());
        assert_eq!(runner.running_count(), 0);
    }

    #[cfg(unix)]
    #[test]
    fn start_tracks_multiple_workers_and_stop_all_ends_them() {
        use std::os::unix::fs::PermissionsExt;

        // A tiny script that ignores start()'s fixed loop_args and just sleeps,
        // so we can exercise tracking several live workers at once.
        let mut script = std::env::temp_dir();
        script.push(format!("copilot-loop-fake-{}.sh", std::process::id()));
        fs::write(&script, "#!/bin/sh\nsleep 30\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let dir = std::env::temp_dir();
        let log1 = dir.join(format!("copilot-loop-w1-{}.log", std::process::id()));
        let log2 = dir.join(format!("copilot-loop-w2-{}.log", std::process::id()));

        let mut runner = LoopRunner::new();
        runner.start(&script, &dir, &log1, None).expect("start w1");
        runner.start(&script, &dir, &log2, None).expect("start w2");
        assert_eq!(runner.running_count(), 2);
        assert!(runner.is_running());

        runner.stop_all();
        assert_eq!(runner.running_count(), 0);
        assert!(!runner.is_running());

        let _ = fs::remove_file(&script);
        let _ = fs::remove_file(&log1);
        let _ = fs::remove_file(&log2);
    }

    #[cfg(unix)]
    #[test]
    fn spawn_and_terminate_a_process() {
        let mut log = std::env::temp_dir();
        log.push(format!("copilot-loop-runner-{}.log", std::process::id()));

        let mut child =
            spawn_detached(Path::new("sleep"), &["30".to_string()], &log).expect("spawn sleep");
        assert!(
            matches!(child.try_wait(), Ok(None)),
            "sleep should still be running right after spawn"
        );

        terminate(&mut child);
        let status = child.wait().expect("reap the terminated child");
        assert!(
            !status.success(),
            "a terminated process should not report success"
        );

        let _ = std::fs::remove_file(&log);
    }
}
