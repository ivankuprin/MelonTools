//! Windows DPAPI at rest for vault/settings secrets.
//!
//! Stored values use the `dpapi2:<base64>` prefix, where `<base64>` is the
//! output of `CryptProtectData` with the fixed application entropy
//! [`ENTROPY`]. The protection is scoped to the current Windows user: another
//! user or machine cannot decrypt the file.
//!
//! Legacy `dpapi:<base64>` values (v1, no entropy) are still decrypted on
//! read; the next save writes the v2 format. Plaintext values (no prefix) are
//! read unchanged and encrypted by the next save. A plaintext value that
//! starts with a reserved tag (`dpapi:`, `dpapi2:`, `plain:`) is stored as
//! `plain:<base64>` so it can never be mistaken for ciphertext.
//!
//! Undecryptable values are reported as [`Undecryptable`]; callers treat them
//! as unset (settings) or require a re-login (vault). They are never passed
//! onward as if they were secrets.
//!
//! Host builds (macOS/Linux tests) cannot call DPAPI: `protect` stores the
//! plaintext (escaped when needed) and `unprotect` only handles plaintext and
//! `plain:` tags. The Windows branch is compiled by the `cargo xwin build`
//! target; the syscalls themselves need a real Windows run.

use base64::Engine;
use zeroize::Zeroizing;

/// Prefix for v1 DPAPI payloads (no entropy). Read-only, kept for migration.
pub const PREFIX_V1: &str = "dpapi:";
/// Prefix for v2 DPAPI payloads (application entropy).
pub const PREFIX_V2: &str = "dpapi2:";
/// Prefix for base64-encoded plaintext that would otherwise look like a tag.
pub const PREFIX_PLAIN: &str = "plain:";

/// Fixed application entropy for v2 payloads. It binds the ciphertext to
/// Melon Tools and must be identical on protect and unprotect.
const ENTROPY: &[u8] = b"melontools-dpapi-v2";

/// A stored value that claims to be protected but cannot be decoded or
/// decrypted (wrong user/machine, corrupt file, unknown format).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Undecryptable;

impl std::fmt::Display for Undecryptable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("secret is not decryptable")
    }
}

impl std::error::Error for Undecryptable {}

/// True when the stored value carries a DPAPI prefix.
pub fn is_protected(value: &str) -> bool {
    value.starts_with(PREFIX_V1) || value.starts_with(PREFIX_V2)
}

fn is_reserved(value: &str) -> bool {
    is_protected(value) || value.starts_with(PREFIX_PLAIN)
}

fn wrap(prefix: &str, encrypted: &[u8]) -> String {
    format!(
        "{}{}",
        prefix,
        base64::engine::general_purpose::STANDARD.encode(encrypted)
    )
}

fn decode_payload(encoded: &str) -> Result<Vec<u8>, Undecryptable> {
    base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| Undecryptable)
}

/// Escape a plaintext value whose first bytes look like a storage tag.
/// The copy is zeroized when the caller drops it.
fn escape_reserved(value: &str) -> Zeroizing<String> {
    if is_reserved(value) {
        let encoded = Zeroizing::new(
            base64::engine::general_purpose::STANDARD.encode(value.as_bytes()),
        );
        Zeroizing::new(format!("{}{}", PREFIX_PLAIN, encoded.as_str()))
    } else {
        Zeroizing::new(value.to_string())
    }
}

/// Decode a `plain:<base64>` payload back to its original string.
fn decode_plain(encoded: &str) -> Result<String, Undecryptable> {
    let bytes = Zeroizing::new(decode_payload(encoded)?);
    std::str::from_utf8(&bytes)
        .map(str::to_owned)
        .map_err(|_| Undecryptable)
}

/// A decrypted v2 payload may itself be an escaped `plain:` value.
fn decode_plain_if_tagged(text: Zeroizing<String>) -> Result<String, Undecryptable> {
    let decoded = text
        .strip_prefix(PREFIX_PLAIN)
        .filter(|encoded| !encoded.is_empty())
        .and_then(|encoded| decode_plain(encoded).ok());
    match decoded {
        Some(plaintext) => Ok(plaintext),
        // Not a well-formed escape: keep the literal value.
        None => Ok(text.to_string()),
    }
}

