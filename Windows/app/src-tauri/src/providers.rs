//! Provider metrics: OpenRouter balance, key limits and the Claude
//! (Anthropic) subscription status.

use serde_json::{json, Value};

use crate::claude;
use crate::settings::Settings;

async fn http_json(client: &reqwest::Client, url: &str, key: &str) -> Result<Value, String> {
    let resp = client
        .get(url)
        .header("Authorization", format!("Bearer {}", key))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!(
            "{}: {}",
            status.as_u16(),
            text.chars().take(200).collect::<String>()
        ));
    }
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

pub async fn openrouter(key: &str) -> Result<Value, String> {
    if key.trim().is_empty() {
        return Err("ключ OpenRouter не задан".to_string());
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|e| e.to_string())?;

    let credits = http_json(&client, "https://openrouter.ai/api/v1/credits", key).await?;
    let key_info = http_json(&client, "https://openrouter.ai/api/v1/key", key)
        .await
        .ok();

    let total = credits
        .pointer("/data/total_credits")
        .and_then(|v| v.as_f64());
    let usage = credits
        .pointer("/data/total_usage")
        .and_then(|v| v.as_f64());

    Ok(json!({
        "totalCredits": total,
        "totalUsage": usage,
        "remaining": match (total, usage) { (Some(t), Some(u)) => Some(t - u), _ => None },
        "label": key_info.as_ref().and_then(|k| k.pointer("/data/label")).and_then(|v| v.as_str()),
        "usage": key_info.as_ref().and_then(|k| k.pointer("/data/usage")).and_then(|v| v.as_f64()),
        "limit": key_info.as_ref().and_then(|k| k.pointer("/data/limit")).and_then(|v| v.as_f64()),
        "limitRemaining": key_info.as_ref().and_then(|k| k.pointer("/data/limit_remaining")).and_then(|v| v.as_f64()),
        "isFreeTier": key_info.as_ref().and_then(|k| k.pointer("/data/is_free_tier")).and_then(|v| v.as_bool()),
        "status": "ok",
    }))
}

/// Claude (Anthropic) metrics for the Providers page: connection status, the
/// account email, the two quota windows and the model count the gateway
/// serves. Without an auth file the account is not connected; without a usage
/// answer every number stays `null` ("—") — nothing is fabricated.
pub async fn claude(settings: &Settings) -> Result<Value, String> {
    let model_count = claude::models(settings.port, &settings.api_key)
        .await
        .ok()
        .and_then(|value| value.get("count").and_then(|c| c.as_u64()))
        .unwrap_or(0) as usize;
    let Some(file) = claude::newest_auth_file() else {
        return Ok(claude_metrics(false, None, None, model_count, None));
    };
    let usage = claude::usage_snapshot(settings).await;
    Ok(claude_metrics(
        true,
        file.email.clone(),
        usage.as_ref(),
        model_count,
        None,
    ))
}

/// Assembles the Claude metrics object. Pure, so the nil-tolerance is
/// testable without a gateway.
pub fn claude_metrics(
    connected: bool,
    email: Option<String>,
    usage: Option<&claude::UsageSnapshot>,
    model_count: usize,
    error: Option<String>,
) -> Value {
    json!({
        "connected": connected,
        "email": email,
        "plan": usage.and_then(|u| u.plan.clone()),
        "fiveHourPercent": usage.and_then(|u| u.five_hour_percent),
        "fiveHourReset": usage.and_then(|u| u.five_hour_reset.clone()),
        "weeklyPercent": usage.and_then(|u| u.weekly_percent),
        "weeklyReset": usage.and_then(|u| u.weekly_reset.clone()),
        "modelCount": model_count,
        "updatedAt": usage.map(|_| chrono::Utc::now().to_rfc3339()),
        "error": error,
        "status": "ok",
    })
}

#[cfg(test)]
mod tests {
    use super::claude_metrics;
    use crate::claude::UsageSnapshot;

    #[test]
    fn claude_metrics_without_account_stays_empty() {
        let value = claude_metrics(false, None, None, 0, None);
        assert_eq!(value["connected"], false);
        assert_eq!(value["email"], serde_json::Value::Null);
        assert_eq!(value["plan"], serde_json::Value::Null);
        assert_eq!(value["fiveHourPercent"], serde_json::Value::Null);
        assert_eq!(value["fiveHourReset"], serde_json::Value::Null);
        assert_eq!(value["weeklyPercent"], serde_json::Value::Null);
        assert_eq!(value["weeklyReset"], serde_json::Value::Null);
        assert_eq!(value["modelCount"], 0);
        assert_eq!(value["updatedAt"], serde_json::Value::Null);
    }

    #[test]
    fn claude_metrics_carry_the_snapshot_values() {
        let snapshot = UsageSnapshot {
            five_hour_percent: Some(87.5),
            five_hour_reset: Some("2026-10-19T20:00:00+00:00".to_string()),
            weekly_percent: None,
            weekly_reset: None,
            plan: Some("pro".to_string()),
        };
        let value = claude_metrics(
            true,
            Some("user@example.com".to_string()),
            Some(&snapshot),
            4,
            None,
        );
        assert_eq!(value["connected"], true);
        assert_eq!(value["email"], "user@example.com");
        assert_eq!(value["fiveHourPercent"], 87.5);
        assert_eq!(value["fiveHourReset"], "2026-10-19T20:00:00+00:00");
        assert_eq!(value["weeklyPercent"], serde_json::Value::Null);
        assert_eq!(value["plan"], "pro");
        assert_eq!(value["modelCount"], 4);
        assert!(value["updatedAt"].as_str().is_some());

        let failing = claude_metrics(true, None, None, 0, Some("нет связи".to_string()));
        assert_eq!(failing["error"], "нет связи");
        assert_eq!(failing["updatedAt"], serde_json::Value::Null);
    }
}
