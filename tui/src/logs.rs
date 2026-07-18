//! Locating and reading per-issue loop logs for the output side panel.
//!
//! `copilot-loop.sh` captures each issue's (and its PR's) Copilot transcript to
//! `<repo>/.copilot-loop/logs/issue-<n>-<ts>.log` and `pr-<n>-<ts>.log`, and
//! also mirrors the loop's own status narration (branch creation, "running
//! copilot", PR push, …) into that same file (#126). This module finds the
//! newest such log for an issue and reads its tail so the TUI can show the
//! running loop's full output — not just Copilot's — in a side panel (#107).

use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Where `copilot-loop.sh` writes per-run logs (`LOG_DIR` in the script).
pub fn logs_dir(repo_root: &Path) -> PathBuf {
    repo_root.join(".copilot-loop").join("logs")
}

/// Whether `file_name` is a loop log for the given issue number.
///
/// Matches both the issue run (`issue-<n>-…log`) and the PR conflict run
/// (`pr-<n>-…log`). The trailing `-` after the number keeps `#10` from matching
/// `#107`'s logs.
pub fn is_issue_log(file_name: &str, number: u64) -> bool {
    file_name.ends_with(".log")
        && (file_name.starts_with(&format!("issue-{number}-"))
            || file_name.starts_with(&format!("pr-{number}-")))
}

/// Pick the most recently modified entry, breaking ties by path so the choice is
/// deterministic. Pure for testing.
fn pick_latest(mut entries: Vec<(PathBuf, SystemTime)>) -> Option<PathBuf> {
    entries.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
    entries.pop().map(|(path, _)| path)
}

/// The newest loop log for `number` under `dir`, or `None` when the directory is
/// missing or holds no matching log. Newest is by modification time so the panel
/// follows the loop as it moves from the issue run to a later PR run.
pub fn latest_issue_log(dir: &Path, number: u64) -> Option<PathBuf> {
    let mut matches = Vec::new();
    for entry in fs::read_dir(dir).ok()?.flatten() {
        let file_name = entry.file_name();
        let Some(name) = file_name.to_str() else {
            continue;
        };
        if is_issue_log(name, number) {
            let mtime = entry
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            matches.push((entry.path(), mtime));
        }
    }
    pick_latest(matches)
}

/// Read at most the last `max_bytes` of `path` as (lossy) UTF-8.
///
/// Seeking to the tail keeps reads cheap even for large transcripts; the first
/// line may be partial when truncated, which the caller trims by only showing
/// the lines that fit the panel.
pub fn read_log_tail(path: &Path, max_bytes: u64) -> std::io::Result<String> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    if len > max_bytes {
        file.seek(SeekFrom::Start(len - max_bytes))?;
    }
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

