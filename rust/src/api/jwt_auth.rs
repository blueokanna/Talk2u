use base64url::encode;
use chrono::Utc;
use flutter_rust_bridge::frb;
use hmac::{Hmac, Mac};
use sha2::Sha256;

#[frb(opaque)]
pub struct JwtAuth {
    user_id: String,
    user_secret: String,
    cached_token: Option<String>,
    token_expiry: Option<i64>,
}

const TOKEN_VALIDITY_MS: i64 = 30 * 60 * 1000;
const EXPIRY_MARGIN_MS: i64 = 60 * 1000;

impl JwtAuth {
    pub fn new(api_key: &str) -> Result<Self, String> {
        if !Self::validate_api_key_format(api_key) {
            return Err("Invalid API key format: expected \"user_id.user_secret\" with exactly one dot separator and non-empty parts".to_string());
        }
        let dot_pos = api_key.find('.').unwrap();
        let user_id = api_key[..dot_pos].to_string();
        let user_secret = api_key[dot_pos + 1..].to_string();
        Ok(Self {
            user_id,
            user_secret,
            cached_token: None,
            token_expiry: None,
        })
    }

    pub fn get_token(&mut self) -> String {
        if let Some(ref token) = self.cached_token {
            if !self.is_token_expired() {
                return token.clone();
            }
        }
        let token = Self::generate_jwt(&self.user_id, &self.user_secret);
        let expiry = Utc::now().timestamp_millis() + TOKEN_VALIDITY_MS;
        self.cached_token = Some(token.clone());
        self.token_expiry = Some(expiry);
        token
    }

    pub fn is_token_expired(&self) -> bool {
        match self.token_expiry {
            Some(expiry) => Utc::now().timestamp_millis() >= expiry - EXPIRY_MARGIN_MS,
            None => true,
        }
    }

    pub fn validate_api_key_format(api_key: &str) -> bool {
        let parts: Vec<&str> = api_key.split('.').collect();
        parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty()
    }

    /// Generate a JWT token using HMAC-SHA256, reusing the same algorithm
    /// as custom_jwt.rs: base64url(header).base64url(payload).base64url(signature).
    fn generate_jwt(user_id: &str, user_secret: &str) -> String {
        let header = r#"{"alg":"HS256","sign_type":"SIGN"}"#;
        let time_now = Utc::now().timestamp_millis();
        let exp_time = time_now + TOKEN_VALIDITY_MS;
        let payload = format!(
            r#"{{"api_key":"{}","exp":{},"timestamp":{}}}"#,
            user_id, exp_time, time_now
        );

        let encoded_header = encode_base64_url(header.as_bytes());
        let encoded_payload = encode_base64_url(payload.as_bytes());
        let to_sign = format!("{}.{}", encoded_header, encoded_payload);

        let signature_bytes = hmac_sha256_sign(user_secret, &to_sign);
        let encoded_signature = encode_base64_url(&signature_bytes);

        format!("{}.{}", to_sign, encoded_signature)
    }

    /// Verify a JWT token using the stored secret.
    #[allow(dead_code)]
    pub fn verify_jwt(&self, jwt: &str) -> bool {
        let jwt = jwt.trim();
        let parts: Vec<&str> = jwt.split('.').collect();
        if parts.len() != 3 {
            return false;
        }
        let to_verify = format!("{}.{}", parts[0], parts[1]);
        let calculated = encode_base64_url(&hmac_sha256_sign(&self.user_secret, &to_verify));
        calculated == parts[2]
    }

    /// Invalidate the cached token, forcing regeneration on next get_token() call.
    #[allow(dead_code)]
    pub fn invalidate_token(&mut self) {
        self.cached_token = None;
        self.token_expiry = None;
    }

    /// Expose user_id for request building.
    #[allow(dead_code)]
    pub fn user_id(&self) -> &str {
        &self.user_id
    }
}

fn hmac_sha256_sign(secret: &str, data: &str) -> Vec<u8> {
    let mut mac =
        Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC key creation failed");
    mac.update(data.as_bytes());
    mac.finalize().into_bytes().to_vec()
}

