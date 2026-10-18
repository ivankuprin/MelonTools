//! Provider metrics: OpenRouter balance and key limits.

use serde_json::{json, Value};

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
