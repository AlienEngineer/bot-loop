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
use std::process::{Child, Command, ExitStatus, Stdio};
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
/// `None` (auto) leaves it off so Copilot picks. When `auto_merge` is set,
/// `--auto-merge` is forwarded so each PR merges without manual review (#135).
/// Quality assurance is on in the loop by default, so `--no-quality-assurance` is
/// forwarded only when `quality_assurance` is off, to skip the extra tests (#162).
/// Pure for testing.
pub fn loop_args(
    repo_dir: &Path,
    model: Option<&str>,
    auto_merge: bool,
    quality_assurance: bool,
) -> Vec<String> {
    let mut args = vec![
        "--repo-dir".to_string(),
        repo_dir.display().to_string(),
        "--quiet".to_string(),
    ];
    if let Some(model) = model.map(str::trim).filter(|m| !m.is_empty()) {
        args.push("--model".to_string());
        args.push(model.to_string());
    }
    if auto_merge {
        args.push("--auto-merge".to_string());
    }
    if !quality_assurance {
        args.push("--no-quality-assurance".to_string());
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

/// The lifecycle state of a background worker as last observed, so the bots
/// popup can show which workers are alive and which can be restarted (#82).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerStatus {
    /// The worker's process is still running.
    Running,
    /// The worker exited cleanly (status 0) or was stopped by the user.
    Stopped,
    /// The worker exited non-zero or was killed by a signal we did not send.
    Failed,
}

impl WorkerStatus {
    /// Whether a worker in this state can be restarted — anything not running.
    pub fn is_restartable(self) -> bool {
        !matches!(self, WorkerStatus::Running)
    }
}

/// A read-only snapshot of a worker for the bots popup: enough to show its slot,
/// state, and model, and to drive a restart by id (#82).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerView {
    pub id: usize,
    pub pid: u32,
    pub status: WorkerStatus,
    pub model: Option<String>,
    pub log: PathBuf,
}

/// A background `copilot-loop.sh` worker and the options it was launched with, so
/// it can be restarted in place — same slot, same repo dir and forwarded loop
/// flags (model, auto-merge and quality-assurance), archiving rather than
/// overwriting its previous log (#82).
struct Worker {
    /// Stable slot id, reused across restarts so the capture log path is stable.
    id: usize,
    script: PathBuf,
    repo_dir: PathBuf,
    model: Option<String>,
    /// Whether the loop was launched with `--auto-merge`, forwarded again on a
    /// restart so the worker keeps the flags it was started with (#82, #135).
    auto_merge: bool,
    /// Whether quality assurance is on (loop default). Forwarded again on a
    /// restart so a worker started with `--no-quality-assurance` keeps it (#162).
    quality_assurance: bool,
    log: PathBuf,
    /// The most recent process id, updated on each (re)start.
    pid: u32,
    /// The live process handle while running; `None` once it has exited.
    child: Option<Child>,
    /// The exit status once observed, used to tell a clean stop from a failure.
    exit: Option<ExitStatus>,
    /// Whether the user asked us to stop it, so a signalled exit reads as
    /// "stopped" rather than "failed".
    stopped_by_user: bool,
}

impl Worker {
    /// Note the process's exit if it has finished since the last poll, so a
    /// worker that ended on its own is no longer counted as running.
    fn poll(&mut self) {
        if let Some(child) = self.child.as_mut()
            && let Ok(Some(status)) = child.try_wait()
        {
            self.exit = Some(status);
            self.child = None;
        }
    }

    /// Whether the process is still running (as of the last [`Worker::poll`]).
    fn is_running(&self) -> bool {
        self.child.is_some()
    }

    /// The worker's state: running, a clean/user stop, or a failure.
    fn status(&self) -> WorkerStatus {
        if self.is_running() {
            return WorkerStatus::Running;
        }
        match self.exit {
            Some(status) if !self.stopped_by_user && !status.success() => WorkerStatus::Failed,
            _ => WorkerStatus::Stopped,
        }
    }

    /// A snapshot of this worker for the UI.
    fn view(&self) -> WorkerView {
        WorkerView {
            id: self.id,
            pid: self.pid,
            status: self.status(),
            model: self.model.clone(),
            log: self.log.clone(),
        }
    }
}

/// Manages the background `copilot-loop.sh` workers for the TUI session.
///
/// Holds one [`Worker`] per slot. Several may run at once; the loop's own
/// GitHub-lock claiming keeps them on different issues (#134). Unlike the earlier
/// model, exited workers are kept (not dropped) so a stopped or failed one can be
/// restarted in place with the same options (#82).
#[derive(Default)]
pub struct LoopRunner {
    workers: Vec<Worker>,
}