fn encode_base64_url(data: &[u8]) -> String {
    encode(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── API key format validation ──

    #[test]
    fn test_valid_api_key() {
        assert!(JwtAuth::validate_api_key_format("user123.secret456"));
    }

    #[test]
    fn test_api_key_no_dot() {
        assert!(!JwtAuth::validate_api_key_format("nodothere"));
    }

    #[test]
    fn test_api_key_multiple_dots() {
        assert!(!JwtAuth::validate_api_key_format("a.b.c"));
    }

    #[test]
    fn test_api_key_empty_parts() {
        assert!(!JwtAuth::validate_api_key_format(".secret"));
        assert!(!JwtAuth::validate_api_key_format("user."));
        assert!(!JwtAuth::validate_api_key_format("."));
    }

    #[test]
    fn test_api_key_empty_string() {
        assert!(!JwtAuth::validate_api_key_format(""));
    }

    // ── JwtAuth::new ──

    #[test]
    fn test_new_valid_key() {
        let auth = JwtAuth::new("myid.mysecret");
        assert!(auth.is_ok());
        let auth = auth.unwrap();
        assert_eq!(auth.user_id(), "myid");
    }

    #[test]
    fn test_new_invalid_key() {
        assert!(JwtAuth::new("invalid").is_err());
        assert!(JwtAuth::new("a.b.c").is_err());
        assert!(JwtAuth::new("").is_err());
    }

    // ── Token generation & verification ──

    #[test]
    fn test_generate_and_verify_jwt() {
        let auth = JwtAuth::new("testuser.testsecret").unwrap();
        let token = JwtAuth::generate_jwt("testuser", "testsecret");
        assert!(auth.verify_jwt(&token));
    }

    #[test]
    fn test_verify_rejects_tampered_token() {
        let auth = JwtAuth::new("testuser.testsecret").unwrap();
        let token = JwtAuth::generate_jwt("testuser", "testsecret");
        let tampered = format!("{}x", token);
        assert!(!auth.verify_jwt(&tampered));
    }

    #[test]
    fn test_verify_rejects_wrong_secret() {
        let auth = JwtAuth::new("testuser.wrongsecret").unwrap();
        let token = JwtAuth::generate_jwt("testuser", "testsecret");
        assert!(!auth.verify_jwt(&token));
    }

    #[test]
    fn test_jwt_has_three_parts() {
        let token = JwtAuth::generate_jwt("u", "s");
        assert_eq!(token.split('.').count(), 3);
    }

    // ── Token caching & expiry ──

    #[test]
    fn test_get_token_caches() {
        let mut auth = JwtAuth::new("user.secret").unwrap();
        let t1 = auth.get_token();
        let t2 = auth.get_token();
        assert_eq!(t1, t2, "Consecutive get_token calls should return cached token");
    }

    #[test]
    fn test_is_token_expired_when_no_token() {
        let auth = JwtAuth::new("user.secret").unwrap();
        assert!(auth.is_token_expired(), "Should be expired when no token exists");
    }

    #[test]
    fn test_is_token_not_expired_after_generation() {
        let mut auth = JwtAuth::new("user.secret").unwrap();
        auth.get_token();
        assert!(!auth.is_token_expired(), "Freshly generated token should not be expired");
    }

    #[test]
    fn test_invalidate_forces_new_token() {
        let mut auth = JwtAuth::new("user.secret").unwrap();
        let t1 = auth.get_token();
        auth.invalidate_token();
        assert!(auth.is_token_expired());
        // After invalidation, next get_token generates a new one
        // (may be identical content-wise if called within same ms, but cache was cleared)
        let t2 = auth.get_token();
        // The token should be valid
        assert!(auth.verify_jwt(&t2));
        // Cache should be repopulated
        assert!(!auth.is_token_expired());
        let _ = t1; // suppress unused warning
    }

    #[test]
    fn test_expired_token_triggers_refresh() {
        let mut auth = JwtAuth::new("user.secret").unwrap();
        let t1 = auth.get_token();
        // Simulate expiry by setting token_expiry to the past
        auth.token_expiry = Some(0);
        assert!(auth.is_token_expired());
        // Sleep 2ms to guarantee a different timestamp in the payload
        std::thread::sleep(std::time::Duration::from_millis(2));
        let t2 = auth.get_token();
        // New token should be generated (different because timestamp changed)
        assert_ne!(t1, t2, "Expired token should be replaced with a new one");
        assert!(auth.verify_jwt(&t2));
    }
}
