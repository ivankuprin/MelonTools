//! The Codex client route: `model_provider` + `[model_providers.<id>]` in
//! `%USERPROFILE%\.codex\config.toml` (line-based editing, ported from the
//! macOS app) plus the model catalog the Codex picker reads.

use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

use crate::paths;

pub const PROVIDER_ID: &str = "melon_local_access";
const PROVIDER_NAME: &str = "Melon Tools API";
pub const CATALOG_FILE: &str = "melon-model-catalog.json";

fn config_path() -> PathBuf {
    paths::codex_home().join("config.toml")
}

// MARK: - Line transforms (pure, mirrored from CodexConfigRoute.swift)

fn first_header(lines: &[String]) -> usize {
    lines
        .iter()
        .position(|l| l.trim_start().starts_with('['))
        .unwrap_or(lines.len())
}

fn raw_value(line: &str, key: &str) -> Option<String> {
    let trimmed = line.trim();
    if !trimmed.starts_with(key) {
        return None;
    }
    let rest = trimmed[key.len()..].trim_start();
    if !rest.starts_with('=') {
        return None;
    }
    let mut value = rest[1..].trim().to_string();
    if let Some(hash) = value.find('#') {
        value = value[..hash].trim().to_string();
    }
    Some(value.trim_matches(|c| c == '"' || c == '\'').to_string())
}

fn provider_value(line: &str) -> Option<String> {
    raw_value(line, "model_provider").filter(|v| !v.is_empty())
}

fn table_bounds(lines: &[String], id: &str) -> Option<(usize, usize)> {
    let header = format!("[model_providers.{}]", id);
    let mut start: Option<usize> = None;
    for (index, raw) in lines.iter().enumerate() {
        let line = raw.trim();
        if line == header {
            if start.is_none() {
                start = Some(index);
            }
            continue;
        }
        if let Some(s) = start {
            if index > s && line.starts_with('[') {
                return Some((s, index));
            }
        }
    }
    start.map(|s| (s, lines.len()))
}

fn normalized(mut lines: Vec<String>, ends_with_newline: bool) -> String {
    if ends_with_newline {
        if lines.last().map(|l| !l.is_empty()).unwrap_or(true) {
            lines.push(String::new());
        }
    } else if lines.last().map(|l| l.is_empty()).unwrap_or(false) {
        lines.pop();
    }
    lines.join("\n")
}

fn to_lines(text: &str) -> Vec<String> {
    text.split('\n').map(String::from).collect()
}

pub fn upsert_route(in_text: &str, base_url: &str, token: &str) -> String {
    let ends = in_text.ends_with('\n');
    let mut lines = to_lines(in_text);
    let header = first_header(&lines);
    let provider_line = format!("model_provider = \"{}\"", PROVIDER_ID);
    let mut replaced = false;
    for index in 0..header {
        if provider_value(&lines[index]).is_some() {
            lines[index] = provider_line.clone();
            replaced = true;
            break;
        }
    }
    if !replaced {
        lines.insert(0, provider_line);
        if lines.len() > 1 && !lines[1].is_empty() {
            lines.insert(1, String::new());
        }
    }
    let block = vec![
        format!("[model_providers.{}]", PROVIDER_ID),
        format!("name = \"{}\"", PROVIDER_NAME),
        format!("base_url = \"{}\"", base_url),
        "wire_api = \"responses\"".to_string(),
        "requires_openai_auth = true".to_string(),
        format!("experimental_bearer_token = \"{}\"", token),
        "supports_websockets = false".to_string(),
    ];
    if let Some((start, end)) = table_bounds(&lines, PROVIDER_ID) {
        lines.splice(start..end, block);
    } else {
        if lines.last().map(|l| !l.is_empty()).unwrap_or(false) {
            lines.push(String::new());
        }
        lines.extend(block);
    }
    normalized(lines, ends)
}