impl LoopRunner {
    /// A runner with no workers started yet.
    pub fn new() -> Self {
        Self::default()
    }

    /// Refresh every worker's liveness so counts and statuses stay accurate.
    fn poll_all(&mut self) {
        for worker in &mut self.workers {
            worker.poll();
        }
    }

    /// How many workers are currently running. Refreshes liveness first.
    pub fn running_count(&mut self) -> usize {
        self.poll_all();
        self.workers.iter().filter(|w| w.is_running()).count()
    }

    /// Whether any background worker is currently running.
    pub fn is_running(&mut self) -> bool {
        self.running_count() > 0
    }

    /// A snapshot of every tracked worker (running, stopped, or failed), in the
    /// order they were first started, for the bots popup (#82).
    pub fn views(&mut self) -> Vec<WorkerView> {
        self.poll_all();
        self.workers.iter().map(Worker::view).collect()
    }

    /// Start a new worker in slot `id` against `repo_dir`, capturing output to
    /// `log` and running on `model` (`None` = auto). When `auto_merge` is set the
    /// loop is told to merge each PR automatically (`--auto-merge`, #135); when
    /// `quality_assurance` is off it is told to skip the QA tests
    /// (`--no-quality-assurance`, #162). Errors when the process cannot be
    /// spawned. Returns the new process id.
    ///
    /// The launch options are remembered so the worker can later be restarted in
    /// place with the same repo dir and forwarded flags (#82). Unlike a
    /// single-loop model, this never refuses because one is already running: the
    /// loop keeps workers on different issues, so more can be added (#134).
    #[allow(clippy::too_many_arguments)]
    pub fn start(
        &mut self,
        id: usize,
        script: &Path,
        repo_dir: &Path,
        log: &Path,
        model: Option<&str>,
        auto_merge: bool,
        quality_assurance: bool,
    ) -> Result<u32> {
        let child = spawn_detached(
            script,
            &loop_args(repo_dir, model, auto_merge, quality_assurance),
            log,
        )?;
        let pid = child.id();
        self.workers.push(Worker {
            id,
            script: script.to_path_buf(),
            repo_dir: repo_dir.to_path_buf(),
            model: model.map(str::to_owned),
            auto_merge,
            quality_assurance,
            log: log.to_path_buf(),
            pid,
            child: Some(child),
            exit: None,
            stopped_by_user: false,
        });
        Ok(pid)
    }

    /// Restart the stopped or failed worker in slot `id`, re-spawning it with the
    /// same options it was launched with (repo dir and forwarded loop flags) and
    /// reusing its slot, so its capture log path is stable and its previous log is
    /// archived rather than overwritten (#82). Errors when no such slot exists or
    /// the worker is still running.
    pub fn restart(&mut self, id: usize) -> Result<u32> {
        let worker = self
            .workers
            .iter_mut()
            .find(|w| w.id == id)
            .with_context(|| format!("no bot #{id} to restart"))?;
        worker.poll();
        if worker.is_running() {
            anyhow::bail!("bot #{id} is still running");
        }
        let args = loop_args(
            &worker.repo_dir,
            worker.model.as_deref(),
            worker.auto_merge,
            worker.quality_assurance,
        );
        let child = spawn_detached(&worker.script, &args, &worker.log)?;
        worker.pid = child.id();
        worker.child = Some(child);
        worker.exit = None;
        worker.stopped_by_user = false;
        Ok(worker.pid)
    }