/// Encrypt with an injectable backend. Production uses DPAPI; tests use a
/// reversible fake to verify the v1/v2 formats, entropy and migration.
pub(crate) fn protect_with(
    value: &str,
    encrypt: impl Fn(&[u8], &[u8]) -> Option<Zeroizing<Vec<u8>>>,
) -> Result<String, String> {
    if value.is_empty() {
        return Ok(String::new());
    }
    let payload = escape_reserved(value);
    let encrypted = encrypt(payload.as_bytes(), ENTROPY)
        .ok_or_else(|| "DPAPI CryptProtectData failed".to_string())?;
    Ok(wrap(PREFIX_V2, encrypted.as_slice()))
}

/// Decrypt with an injectable backend. `dpapi:` is read with no entropy
/// (v1 migration), `dpapi2:` with [`ENTROPY`]. Decrypted buffers are zeroized
/// after the owned `String` is produced.
pub(crate) fn unprotect_with(
    value: &str,
    decrypt: impl Fn(&[u8], Option<&[u8]>) -> Option<Zeroizing<Vec<u8>>>,
) -> Result<String, Undecryptable> {
    if value.is_empty() {
        return Ok(String::new());
    }
    if let Some(encoded) = value.strip_prefix(PREFIX_V2) {
        let encrypted = Zeroizing::new(decode_payload(encoded)?);
        let plain = decrypt(&encrypted, Some(ENTROPY)).ok_or(Undecryptable)?;
        let text = Zeroizing::new(
            std::str::from_utf8(&plain)
                .map_err(|_| Undecryptable)?
                .to_owned(),
        );
        return decode_plain_if_tagged(text);
    }
    if let Some(encoded) = value.strip_prefix(PREFIX_V1) {
        let encrypted = Zeroizing::new(decode_payload(encoded)?);
        let plain = decrypt(&encrypted, None).ok_or(Undecryptable)?;
        // v1 never escaped reserved prefixes, so the decrypted text is the
        // original secret even if it starts with `plain:`.
        return std::str::from_utf8(&plain)
            .map(str::to_owned)
            .map_err(|_| Undecryptable);
    }
    if let Some(encoded) = value.strip_prefix(PREFIX_PLAIN) {
        if !encoded.is_empty() {
            if let Ok(plaintext) = decode_plain(encoded) {
                return Ok(plaintext);
            }
        }
        // A legacy plaintext value that happens to start with `plain:` is
        // kept verbatim unless the remainder is a valid escape payload.
        return Ok(value.to_string());
    }
    Ok(value.to_string())
}

/// Protect a secret for storage. Empty values stay empty. On Windows this
/// always writes the v2 format; on other hosts the escaped plaintext is kept.
pub fn protect(value: &str) -> Result<String, String> {
    #[cfg(windows)]
    {
        protect_with(value, win::protect)
    }
    #[cfg(not(windows))]
    {
        if value.is_empty() {
            return Ok(String::new());
        }
        Ok(escape_reserved(value).to_string())
    }
}

/// Read a stored secret. Legacy plaintext and `plain:` values are decoded;
/// `dpapi:`/`dpapi2:` values must decrypt or return [`Undecryptable`].
pub fn unprotect(value: &str) -> Result<String, Undecryptable> {
    #[cfg(windows)]
    {
        unprotect_with(value, win::unprotect)
    }
    #[cfg(not(windows))]
    {
        unprotect_with(value, |_, _| None)
    }
}

