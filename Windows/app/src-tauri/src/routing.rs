//! Routing planner: accounts in, effective order out — a port of
//! CodexRoutingPlanner (groups → preferred → strategy key).

use crate::vault::{Account, APPLE_REF_UNIX_OFFSET};

pub const STRATEGIES: [&str; 7] = [
    "auto",
    "quotaHighFirst",
    "quotaLowFirst",
    "planHighFirst",
    "planLowFirst",
    "expirySoonFirst",
    "custom",
];

fn quota_score(account: &Account) -> f64 {
    let hourly = account
        .quota
        .as_ref()
        .and_then(|q| q.hourly_remaining_percent)
        .unwrap_or(100.0);
    let weekly = account
        .quota
        .as_ref()
        .and_then(|q| q.weekly_remaining_percent)
        .unwrap_or(100.0);
    hourly.min(weekly)
}

fn plan_rank(account: &Account) -> i32 {
    let plan = account
        .plan_type
        .clone()
        .unwrap_or_default()
        .to_lowercase();
    match plan.as_str() {
        "free" => 0,
        "go" => 1,
        "plus" => 2,
        "prolite" => 3,
        "pro" => 4,
        "team" | "business" | "self_serve_business_usage_based" => 5,
        "enterprise" | "enterprise_cbp_automation" => 6,
        _ if plan.is_empty() => 0,
        _ => 2,
    }
}

fn expiry_unix(account: &Account) -> f64 {
    account
        .subscription_active_until
        .as_deref()
        .and_then(|raw| chrono::DateTime::parse_from_rfc3339(raw).ok())
        .map(|dt| dt.timestamp() as f64)
        .unwrap_or(f64::MAX)
}

/// Orders accounts the way the gateway should try them, and returns the ids
/// that the planner paused (window exhausted or below the reserve).
pub fn resolve(
    accounts: &[Account],
    strategy: &str,
    manual_order: &[String],
) -> (Vec<String>, Vec<String>) {
    let mut manual_index: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for (index, id) in manual_order.iter().enumerate() {
        manual_index.entry(id.as_str()).or_insert(index);
    }

    let mut sorted: Vec<&Account> = accounts.iter().collect();
    sorted.sort_by(|lhs, rhs| {
        let group = |account: &Account| -> i32 {
            match (account.is_backup.unwrap_or(false), account.is_blocked()) {
                (false, false) => 0,
                (true, false) => 1,
                (false, true) => 2,
                (true, true) => 3,
            }
        };
        let left_group = group(lhs);
        let right_group = group(rhs);
        if left_group != right_group {
            return left_group.cmp(&right_group);
        }

        if strategy != "custom" {
            let left_preferred = if lhs.preferred_first.unwrap_or(false) { 0 } else { 1 };
            let right_preferred = if rhs.preferred_first.unwrap_or(false) { 0 } else { 1 };
            if left_preferred != right_preferred {
                return left_preferred.cmp(&right_preferred);
            }
        }

        match strategy {
            "custom" => {
                let left = manual_index.get(lhs.id.as_str()).copied().unwrap_or(usize::MAX);
                let right = manual_index.get(rhs.id.as_str()).copied().unwrap_or(usize::MAX);
                left.cmp(&right)
            }
            "quotaLowFirst" => quota_score(lhs)
                .partial_cmp(&quota_score(rhs))
                .unwrap_or(std::cmp::Ordering::Equal),
            "planHighFirst" => plan_rank(rhs).cmp(&plan_rank(lhs)),
            "planLowFirst" => plan_rank(lhs).cmp(&plan_rank(rhs)),
            "expirySoonFirst" => expiry_unix(lhs)
                .partial_cmp(&expiry_unix(rhs))
                .unwrap_or(std::cmp::Ordering::Equal),
            // auto, quotaHighFirst
            _ => quota_score(rhs)
                .partial_cmp(&quota_score(lhs))
                .unwrap_or(std::cmp::Ordering::Equal),
        }
    });

    let ordered_ids: Vec<String> = sorted.iter().map(|a| a.id.clone()).collect();
    let blocked_ids: Vec<String> = sorted
        .iter()
        .filter(|a| a.is_blocked())
        .map(|a| a.id.clone())
        .collect();
    (ordered_ids, blocked_ids)
}

/// Quota freshness helper used by the UI-side view too.
pub fn quota_is_fresh(updated_ref: Option<f64>) -> bool {
    match updated_ref {
        Some(updated) => crate::vault::now_ref() - updated < 1800.0,
        None => false,
    }
}

pub fn _unused_reference() -> f64 {
    APPLE_REF_UNIX_OFFSET
}