/// Strip terminal control noise so the transcript renders cleanly.
///
/// Removes ANSI escape sequences (CSI and OSC) and stray control characters, and
/// treats a lone carriage return as a line reset (spinners overwrite a line with
/// `\r`) while preserving `\r\n` line endings. Pure for testing.
pub fn sanitize(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut line_start = 0usize;
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\x1b' => match chars.peek() {
                Some('[') => {
                    chars.next();
                    // CSI: consume params/intermediates up to a final byte.
                    while let Some(&nc) = chars.peek() {
                        chars.next();
                        if ('\x40'..='\x7e').contains(&nc) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    chars.next();
                    // OSC: consume up to BEL or the ST terminator (ESC \).
                    while let Some(nc) = chars.next() {
                        if nc == '\x07' {
                            break;
                        }
                        if nc == '\x1b' {
                            if chars.peek() == Some(&'\\') {
                                chars.next();
                            }
                            break;
                        }
                    }
                }
                Some(_) => {
                    chars.next();
                }
                None => {}
            },
            '\r' => {
                if chars.peek() != Some(&'\n') {
                    out.truncate(line_start);
                }
            }
            '\n' => {
                out.push('\n');
                line_start = out.len();
            }
            '\t' => out.push('\t'),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

/// The last `max` lines of `text`, in order. Empty when `max` is 0.
pub fn last_lines(text: &str, max: usize) -> Vec<&str> {
    if max == 0 {
        return Vec::new();
    }
    let mut lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(max);
    lines.split_off(start)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn logs_dir_is_under_the_state_dir() {
        assert_eq!(
            logs_dir(Path::new("/repo")),
            PathBuf::from("/repo/.copilot-loop/logs")
        );
    }

    #[test]
    fn is_issue_log_matches_issue_and_pr_runs() {
        assert!(is_issue_log("issue-107-20260101-000000.log", 107));
        assert!(is_issue_log("pr-107-20260101-000000.log", 107));
    }

    #[test]
    fn is_issue_log_rejects_other_numbers_and_kinds() {
        // The trailing dash stops #10 from matching #107's logs.
        assert!(!is_issue_log("issue-107-20260101-000000.log", 10));
        assert!(!is_issue_log("issue-10-20260101-000000.log", 107));
        assert!(!is_issue_log("issue-107-20260101-000000.txt", 107));
        assert!(!is_issue_log("loop.log", 107));
    }

    #[test]
    fn pick_latest_prefers_newest_then_path() {
        let old = SystemTime::UNIX_EPOCH;
        let new = SystemTime::UNIX_EPOCH + Duration::from_secs(10);
        let chosen = pick_latest(vec![
            (PathBuf::from("a.log"), old),
            (PathBuf::from("b.log"), new),
            (PathBuf::from("c.log"), old),
        ]);
        assert_eq!(chosen, Some(PathBuf::from("b.log")));

        // Ties fall back to the larger path so the result is stable.
        let tie = pick_latest(vec![
            (PathBuf::from("a.log"), new),
            (PathBuf::from("z.log"), new),
        ]);
        assert_eq!(tie, Some(PathBuf::from("z.log")));
    }

    #[test]
    fn pick_latest_none_when_empty() {
        assert_eq!(pick_latest(Vec::new()), None);
    }

    #[test]
    fn latest_issue_log_finds_matches_and_ignores_the_rest() {
        let dir = std::env::temp_dir().join(format!("copilot-logs-{}", std::process::id()));
        let logs = dir.join(".copilot-loop").join("logs");
        fs::create_dir_all(&logs).unwrap();
        for name in [
            "issue-107-20260101-000000.log",
            "pr-107-20260102-000000.log",
            "issue-10-20260101-000000.log",
            "loop.log",
        ] {
            fs::write(logs.join(name), "x").unwrap();
        }

        let found = latest_issue_log(&logs, 107).expect("a 107 log");
        let name = found.file_name().unwrap().to_string_lossy().into_owned();
        assert!(is_issue_log(&name, 107), "unexpected match: {name}");

        assert!(latest_issue_log(&logs, 999).is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn latest_issue_log_none_when_dir_missing() {
        assert!(latest_issue_log(Path::new("/no/such/dir"), 1).is_none());
    }

    #[test]
    fn read_log_tail_returns_only_the_tail() {
        let path = std::env::temp_dir().join(format!("copilot-tail-{}.log", std::process::id()));
        fs::write(&path, "0123456789ABCDEF").unwrap();

        assert_eq!(read_log_tail(&path, 4).unwrap(), "CDEF");
        assert_eq!(read_log_tail(&path, 1000).unwrap(), "0123456789ABCDEF");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn sanitize_strips_ansi_colour_codes() {
        assert_eq!(sanitize("\x1b[32mgreen\x1b[0m done"), "green done");
    }

    #[test]
    fn sanitize_strips_osc_sequences() {
        // OSC 0 (set title) terminated by BEL, then by ST.
        assert_eq!(sanitize("\x1b]0;title\x07keep"), "keep");
        assert_eq!(sanitize("\x1b]0;title\x1b\\keep"), "keep");
    }

    #[test]
    fn sanitize_treats_lone_cr_as_line_reset() {
        // A spinner overwrites the line; only the final frame survives.
        assert_eq!(sanitize("working -\rworking \\\rdone"), "done");
    }

    #[test]
    fn sanitize_keeps_crlf_lines() {
        assert_eq!(sanitize("one\r\ntwo\r\n"), "one\ntwo\n");
    }

    #[test]
    fn last_lines_returns_the_tail_in_order() {
        assert_eq!(last_lines("a\nb\nc\nd", 2), vec!["c", "d"]);
        assert_eq!(last_lines("a\nb", 5), vec!["a", "b"]);
        assert!(last_lines("a\nb", 0).is_empty());
        assert!(last_lines("", 3).is_empty());
    }
}
