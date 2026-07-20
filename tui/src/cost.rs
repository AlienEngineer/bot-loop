//! Pure monthly-cost aggregation for the cost dashboard (#163).
//!
//! The loop records what each Copilot run cost as an `AI Credits` usage comment
//! on the issue it worked, tagged with a hidden marker and carrying the comment's
//! `createdAt` date. This module turns those usage events into a per-day view of
//! one calendar month — total spend, how many issues were worked, the average
//! per issue, and the cost/issue-count for each day — so the UI can render KPIs
//! and a by-day graph. Everything here is pure (bar [`current_month`], which
//! reads the clock) so the aggregation is unit-testable without a terminal.

use std::time::{SystemTime, UNIX_EPOCH};

use crate::github::Issue;

/// A calendar year and month (1–12).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct YearMonth {
    pub year: i32,
    pub month: u32,
}

impl YearMonth {
    /// The month's short English name (`Jan`…`Dec`), or `"?"` when out of range.
    pub fn short_name(&self) -> &'static str {
        const NAMES: [&str; 12] = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ];
        NAMES
            .get(self.month.wrapping_sub(1) as usize)
            .copied()
            .unwrap_or("?")
    }
}

/// Whether `year` is a Gregorian leap year.
fn is_leap_year(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// The number of days in a given month (1–12), accounting for leap years.
/// Out-of-range months fall back to 30 so callers never index past an array.
pub fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if is_leap_year(year) {
                29
            } else {
                28
            }
        }
        _ => 30,
    }
}

/// Convert a count of days since the Unix epoch (1970-01-01) into a civil
/// `(year, month, day)`. Howard Hinnant's `civil_from_days` algorithm, valid for
/// the whole proleptic Gregorian range. Pure.
fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    let year = (y + i64::from(m <= 2)) as i32;
    (year, m, d)
}

/// Convert a Unix timestamp (seconds, UTC) into a civil `(year, month, day)`.
pub fn civil_from_unix(secs: i64) -> (i32, u32, u32) {
    civil_from_days(secs.div_euclid(86_400))
}

/// The current UTC year-month, read from the system clock. GitHub timestamps are
/// UTC, so bucketing "this month" against a UTC clock keeps the two aligned.
pub fn current_month() -> YearMonth {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let (year, month, _) = civil_from_unix(secs);
    YearMonth { year, month }
}

/// Parse the leading `YYYY-MM-DD` of an ISO-8601 timestamp into `(year, month,
/// day)`, or `None` when it is missing or malformed. Pure.
pub fn parse_ymd(s: &str) -> Option<(i32, u32, u32)> {
    let date = s.get(0..10)?; // "YYYY-MM-DD"
    let mut parts = date.split('-');
    let year: i32 = parts.next()?.parse().ok()?;
    let month: u32 = parts.next()?.parse().ok()?;
    let day: u32 = parts.next()?.parse().ok()?;
    if parts.next().is_some() || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    Some((year, month, day))
}

/// One calendar month of loop spend, bucketed by day.
///
/// `cost_per_day` and `issues_per_day` are indexed by day-of-month minus one
/// (index 0 is the 1st) and are always [`MonthlyCost::days`] long. `issues_per_day`
/// counts *distinct* issues worked that day; `issue_count` counts distinct issues
/// worked anywhere in the month.
#[derive(Debug, Clone, PartialEq)]
pub struct MonthlyCost {
    pub month: YearMonth,
    pub days: u32,
    pub cost_per_day: Vec<f64>,
    pub issues_per_day: Vec<u32>,
    pub total: f64,
    pub issue_count: usize,
}

impl MonthlyCost {
    /// The average spend per issue worked this month, or `None` when no issue
    /// was worked (so the UI shows a dash rather than dividing by zero).
    pub fn average_per_issue(&self) -> Option<f64> {
        (self.issue_count > 0).then(|| self.total / self.issue_count as f64)
    }

    /// The costliest day and its spend (1-based day number), or `None` when
    /// nothing was spent this month.
    pub fn peak_day(&self) -> Option<(u32, f64)> {
        self.cost_per_day
            .iter()
            .enumerate()
            .filter(|&(_, &c)| c > 0.0)
            .max_by(|&(_, a), &(_, b)| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal))
            .map(|(idx, &cost)| (idx as u32 + 1, cost))
    }

    /// Whether any spend was recorded this month.
    pub fn has_spend(&self) -> bool {
        self.total > 0.0
    }
}