#[cfg(windows)]
mod win {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };
    use zeroize::Zeroizing;

    fn blob(data: &[u8]) -> CRYPT_INTEGER_BLOB {
        CRYPT_INTEGER_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_ptr() as *mut u8,
        }
    }

    /// Copy the DPAPI-owned buffer, wipe it, then release it.
    unsafe fn take_output(output: CRYPT_INTEGER_BLOB) -> Zeroizing<Vec<u8>> {
        if output.pbData.is_null() {
            return Zeroizing::new(Vec::new());
        }
        let bytes =
            std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        std::ptr::write_bytes(output.pbData, 0, output.cbData as usize);
        LocalFree(output.pbData as *mut core::ffi::c_void);
        Zeroizing::new(bytes)
    }

    pub fn protect(data: &[u8], entropy: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        let input = blob(data);
        let entropy = blob(entropy);
        let mut output = CRYPT_INTEGER_BLOB::default();
        let ok = unsafe {
            CryptProtectData(
                &input,
                std::ptr::null(),
                &entropy,
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        if ok == 0 {
            return None;
        }
        Some(unsafe { take_output(output) })
    }

    pub fn unprotect(data: &[u8], entropy: Option<&[u8]>) -> Option<Zeroizing<Vec<u8>>> {
        let input = blob(data);
        let entropy = entropy.map(blob);
        let entropy_ptr = entropy
            .as_ref()
            .map_or(std::ptr::null(), |blob| blob as *const CRYPT_INTEGER_BLOB);
        let mut output = CRYPT_INTEGER_BLOB::default();
        let ok = unsafe {
            CryptUnprotectData(
                &input,
                std::ptr::null_mut(),
                entropy_ptr,
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        if ok == 0 {
            return None;
        }
        Some(unsafe { take_output(output) })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        decode_payload, is_protected, protect, protect_with, unprotect, unprotect_with, wrap,
        Undecryptable, ENTROPY, PREFIX_PLAIN, PREFIX_V1, PREFIX_V2,
    };
    use base64::Engine;
    use zeroize::Zeroizing;

    const XOR: u8 = 0x5A;

    /// Reversible fake ciphertext that records the entropy it was bound to.
    fn fake_encrypt(data: &[u8], entropy: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        assert!(entropy.len() <= u8::MAX as usize);
        let mut out = Vec::with_capacity(1 + data.len() + entropy.len());
        out.push(entropy.len() as u8);
        out.extend(data.iter().map(|byte| byte ^ XOR));
        out.extend_from_slice(entropy);
        Some(Zeroizing::new(out))
    }

    fn fake_decrypt(data: &[u8], entropy: Option<&[u8]>) -> Option<Zeroizing<Vec<u8>>> {
        let (len, body) = data.split_first()?;
        let len = *len as usize;
        if body.len() < len {
            return None;
        }
        let (cipher, trailer) = body.split_at(body.len() - len);
        if trailer != entropy.unwrap_or(&[]) {
            return None;
        }
        Some(Zeroizing::new(cipher.iter().map(|byte| byte ^ XOR).collect()))
    }

    fn legacy_v1(secret: &str) -> String {
        let encrypted = fake_encrypt(secret.as_bytes(), b"").unwrap();
        wrap(PREFIX_V1, encrypted.as_slice())
    }

    #[test]
    fn entropy_is_bound_to_the_app_contract() {
        assert_eq!(ENTROPY, b"melontools-dpapi-v2");
    }

    #[test]
    fn prefix_marks_protected_values() {
        assert!(is_protected("dpapi:AAAA"));
        assert!(is_protected("dpapi2:AAAA"));
        assert!(!is_protected("plain:AAAA"));
        assert!(!is_protected("sk-live-plaintext"));
        assert!(!is_protected(""));
    }

    #[test]
    fn empty_and_legacy_plaintext_pass_through() {
        assert_eq!(protect("").unwrap(), "");
        assert_eq!(unprotect("").unwrap(), "");
        assert_eq!(unprotect("sk-legacy").unwrap(), "sk-legacy");
        assert_eq!(unprotect("has dpapi: inside").unwrap(), "has dpapi: inside");
        #[cfg(not(windows))]
        assert_eq!(protect("sk-live").unwrap(), "sk-live");
        #[cfg(windows)]
        {
            let stored = protect("sk-live").unwrap();
            assert!(stored.starts_with(PREFIX_V2));
            assert_eq!(unprotect(&stored).unwrap(), "sk-live");
        }
    }

    #[test]
    fn v2_roundtrip_uses_entropy() {
        let stored = protect_with("sk-v2-token", fake_encrypt).unwrap();
        assert!(stored.starts_with(PREFIX_V2));
        assert_eq!(unprotect_with(&stored, fake_decrypt).unwrap(), "sk-v2-token");

        let raw = decode_payload(stored.strip_prefix(PREFIX_V2).unwrap()).unwrap();
        assert!(fake_decrypt(&raw, None).is_none(), "v2 must require entropy");
        assert!(fake_decrypt(&raw, Some(b"wrong")).is_none());
        assert!(fake_decrypt(&raw, Some(ENTROPY)).is_some());
    }

    #[test]
    fn v1_migrates_to_v2_on_the_next_save() {
        let secret = "sk-legacy-token";
        let stored = legacy_v1(secret);
        assert!(stored.starts_with(PREFIX_V1));
        assert_eq!(unprotect_with(&stored, fake_decrypt).unwrap(), secret);

        let migrated = protect_with(secret, fake_encrypt).unwrap();
        assert!(migrated.starts_with(PREFIX_V2));
        assert_eq!(unprotect_with(&migrated, fake_decrypt).unwrap(), secret);
    }

    #[test]
    fn v1_plaintext_is_not_mistaken_for_a_plain_escape() {
        // v1 code never wrote `plain:` escapes, so a decrypted v1 value keeps
        // its literal prefix instead of being decoded again.
        let secret = "plain:literal-secret";
        assert_eq!(
            unprotect_with(&legacy_v1(secret), fake_decrypt).unwrap(),
            secret
        );
    }

    #[test]
    fn reserved_plaintext_is_escaped_and_roundtrips() {
        for secret in [
            "dpapi:looks-encrypted",
            "dpapi2:looks-encrypted",
            "plain:looks-escaped",
        ] {
            let stored = protect_with(secret, fake_encrypt).unwrap();
            assert!(stored.starts_with(PREFIX_V2));
            assert_eq!(unprotect_with(&stored, fake_decrypt).unwrap(), secret);

            let host = protect(secret).unwrap();
            #[cfg(not(windows))]
            {
                assert!(host.starts_with(PREFIX_PLAIN));
                assert_eq!(unprotect(&host).unwrap(), secret);
            }
            #[cfg(windows)]
            {
                assert!(host.starts_with(PREFIX_V2));
                assert_eq!(unprotect(&host).unwrap(), secret);
            }
        }
    }

    #[test]
    fn plain_tag_decodes_without_a_backend() {
        let encoded = base64::engine::general_purpose::STANDARD.encode("dpapi:literal");
        let stored = format!("{}{}", PREFIX_PLAIN, encoded);
        assert_eq!(unprotect(&stored).unwrap(), "dpapi:literal");
    }

    #[test]
    fn invalid_plain_escape_is_treated_as_legacy_plaintext() {
        for value in ["plain:", "plain:literal-secret", "plain:not base64!"] {
            assert_eq!(unprotect(value).unwrap(), value, "erased {value}");
        }
        // A valid escape payload still decodes.
        let encoded = base64::engine::general_purpose::STANDARD.encode("dpapi:literal");
        let stored = format!("{}{}", PREFIX_PLAIN, encoded);
        assert_eq!(unprotect(&stored).unwrap(), "dpapi:literal");
    }

    #[test]
    fn undecryptable_values_are_reported() {
        for bad in [
            "dpapi:",
            "dpapi:not-base64!!!",
            "dpapi:AAAA",
            "dpapi2:",
            "dpapi2:not-base64!!!",
            "dpapi2:AAAA",
        ] {
            assert_eq!(unprotect(bad), Err(Undecryptable), "accepted {bad}");
        }
    }

    #[test]
    fn malformed_encrypted_payloads_are_not_rewritten_as_ciphertext() {
        // A failed read is reported; callers must treat it as unset. `protect`
        // never treats a stored prefix as plaintext and double-wraps it.
        let stored = format!("{}{}", PREFIX_V2, "not-base64!!!");
        assert_eq!(unprotect(&stored), Err(Undecryptable));
        assert!(protect_with("sk-new", fake_encrypt)
            .unwrap()
            .starts_with(PREFIX_V2));
    }
}
