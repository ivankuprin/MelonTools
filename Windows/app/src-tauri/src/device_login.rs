//! Device login: add a new ChatGPT account to the pool without a browser
//! callback — the code is entered at auth.openai.com/codex/device.
//! Ported from CodexService.swift (startDeviceLogin / pollDeviceLogin).

use serde_json::{json, Value};

use crate::vault::Tokens;

const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const USER_CODE_ENDPOINT: &str = "https://auth.openai.com/api/accounts/deviceauth/usercode";
const TOKEN_ENDPOINT: &str = "https://auth.openai.com/api/accounts/deviceauth/token";
const OAUTH_TOKEN_ENDPOINT: &str = "https://auth.openai.com/oauth/token";
const VERIFICATION_URL: &str = "https://auth.openai.com/codex/device";
const REDIRECT_URI: &str = "https://auth.openai.com/deviceauth/callback";
const USER_AGENT: &str = "Codex Desktop (Windows)";

fn short(text: &str) -> String {
    text.chars().take(200).collect()
}

/// Requests a user code: the user opens `verificationURL` and enters it.
pub async fn start(client: &reqwest::Client) -> Result<Value, String> {
    let resp = client
        .post(USER_CODE_ENDPOINT)
        .header("User-Agent", USER_AGENT)
        .json(&json!({ "client_id": CLIENT_ID }))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("{}: {}", status.as_u16(), short(&text)));
    }
    let obj: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let device_auth_id = obj
        .get("device_auth_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "в ответе нет device_auth_id".to_string())?;
    let user_code = obj
        .get("user_code")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "в ответе нет user_code".to_string())?;
    let interval = obj.get("interval").and_then(|v| v.as_i64()).unwrap_or(5);
    Ok(json!({
        "deviceAuthId": device_auth_id,
        "userCode": user_code,
        "interval": interval,
        "verificationURL": VERIFICATION_URL,
    }))
}

/// One poll attempt: `Ok(Some(tokens))` when the user finished the flow,
/// `Ok(None)` while still pending.
pub async fn poll(
    client: &reqwest::Client,
    device_auth_id: &str,
    user_code: &str,
) -> Result<Option<Tokens>, String> {
    let resp = client
        .post(TOKEN_ENDPOINT)
        .header("User-Agent", USER_AGENT)
        .json(&json!({
            "device_auth_id": device_auth_id,
            "user_code": user_code,
        }))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    match status {
        200 => {
            let obj: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
            let code = obj
                .get("authorization_code")
                .and_then(|v| v.as_str())
                .ok_or_else(|| "в ответе нет authorization_code".to_string())?;
            let verifier = obj
                .get("code_verifier")
                .and_then(|v| v.as_str())
                .ok_or_else(|| "в ответе нет code_verifier".to_string())?;
            exchange_code(client, code, verifier).await.map(Some)
        }
        403 | 404 => Ok(None),
        other => Err(format!("{}: {}", other, short(&text))),
    }
}

async fn exchange_code(
    client: &reqwest::Client,
    code: &str,
    verifier: &str,
) -> Result<Tokens, String> {
    let params = [
        ("grant_type", "authorization_code"),
        ("code", code),
        ("redirect_uri", REDIRECT_URI),
        ("client_id", CLIENT_ID),
        ("code_verifier", verifier),
    ];
    let resp = client
        .post(OAUTH_TOKEN_ENDPOINT)
        .header("User-Agent", USER_AGENT)
        .form(&params)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("{}: {}", status.as_u16(), short(&text)));
    }
    let obj: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let access = obj
        .get("access_token")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "в ответе нет access_token".to_string())?;
    Ok(Tokens {
        id_token: obj
            .get("id_token")
            .and_then(|v| v.as_str())
            .map(String::from),
        access_token: Some(access.to_string()),
        refresh_token: obj
            .get("refresh_token")
            .and_then(|v| v.as_str())
            .map(String::from),
        account_id: None,
    })
}