pub fn remove_route(in_text: &str) -> String {
    let ends = in_text.ends_with('\n');
    let mut lines = to_lines(in_text);
    if let Some((start, end)) = table_bounds(&lines, PROVIDER_ID) {
        lines.drain(start..end);
    }
    let header = first_header(&lines);
    for index in 0..header {
        if provider_value(&lines[index]).as_deref() == Some(PROVIDER_ID) {
            lines.remove(index);
            break;
        }
    }
    normalized(lines, ends)
}

pub fn upsert_top_level_key(in_text: &str, key: &str, value: &str) -> String {
    let ends = in_text.ends_with('\n');
    let mut lines = to_lines(in_text);
    let header = first_header(&lines);
    let line = format!("{} = \"{}\"", key, value);
    for index in 0..header {
        if raw_value(&lines[index], key).is_some() {
            lines[index] = line;
            return normalized(lines, ends);
        }
    }
    let mut insert_at = 0;
    for index in 0..header {
        if provider_value(&lines[index]).is_some() {
            insert_at = index + 1;
            break;
        }
    }
    lines.insert(insert_at, line);
    normalized(lines, ends)
}

pub fn remove_top_level_key(in_text: &str, key: &str) -> String {
    let ends = in_text.ends_with('\n');
    let mut lines = to_lines(in_text);
    let header = first_header(&lines);
    for index in 0..header {
        if raw_value(&lines[index], key).is_some() {
            lines.remove(index);
            break;
        }
    }
    normalized(lines, ends)
}

// MARK: - High level

