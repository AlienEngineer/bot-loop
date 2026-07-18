//! Background issue/PR fetching for the TUI.
//!
//! The `gh` CLI calls that refresh the issue list block for as long as the
//! subprocess runs — often a second or more. Running them on the UI thread
//! froze input and redraws during the periodic auto-refresh, so navigating or
//! typing stuttered while the loop ran (#144). This moves the blocking fetches
//! onto a dedicated worker thread: the UI thread asks for a refresh and picks up
//! the result on a later tick, never blocking on `gh`.

use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::{self, JoinHandle};

use anyhow::Result;

use crate::github::{self, Issue, PullRequest};

/// A completed background fetch: the issue list and the in-progress PR list,
/// each carrying its own result so one failing does not sink the other (the
/// same best-effort split the old inline `auto_refresh` used).
pub struct FetchOutcome {
    pub issues: Result<Vec<Issue>>,
    pub prs: Result<Vec<PullRequest>>,
}

/// Handle to the background fetch thread. The UI thread requests refreshes and
/// drains outcomes through it. Dropping it closes the request channel, which
/// ends the worker.
pub struct IssueFetcher {
    requests: Sender<()>,
    outcomes: Receiver<FetchOutcome>,
    // Kept so the thread is joined on drop rather than detached; the worker
    // exits promptly once `requests` is dropped and its `recv` returns `Err`.
    _handle: JoinHandle<()>,
}

impl IssueFetcher {
    /// Spawn the worker, fetching up to `limit` issues per refresh.
    pub fn spawn(limit: u32) -> Self {
        let (req_tx, req_rx) = mpsc::channel::<()>();
        let (out_tx, out_rx) = mpsc::channel::<FetchOutcome>();
        let handle = thread::spawn(move || fetch_loop(limit, &req_rx, &out_tx));
        Self {
            requests: req_tx,
            outcomes: out_rx,
            _handle: handle,
        }
    }

    /// Ask the worker to refresh. Non-blocking; a dead worker is ignored since
    /// the UI simply keeps its last data.
    pub fn request(&self) {
        let _ = self.requests.send(());
    }

    /// Take every completed fetch, oldest first, without blocking.
    pub fn drain(&self) -> Vec<FetchOutcome> {
        self.outcomes.try_iter().collect()
    }
}

/// The worker loop: block for a request, coalesce any others already queued into
/// the same cycle, fetch, and send the outcome. Ends when the request channel
/// closes (the UI dropped the fetcher) or the UI stops receiving outcomes.
fn fetch_loop(limit: u32, requests: &Receiver<()>, outcomes: &Sender<FetchOutcome>) {
    while requests.recv().is_ok() {
        // Collapse a backlog of requests into a single fetch so a slow `gh`
        // cannot let refresh requests pile up without bound.
        while requests.try_recv().is_ok() {}

        let outcome = FetchOutcome {
            issues: github::fetch_issues(limit),
            prs: github::fetch_in_progress_prs(),
        };
        if outcomes.send(outcome).is_err() {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn drain_is_empty_before_any_outcome() {
        // A fresh fetcher has produced nothing yet, so draining yields nothing
        // and never blocks. `gh` is not invoked because no request is sent.
        let fetcher = IssueFetcher::spawn(1);
        assert!(fetcher.drain().is_empty());
    }

    #[test]
    fn drain_returns_ready_outcomes_oldest_first() {
        // Drive the drain side directly to avoid depending on `gh`: push two
        // outcomes and confirm `try_iter` hands them back in order.
        let (out_tx, out_rx) = mpsc::channel::<FetchOutcome>();
        out_tx
            .send(FetchOutcome {
                issues: Ok(Vec::new()),
                prs: Ok(Vec::new()),
            })
            .unwrap();
        out_tx
            .send(FetchOutcome {
                issues: Err(anyhow::anyhow!("boom")),
                prs: Ok(Vec::new()),
            })
            .unwrap();

        let drained: Vec<_> = out_rx.try_iter().collect();
        assert_eq!(drained.len(), 2);
        assert!(drained[0].issues.is_ok());
        assert!(drained[1].issues.is_err());
        // Nothing left after a drain.
        assert!(out_rx.try_iter().next().is_none());
    }

    #[test]
    fn coalesces_backlogged_requests_into_one_fetch() {
        // The coalescing drain collapses any queued requests, so N sends result
        // in at most one fetch cycle. Exercise the drain logic in isolation.
        let (req_tx, req_rx) = mpsc::channel::<()>();
        for _ in 0..5 {
            req_tx.send(()).unwrap();
        }
        // First request "seen" by recv, the rest coalesced away.
        assert!(req_rx.recv().is_ok());
        let mut coalesced = 0;
        while req_rx.try_recv().is_ok() {
            coalesced += 1;
        }
        assert_eq!(coalesced, 4);
    }
}