/// Aggregate the usage events of `issues` into a [`MonthlyCost`] for `month`.
///
/// Each issue's usage comments dated within `month` add their credits to that
/// day's cost; an issue counts once per day it was worked (regardless of how many
/// runs that day) and once toward the month's issue count. Events outside the
/// month, or with unparseable dates, are ignored.
pub fn monthly_cost<'a, I>(issues: I, month: YearMonth) -> MonthlyCost
where
    I: IntoIterator<Item = &'a Issue>,
{
    let days = days_in_month(month.year, month.month);
    let mut cost_per_day = vec![0.0_f64; days as usize];
    let mut issues_per_day = vec![0_u32; days as usize];
    let mut total = 0.0_f64;
    let mut issue_count = 0_usize;

    for issue in issues {
        let mut worked_days: Vec<usize> = Vec::new();
        for (date, credits) in issue.usage_events() {
            let Some((year, m, day)) = parse_ymd(date) else {
                continue;
            };
            if year != month.year || m != month.month {
                continue;
            }
            let idx = (day - 1) as usize;
            if idx >= cost_per_day.len() {
                continue;
            }
            cost_per_day[idx] += credits;
            total += credits;
            if !worked_days.contains(&idx) {
                worked_days.push(idx);
            }
        }
        if !worked_days.is_empty() {
            issue_count += 1;
            for idx in worked_days {
                issues_per_day[idx] += 1;
            }
        }
    }

    MonthlyCost {
        month,
        days,
        cost_per_day,
        issues_per_day,
        total,
        issue_count,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::github::parse_issues;

    #[test]
    fn civil_from_unix_matches_known_dates() {
        assert_eq!(civil_from_unix(0), (1970, 1, 1));
        assert_eq!(civil_from_unix(1_580_000_000), (2020, 1, 26));
        // A leap day (2020-02-29).
        assert_eq!(civil_from_unix(1_582_934_400), (2020, 2, 29));
    }

    #[test]
    fn days_in_month_handles_leap_years() {
        assert_eq!(days_in_month(2026, 7), 31);
        assert_eq!(days_in_month(2026, 4), 30);
        assert_eq!(days_in_month(2025, 2), 28);
        assert_eq!(days_in_month(2024, 2), 29);
        assert_eq!(days_in_month(2000, 2), 29);
        assert_eq!(days_in_month(1900, 2), 28);
    }

    #[test]
    fn parse_ymd_reads_the_date_prefix() {
        assert_eq!(parse_ymd("2026-07-20T08:44:28Z"), Some((2026, 7, 20)));
        assert_eq!(parse_ymd("2026-12-01"), Some((2026, 12, 1)));
        assert_eq!(parse_ymd("nonsense"), None);
        assert_eq!(parse_ymd("2026-13-01T00:00:00Z"), None);
        assert_eq!(parse_ymd(""), None);
    }

    /// Build an issue JSON with usage comments given as (date, credits) pairs.
    fn issue_with_usage(number: u64, events: &[(&str, &str)]) -> String {
        let comments: Vec<String> = events
            .iter()
            .map(|(date, credits)| {
                let body =
                    format!("```\nAI Credits {credits} (1s)\n```\n<!-- copilot-loop:usage -->");
                format!(
                    r#"{{"body":{},"createdAt":"{date}"}}"#,
                    serde_json::to_string(&body).unwrap()
                )
            })
            .collect();
        format!(
            r#"{{"number":{number},"title":"t","comments":[{}]}}"#,
            comments.join(",")
        )
    }

    fn month(year: i32, month: u32) -> YearMonth {
        YearMonth { year, month }
    }

    #[test]
    fn aggregates_cost_and_issue_counts_per_day() {
        let json = format!(
            "[{},{}]",
            issue_with_usage(
                1,
                &[
                    ("2026-07-01T09:00:00Z", "100"),
                    ("2026-07-01T18:00:00Z", "20")
                ]
            ),
            issue_with_usage(2, &[("2026-07-03T09:00:00Z", "50")]),
        );
        let issues = parse_issues(&json).unwrap();
        let cost = monthly_cost(issues.iter(), month(2026, 7));

        assert_eq!(cost.days, 31);
        assert_eq!(cost.total, 170.0);
        assert_eq!(cost.issue_count, 2);
        // Day 1: 100 + 20 from one issue.
        assert_eq!(cost.cost_per_day[0], 120.0);
        assert_eq!(cost.issues_per_day[0], 1);
        // Day 3: 50 from the other.
        assert_eq!(cost.cost_per_day[2], 50.0);
        assert_eq!(cost.issues_per_day[2], 1);
        assert_eq!(cost.average_per_issue(), Some(85.0));
        assert_eq!(cost.peak_day(), Some((1, 120.0)));
    }

    #[test]
    fn ignores_events_outside_the_month() {
        let json = format!(
            "[{}]",
            issue_with_usage(
                1,
                &[
                    ("2026-06-30T23:00:00Z", "999"),
                    ("2026-07-05T09:00:00Z", "10")
                ],
            ),
        );
        let issues = parse_issues(&json).unwrap();
        let cost = monthly_cost(issues.iter(), month(2026, 7));
        assert_eq!(cost.total, 10.0);
        assert_eq!(cost.issue_count, 1);
        assert_eq!(cost.cost_per_day[4], 10.0);
    }

    #[test]
    fn counts_an_issue_once_across_multiple_days() {
        let json = format!(
            "[{}]",
            issue_with_usage(
                1,
                &[
                    ("2026-07-01T09:00:00Z", "10"),
                    ("2026-07-02T09:00:00Z", "10")
                ],
            ),
        );
        let issues = parse_issues(&json).unwrap();
        let cost = monthly_cost(issues.iter(), month(2026, 7));
        assert_eq!(cost.issue_count, 1);
        assert_eq!(cost.issues_per_day[0], 1);
        assert_eq!(cost.issues_per_day[1], 1);
    }

    #[test]
    fn empty_month_has_no_spend_and_no_average() {
        let cost = monthly_cost(std::iter::empty(), month(2026, 7));
        assert!(!cost.has_spend());
        assert_eq!(cost.total, 0.0);
        assert_eq!(cost.issue_count, 0);
        assert_eq!(cost.average_per_issue(), None);
        assert_eq!(cost.peak_day(), None);
        assert_eq!(cost.cost_per_day.len(), 31);
    }

    #[test]
    fn short_name_maps_months() {
        assert_eq!(month(2026, 7).short_name(), "Jul");
        assert_eq!(month(2026, 1).short_name(), "Jan");
        assert_eq!(month(2026, 12).short_name(), "Dec");
    }
}