    /// Stop every running worker (TERM each process group, escalating to KILL
    /// after a grace period that matches the bash TUI's `stop_bot`). Stopped
    /// workers are kept (marked "stopped") so they can be restarted in place
    /// (#82). A no-op when nothing is running.
    pub fn stop_all(&mut self) {
        for worker in &mut self.workers {
            if let Some(mut child) = worker.child.take() {
                terminate(&mut child);
                worker.exit = child.wait().ok();
                worker.stopped_by_user = true;
            }
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
    // Preserve any previous capture log instead of silently overwriting it, so a
    // restart keeps the stopped or failed run's output for inspection (#82).
    archive_existing_log(log);
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

/// Move an existing capture `log` aside to the first free `"<log>.<n>"` sibling
/// (n = 1, 2, …) so a restart preserves the previous run's output rather than
/// overwriting it, returning the archive path when one was made (#82). Best
/// effort: a no-op when the log is absent, and it leaves the log in place if
/// every candidate name is taken or the rename fails.
fn archive_existing_log(log: &Path) -> Option<PathBuf> {
    if !log.exists() {
        return None;
    }
    let name = log.file_name()?.to_string_lossy().into_owned();
    for n in 1..=1000u32 {
        let archive = log.with_file_name(format!("{name}.{n}"));
        if !archive.exists() {
            return fs::rename(log, &archive).ok().map(|()| archive);
        }
    }
    None
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
            loop_args(Path::new("/work/repo"), None, false, true),
            vec!["--repo-dir", "/work/repo", "--quiet"]
        );
    }

    #[test]
    fn loop_args_forward_the_model_when_set() {
        assert_eq!(
            loop_args(Path::new("/work/repo"), Some("gpt-5.4"), false, true),
            vec!["--repo-dir", "/work/repo", "--quiet", "--model", "gpt-5.4"]
        );
    }

    #[test]
    fn loop_args_skip_blank_models() {
        assert_eq!(
            loop_args(Path::new("/work/repo"), Some("   "), false, true),
            vec!["--repo-dir", "/work/repo", "--quiet"]
        );
    }

    #[test]
    fn loop_args_forward_auto_merge_when_set() {
        assert_eq!(
            loop_args(Path::new("/work/repo"), None, true, true),
            vec!["--repo-dir", "/work/repo", "--quiet", "--auto-merge"]
        );
    }

    #[test]
    fn loop_args_combine_model_and_auto_merge() {
        assert_eq!(
            loop_args(Path::new("/work/repo"), Some("gpt-5.4"), true, true),
            vec![
                "--repo-dir",
                "/work/repo",
                "--quiet",
                "--model",
                "gpt-5.4",
                "--auto-merge"
            ]
        );
    }

    #[test]
    fn loop_args_forward_no_quality_assurance_when_disabled() {
        // QA is on in the loop by default, so nothing is added when on; the flag
        // only appears to turn it off (#162).
        assert_eq!(
            loop_args(Path::new("/work/repo"), None, false, false),
            vec![
                "--repo-dir",
                "/work/repo",
                "--quiet",
                "--no-quality-assurance"
            ]
        );
    }

    #[test]
    fn loop_args_combine_all_flags() {
        assert_eq!(
            loop_args(Path::new("/work/repo"), Some("gpt-5.4"), true, false),
            vec![
                "--repo-dir",
                "/work/repo",
                "--quiet",
                "--model",
                "gpt-5.4",
                "--auto-merge",
                "--no-quality-assurance"
            ]
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

    /// Whether `err`'s chain carries an `ETXTBSY` ("Text file busy", `os error
    /// 26`) failure.
    #[cfg(unix)]
    fn is_text_file_busy(err: &anyhow::Error) -> bool {
        err.chain().any(|cause| {
            cause
                .downcast_ref::<std::io::Error>()
                .and_then(std::io::Error::raw_os_error)
                == Some(26)
        })
    }

    /// Start a worker, retrying briefly while exec fails with `ETXTBSY`. Writing
    /// an executable and then exec'ing it inside a multithreaded process is
    /// inherently racy: a *concurrent* test's fork can momentarily inherit our
    /// still-open write handle to the freshly written script, so the kernel
    /// refuses to exec it until that child execs and the handle closes. A short
    /// retry makes the test deterministic without weakening what it checks.
    #[cfg(unix)]
    fn start_worker(
        runner: &mut LoopRunner,
        id: usize,
        script: &Path,
        dir: &Path,
        log: &Path,
    ) -> u32 {
        for attempt in 1..=50 {
            match runner.start(id, script, dir, log, None, false, true) {
                Ok(pid) => return pid,
                Err(err) if attempt < 50 && is_text_file_busy(&err) => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(err) => panic!("start worker: {err:#}"),
            }
        }
        unreachable!("the loop returns or panics before exhausting its attempts")
    }

    /// Poll `runner` until the worker in slot `id` is no longer running, or give
    /// up after ~5s so a wedged test fails loudly rather than hanging.
    #[cfg(unix)]
    fn wait_until_stopped(runner: &mut LoopRunner, id: usize) -> WorkerStatus {
        for _ in 0..250 {
            let view = runner
                .views()
                .into_iter()
                .find(|v| v.id == id)
                .expect("worker is tracked");
            if view.status != WorkerStatus::Running {
                return view.status;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("worker #{id} never stopped");
    }

    #[cfg(unix)]
    #[test]
    fn detects_text_file_busy_in_an_error_chain() {
        let busy = Err::<(), _>(std::io::Error::from_raw_os_error(26))
            .context("failed to start /tmp/fake.sh")
            .unwrap_err();
        assert!(is_text_file_busy(&busy));

        let missing = Err::<(), _>(std::io::Error::from_raw_os_error(2))
            .context("failed to start /tmp/fake.sh")
            .unwrap_err();
        assert!(!is_text_file_busy(&missing));
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
        start_worker(&mut runner, 1, &script, &dir, &log1);
        start_worker(&mut runner, 2, &script, &dir, &log2);
        assert_eq!(runner.running_count(), 2);
        assert!(runner.is_running());

        runner.stop_all();
        assert_eq!(runner.running_count(), 0);
        assert!(!runner.is_running());
        // Stopped workers are kept so they can be restarted in place (#82).
        let views = runner.views();
        assert_eq!(views.len(), 2);
        assert!(views.iter().all(|v| v.status == WorkerStatus::Stopped));

        let _ = fs::remove_file(&script);
        let _ = fs::remove_file(&log1);
        let _ = fs::remove_file(&log2);
    }

    #[cfg(unix)]
    #[test]
    fn restart_reuses_the_slot_and_archives_the_previous_log() {
        use std::os::unix::fs::PermissionsExt;

        // A script that records a line then exits cleanly, so the worker stops on
        // its own and we can prove a restart re-runs it and keeps the old log.
        let mut script = std::env::temp_dir();
        script.push(format!("copilot-loop-restart-{}.sh", std::process::id()));
        fs::write(&script, "#!/bin/sh\necho run\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let dir = std::env::temp_dir();
        let log = dir.join(format!("copilot-loop-restart-{}.log", std::process::id()));
        let archived = dir.join(format!("copilot-loop-restart-{}.log.1", std::process::id()));
        let _ = fs::remove_file(&log);
        let _ = fs::remove_file(&archived);

        let mut runner = LoopRunner::new();
        start_worker(&mut runner, 7, &script, &dir, &log);
        assert_eq!(wait_until_stopped(&mut runner, 7), WorkerStatus::Stopped);

        // Restart in place: same slot, previous log archived, new log created.
        for attempt in 1..=50 {
            match runner.restart(7) {
                Ok(_) => break,
                Err(err) if attempt < 50 && is_text_file_busy(&err) => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(err) => panic!("restart worker: {err:#}"),
            }
        }
        assert!(
            archived.is_file(),
            "previous log should be archived, not overwritten"
        );
        let views = runner.views();
        assert_eq!(
            views.len(),
            1,
            "restart reuses the slot rather than adding one"
        );
        assert_eq!(views[0].id, 7);

        wait_until_stopped(&mut runner, 7);
        let _ = fs::remove_file(&script);
        let _ = fs::remove_file(&log);
        let _ = fs::remove_file(&archived);
    }

    #[cfg(unix)]
    #[test]
    fn a_nonzero_exit_reads_as_failed() {
        use std::os::unix::fs::PermissionsExt;

        let mut script = std::env::temp_dir();
        script.push(format!("copilot-loop-fail-{}.sh", std::process::id()));
        fs::write(&script, "#!/bin/sh\nexit 3\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let dir = std::env::temp_dir();
        let log = dir.join(format!("copilot-loop-fail-{}.log", std::process::id()));

        let mut runner = LoopRunner::new();
        start_worker(&mut runner, 1, &script, &dir, &log);
        assert_eq!(wait_until_stopped(&mut runner, 1), WorkerStatus::Failed);

        let _ = fs::remove_file(&script);
        let _ = fs::remove_file(&log);
    }

    #[test]
    fn restart_of_an_unknown_slot_errors() {
        let mut runner = LoopRunner::new();
        assert!(runner.restart(99).is_err());
    }

    #[test]
    fn archive_existing_log_rotates_through_numbered_siblings() {
        let mut log = std::env::temp_dir();
        log.push(format!("copilot-loop-archive-{}.log", std::process::id()));
        let first = log.with_file_name(format!("{}.1", log.file_name().unwrap().to_string_lossy()));
        let second =
            log.with_file_name(format!("{}.2", log.file_name().unwrap().to_string_lossy()));
        let _ = fs::remove_file(&log);
        let _ = fs::remove_file(&first);
        let _ = fs::remove_file(&second);

        // Nothing to archive when the log is absent.
        assert_eq!(archive_existing_log(&log), None);

        fs::write(&log, "one").unwrap();
        assert_eq!(archive_existing_log(&log), Some(first.clone()));
        assert!(!log.exists(), "the log is moved aside, not left in place");
        assert_eq!(fs::read_to_string(&first).unwrap(), "one");

        fs::write(&log, "two").unwrap();
        assert_eq!(archive_existing_log(&log), Some(second.clone()));
        assert_eq!(fs::read_to_string(&second).unwrap(), "two");

        let _ = fs::remove_file(&first);
        let _ = fs::remove_file(&second);
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