/// Atomic replace: the sibling temp file is renamed over the target, so a
/// crash mid-write cannot truncate config.toml. The file holds the gateway
/// bearer token, hence 0600 on Unix hosts (Windows uses the user-profile ACL).
fn write_atomic(path: &Path, data: &str) -> Result<(), String> {
    let tmp = paths::tmp_path(path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

/// Writes (or updates) the Melon route in config.toml, pointing Codex at the
/// local gateway. A one-time backup of the previous file is kept.
pub fn apply(port: u16, api_key: &str) -> Result<(), String> {
    let path = config_path();
    let current = std::fs::read_to_string(&path).unwrap_or_default();
    if !current.is_empty() {
        let backup = path.with_extension("toml.melon-backup");
        if !backup.exists() {
            let _ = std::fs::copy(&path, &backup);
        }
    }
    let mut updated = upsert_route(
        &current,
        &format!("http://127.0.0.1:{}/v1", port),
        api_key,
    );
    updated = upsert_top_level_key(&updated, "model_catalog_json", CATALOG_FILE);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    write_atomic(&path, &updated)
}

/// Removes the Melon route (and the catalog reference, which would otherwise
/// stop the Codex app from starting when the file is gone).
pub fn remove() -> Result<(), String> {
    let path = config_path();
    let Ok(current) = std::fs::read_to_string(&path) else {
        return Ok(());
    };
    let mut updated = remove_route(&current);
    updated = remove_top_level_key(&updated, "model_catalog_json");
    write_atomic(&path, &updated)
}

/// What the route looks like right now, for the UI.
pub fn status() -> Value {
    let path = config_path();
    let current = std::fs::read_to_string(&path).unwrap_or_default();
    let lines = to_lines(&current);
    let header = first_header(&lines);
    let mut provider = None;
    for index in 0..header {
        if let Some(value) = provider_value(&lines[index]) {
            provider = Some(value);
            break;
        }
    }
    let catalog = paths::codex_home().join(CATALOG_FILE);
    json!({
        "configPath": path.to_string_lossy(),
        "provider": provider,
        "ours": provider.as_deref() == Some(PROVIDER_ID),
        "catalogExists": catalog.exists(),
        "catalogPath": catalog.to_string_lossy(),
    })
}

// MARK: - Model catalog

/// Readable name for a raw model id. Numeric groups keep their dotted form
/// (`claude-opus-5-5` → `Claude Opus 5.5`), matching the macOS catalogue.
pub fn prettify(alias: &str) -> String {
    let tail = alias.rsplit('/').next().unwrap_or(alias);
    let mut words: Vec<String> = Vec::new();
    let mut previous_numeric = false;
    for word in tail.split(|c| c == '-' || c == '_') {
        if word.is_empty() {
            continue;
        }
        let numeric = word.chars().all(|c| c.is_ascii_digit());
        if numeric && previous_numeric {
            if let Some(last) = words.last_mut() {
                last.push('.');
                last.push_str(word);
                continue;
            }
        }
        words.push(capitalize(word));
        previous_numeric = numeric;
    }
    words.join(" ")
}

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// Best-effort vision-capability heuristic for a gateway model id.
///
/// Codex decides whether the composer accepts pasted images from the catalog
/// entry's `input_modalities`. Provider entries are cloned from a base entry,
/// so the per-model answer has to come from the id. Routing prefixes
/// (`openrouter/anthropic/...`) are ignored, and the heuristic is deliberately
/// conservative: unknown ids stay text-only until the family is known here.
pub fn vision_capable(model_id: &str, owned_by: Option<&str>) -> bool {
    let id = model_id.to_ascii_lowercase();
    let tail = id.rsplit('/').next().unwrap_or(&id);
    let owner = owned_by.unwrap_or("").to_ascii_lowercase();

    // Text-only and generation-only families first: they must not inherit
    // vision from a broader prefix below.
    if tail.starts_with("gpt-oss-") {
        return false;
    }
    if ["dall-e", "flux", "stable-diffusion", "imagen", "gpt-image", "embed"]
        .iter()
        .any(|marker| tail.contains(marker))
    {
        return false;
    }

    // Claude and Gemini are multimodal on every gateway this app routes.
    // `gemini-*-image` still accepts image input, so the whole family is true.
    if tail.starts_with("claude-") || owner.contains("anthropic") {
        return true;
    }
    if tail.starts_with("gemini-") || owner.contains("antigravity") {
        return true;
    }

    // OpenAI GPT families with image input.
    if tail.starts_with("gpt-4o")
        || tail.starts_with("gpt-4.1")
        || tail.starts_with("gpt-5")
        || tail.starts_with("gpt-6")
    {
        return true;
    }

    // OpenRouter vision families.
    if (tail.starts_with("qwen") && tail.contains("-vl"))
        || (tail.starts_with("llama") && tail.contains("vision"))
        || (tail.starts_with("mistral") && tail.contains("vision"))
        || (tail.starts_with("gemma") && tail.contains("vision"))
        || (tail.starts_with("grok-") && tail.contains("vision"))
        || tail.contains("pixtral")
        || tail.contains("internvl")
        || tail.contains("llava")
        || (tail.starts_with("glm-") && glm_vision_suffix(tail))
    {
        return true;
    }

    false
}

/// `glm-*-v` ids (`glm-4.5v`, `glm-4.6-v`) but not plain `glm-5.3`.
fn glm_vision_suffix(tail: &str) -> bool {
    tail.split('-').skip(1).any(|part| {
        part == "v"
            || (part.ends_with('v')
                && part[..part.len() - 1]
                    .chars()
                    .any(|c| c.is_ascii_digit()))
    })
}

/// Priority band and provider tag of a gateway model id. One band per provider
/// keeps the Codex picker grouped (pool → OpenCode → OpenRouter → Claude →
/// Antigravity); `None` for ids this app does not publish.
///
/// Antigravity also serves `claude-*` ids, so its registry allowlist is checked
/// before the Claude prefix. Callers that have the `/v1/models` entry should
/// use [`third_party_band_for_model`] so ownership wins over id overlap.
pub fn third_party_band(id: &str) -> Option<(&'static str, i32)> {
    if crate::antigravity::is_antigravity_model_id(id) {
        Some(("Antigravity", 400))
    } else if id.starts_with("opencode/") {
        Some(("opencode", 100))
    } else if id.starts_with("openrouter/") {
        Some(("openrouter", 200))
    } else if crate::claude::is_claude_model_id(id) {
        Some(("Claude", 300))
    } else {
        None
    }
}

/// Band for a full `/v1/models` entry. Ownership data (`owned_by`/`type`) wins
/// when the engine provides it, which resolves the `claude-sonnet-4-6` overlap
/// between the Claude and Antigravity registries.
pub fn third_party_band_for_model(entry: &Value) -> Option<(&'static str, i32)> {
    let id = entry.get("id").and_then(|value| value.as_str())?;
    if crate::antigravity::is_antigravity_model_entry(entry) {
        Some(("Antigravity", 400))
    } else if id.starts_with("opencode/") {
        Some(("opencode", 100))
    } else if id.starts_with("openrouter/") {
        Some(("openrouter", 200))
    } else if crate::claude::is_claude_model_id(id) {
        Some(("Claude", 300))
    } else {
        None
    }
}

/// Provider tag shown by the picker and the chips. Consumed by the tests and
/// kept as the shared contract for the bridge's provider labels (`bridge.rs`
/// still maps everything unknown to `openai` — wiring it up is a follow-up).
#[allow(dead_code)]
pub fn provider_tag(slug: &str) -> &'static str {
    third_party_band(slug).map(|(tag, _)| tag).unwrap_or("openai")
}

const PRIVATE_CATALOG_KEYS: &[&str] = &[
    "base_instructions",
    "model_messages",
    "policy",
    "policy_template",
    "node_repl_policy",
    "rejection_instructions",
    "timeout_instructions",
    "experimental_supported_tools",
    "instructions_variables",
];

fn strip_private_catalog_metadata(value: &mut Value) {
    match value {
        Value::Object(object) => {
            for key in PRIVATE_CATALOG_KEYS {
                object.remove(*key);
            }
            for child in object.values_mut() {
                strip_private_catalog_metadata(child);
            }
        }
        Value::Array(items) => {
            for item in items {
                strip_private_catalog_metadata(item);
            }
        }
        _ => {}
    }
}

/// Builds one provider catalog entry from the bundled base template. Image
/// input is written explicitly: a plain clone would keep the template's
/// modalities for every provider model, which is what made Codex reject pasted
/// images for vision ids (and would otherwise advertise them for text-only ids).
fn custom_catalog_entry(
    template: &Value,
    id: &str,
    owned_by: Option<&str>,
    band: i32,
    index: usize,
) -> Value {
    let mut entry = template.clone();
    entry["slug"] = json!(id);
    entry["display_name"] = json!(prettify(id));
    entry["priority"] = json!(band + index as i32);
    entry["input_modalities"] = if vision_capable(id, owned_by) {
        json!(["text", "image"])
    } else {
        json!(["text"])
    };
    entry["supports_image_detail_original"] = json!(false);
    entry
}

/// Regenerates `%~/.codex/melon-model-catalog.json`: the bundled base entries
/// (account-pool models) plus one cloned entry per gateway model that is not
/// in the pool list (opencode/*, openrouter/*). Returns the custom count.
pub async fn sync_catalog(
    client: &reqwest::Client,
    port: u16,
    api_key: &str,
) -> Result<usize, String> {
    let base: Value =
        serde_json::from_str(include_str!("../../resources/BaseModelCatalog.json"))
            .map_err(|e| e.to_string())?;
    let mut models: Vec<Value> = base
        .get("models")
        .and_then(|m| m.as_array())
        .cloned()
        .unwrap_or_default();
    for model in &mut models {
        strip_private_catalog_metadata(model);
    }
    if models.is_empty() {
        return Err("базовый каталог пуст".to_string());
    }
    let pool_slugs: HashSet<String> = models
        .iter()
        .filter_map(|m| m.get("slug").and_then(|s| s.as_str()).map(String::from))
        .collect();
    let template = models
        .iter()
        .find(|m| m.get("slug").and_then(|v| v.as_str()) == Some("gpt-6.1-sol"))
        .or_else(|| models.iter().find(|m| m.get("context_window").is_some()))
        .cloned()
        .ok_or_else(|| "нет шаблонной записи".to_string())?;

    let list: Value = client
        .get(format!("http://127.0.0.1:{}/v1/models", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())?;
    let mut entries: Vec<Value> = list
        .get("data")
        .and_then(|d| d.as_array())
        .cloned()
        .unwrap_or_default();
    // Ownership-aware: when the same id is served by both Claude and
    // Antigravity, the Antigravity entry wins the band.
    entries.sort_by_key(|entry| !crate::antigravity::is_antigravity_model_entry(entry));

    let mut custom = 0usize;
    let mut seen: HashSet<String> = HashSet::new();
    let mut opencode_index = 0usize;
    let mut openrouter_index = 0usize;
    let mut claude_index = 0usize;
    let mut antigravity_index = 0usize;
    for entry in entries {
        let Some(id) = entry.get("id").and_then(|v| v.as_str()).map(String::from) else {
            continue;
        };
        if pool_slugs.contains(&id) || !seen.insert(id.clone()) {
            continue;
        }
        let Some((tag, band)) = third_party_band_for_model(&entry) else {
            continue;
        };
        let index = match tag {
            "opencode" => {
                let index = opencode_index;
                opencode_index += 1;
                index
            }
            "openrouter" => {
                let index = openrouter_index;
                openrouter_index += 1;
                index
            }
            "Antigravity" => {
                let index = antigravity_index;
                antigravity_index += 1;
                index
            }
            _ => {
                let index = claude_index;
                claude_index += 1;
                index
            }
        };
        let owned_by = entry.get("owned_by").and_then(|v| v.as_str());
        let generated = custom_catalog_entry(&template, &id, owned_by, band, index);
        models.push(generated);
        custom += 1;
    }

    let payload = json!({ "models": models });
    let path = paths::codex_home().join(CATALOG_FILE);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let data = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    std::fs::write(&path, data).map_err(|e| e.to_string())?;
    Ok(custom)
}

#[cfg(test)]
mod tests {
    use super::{
        custom_catalog_entry, prettify, provider_tag, strip_private_catalog_metadata,
        third_party_band, third_party_band_for_model, vision_capable,
    };
    use serde_json::json;

    #[test]
    fn claude_ids_get_band_300_and_the_claude_tag() {
        assert_eq!(third_party_band("claude-opus-5-5"), Some(("Claude", 300)));
        assert_eq!(third_party_band("claude-haiku-4-5-20251001"), Some(("Claude", 300)));
        assert_eq!(provider_tag("claude-opus-5-5"), "Claude");
        // The existing bands stay untouched.
        assert_eq!(third_party_band("opencode/glm-5.3"), Some(("opencode", 100)));
        assert_eq!(third_party_band("openrouter/x-ai/grok-4.7"), Some(("openrouter", 200)));
        // Account-pool ids are not published by this path.
        assert_eq!(third_party_band("gpt-6.1-sol"), None);
        assert_eq!(provider_tag("gpt-6.1-sol"), "openai");
    }

    #[test]
    fn antigravity_ids_get_band_400_and_the_antigravity_tag() {
        assert_eq!(
            third_party_band("gemini-3-flash"),
            Some(("Antigravity", 400))
        );
        assert_eq!(
            third_party_band("claude-opus-4-6-thinking"),
            Some(("Antigravity", 400))
        );
        // Antigravity also serves claude-* ids; its allowlist must win over
        // the Claude prefix.
        assert_eq!(
            third_party_band("claude-sonnet-4-6"),
            Some(("Antigravity", 400))
        );
        assert_eq!(provider_tag("gemini-3-flash"), "Antigravity");
        assert_eq!(provider_tag("claude-opus-4-6-thinking"), "Antigravity");

        // Ownership data resolves the overlap: an anthropic-owned
        // claude-sonnet-4-6 stays in the Claude band.
        assert_eq!(
            third_party_band_for_model(&json!({
                "id": "claude-sonnet-4-6",
                "owned_by": "anthropic",
                "type": "claude"
            })),
            Some(("Claude", 300))
        );
        assert_eq!(
            third_party_band_for_model(&json!({
                "id": "claude-sonnet-4-6",
                "owned_by": "antigravity",
                "type": "antigravity"
            })),
            Some(("Antigravity", 400))
        );
        // Without ownership the registry allowlist is the fallback.
        assert_eq!(
            third_party_band_for_model(&json!({"id": "gemini-3-flash"})),
            Some(("Antigravity", 400))
        );

        // The existing bands stay untouched.
        assert_eq!(third_party_band("opencode/glm-5.3"), Some(("opencode", 100)));
        assert_eq!(
            third_party_band("openrouter/x-ai/grok-4.7"),
            Some(("openrouter", 200))
        );
        assert_eq!(third_party_band("gpt-6.1-sol"), None);
    }

    #[test]
    fn claude_display_names_keep_dotted_versions() {
        assert_eq!(prettify("claude-opus-5-5"), "Claude Opus 5.5");
        assert_eq!(prettify("claude-sonnet-4-6"), "Claude Sonnet 4.6");
        assert_eq!(prettify("opencode/claude-haiku-5-5"), "Claude Haiku 5.5");
        assert_eq!(prettify("deepseek-v4.1-flash"), "Deepseek V4.1 Flash");
        assert_eq!(prettify("glm-5.3"), "Glm 5.3");
    }

    #[test]
    fn private_catalog_metadata_is_removed_recursively() {
        let mut value = json!({
            "slug": "sample-model",
            "base_instructions": "private fixture",
            "nested": {
                "policy": "private fixture",
                "safe": true,
                "items": [{"timeout_instructions": "private fixture", "enabled": true}]
            }
        });

        strip_private_catalog_metadata(&mut value);

        assert_eq!(value["slug"], "sample-model");
        assert!(value.get("base_instructions").is_none());
        assert!(value["nested"].get("policy").is_none());
        assert_eq!(value["nested"]["safe"], true);
        assert!(value["nested"]["items"][0].get("timeout_instructions").is_none());
    }

    #[test]
    fn vision_heuristic_accepts_known_vision_models() {
        assert!(vision_capable("claude-sonnet-4-6", Some("anthropic")));
        assert!(vision_capable(
            "openrouter/anthropic/claude-sonnet-4.6",
            Some("openrouter")
        ));
        assert!(vision_capable("gemini-3-flash", Some("antigravity")));
        assert!(vision_capable("gemini-2.5-flash-image", None));
        assert!(vision_capable("qwen2.5-vl-72b-instruct", None));
        assert!(vision_capable("gpt-4o-mini", None));
        assert!(vision_capable("gpt-5.1", None));
        assert!(vision_capable("openrouter/meta-llama/llama-3.2-11b-vision", None));
        assert!(vision_capable("mistralai/pixtral-large", None));
        assert!(vision_capable("glm-4.5v", None));
    }

    #[test]
    fn vision_heuristic_rejects_text_and_generation_models() {
        assert!(!vision_capable("gpt-oss-120b-medium", Some("openai")));
        assert!(!vision_capable("dall-e-3", Some("openai")));
        assert!(!vision_capable("flux-1.1-pro", None));
        assert!(!vision_capable("stable-diffusion-3.5", None));
        assert!(!vision_capable("imagen-3.0", None));
        assert!(!vision_capable("gpt-image-1", Some("openai")));
        assert!(!vision_capable("text-embedding-3-large", Some("openai")));
        assert!(!vision_capable("glm-5.3", None));
        assert!(!vision_capable("unknown-model", None));
    }

    #[test]
    fn catalog_entry_writes_input_modalities_from_the_heuristic() {
        let template = json!({
            "slug": "gpt-6.1-sol",
            "display_name": "GPT-6.1 Sol",
            "context_window": 272000,
            "input_modalities": ["text"],
            "supports_image_detail_original": true
        });

        let vision = custom_catalog_entry(
            &template,
            "openrouter/qwen2.5-vl-72b",
            Some("openrouter"),
            200,
            3,
        );
        assert_eq!(vision["input_modalities"], json!(["text", "image"]));
        assert_eq!(vision["supports_image_detail_original"], json!(false));
        assert_eq!(vision["slug"], json!("openrouter/qwen2.5-vl-72b"));
        assert_eq!(vision["priority"], json!(203));

        let text = custom_catalog_entry(&template, "gpt-oss-120b-medium", Some("openai"), 200, 4);
        assert_eq!(text["input_modalities"], json!(["text"]));
        assert_eq!(text["supports_image_detail_original"], json!(false));
        assert_eq!(text["priority"], json!(204));
    }
}
