use base64url::encode;
use flutter_rust_bridge::frb;
use hmac::{Hmac, Mac};
use rsntp::SntpClient;
use sha2::Sha256;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

#[frb(opaque)]
pub struct JwtAuth {
    user_id: String,
    user_secret: String,
    cached_token: Option<String>,
    token_expiry: Option<i64>,
}

const TOKEN_VALIDITY_SECONDS: i64 = 3600;
const EXPIRY_MARGIN_SECONDS: i64 = 60;
const NTP_SERVERS: [&str; 4] = [
    "ntp.aliyun.com",
    "ntp1.aliyun.com",
    "ntp.ntsc.ac.cn",
    "cn.pool.ntp.org",
];
static LAST_JWT_TIMESTAMP: AtomicI64 = AtomicI64::new(0);
/// 缓存 NTP 时间偏移量，避免每次 get_token() 都发起阻塞网络请求
static NTP_OFFSET_SECS: AtomicI64 = AtomicI64::new(0);
static NTP_INITIALIZED: AtomicBool = AtomicBool::new(false);

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
        self.invalidate_token();
        let token = Self::generate_jwt(self.user_id(), &self.user_secret);
        debug_assert!(self.verify_jwt(&token));
        let issued_at = LAST_JWT_TIMESTAMP.load(Ordering::Relaxed);
        let expiry = issued_at + TOKEN_VALIDITY_SECONDS;
        self.cached_token = Some(token.clone());
        self.token_expiry = Some(expiry);
        token
    }

    pub fn is_token_expired(&self) -> bool {
        match self.token_expiry {
            Some(expiry) => current_unix_seconds() >= expiry - EXPIRY_MARGIN_SECONDS,
            None => true,
        }
    }

    pub fn validate_api_key_format(api_key: &str) -> bool {
        let parts: Vec<&str> = api_key.split('.').collect();
        parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty()
    }

    fn generate_jwt(user_id: &str, user_secret: &str) -> String {
        let time_now = next_monotonic_jwt_timestamp_seconds();
        Self::generate_jwt_with_issued_at(user_id, user_secret, time_now)
    }

    fn generate_jwt_with_issued_at(user_id: &str, user_secret: &str, time_now: i64) -> String {
        let header = r#"{"alg":"HS256","sign_type":"SIGN"}"#;
        let exp_time = time_now + TOKEN_VALIDITY_SECONDS;
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

    pub fn invalidate_token(&mut self) {
        self.cached_token = None;
        self.token_expiry = None;
    }

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

fn current_unix_seconds() -> i64 {
    let system_time = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    // 如果已经初始化过 NTP 偏移量，直接使用缓存值
    // 避免每次调用都发起阻塞的 NTP 网络请求
    if NTP_INITIALIZED.load(Ordering::Relaxed) {
        let offset = NTP_OFFSET_SECS.load(Ordering::Relaxed);
        return system_time + offset;
    }

    // 首次调用，尝试 NTP 同步（仅执行一次）
    let client = SntpClient::new();
    for server in NTP_SERVERS {
        if let Ok(result) = client.synchronize(server) {
            if let Ok(chrono_time) = result.datetime().into_chrono_datetime() {
                let ntp_time = chrono_time.timestamp();
                let offset = ntp_time - system_time;
                NTP_OFFSET_SECS.store(offset, Ordering::Relaxed);
                NTP_INITIALIZED.store(true, Ordering::Relaxed);
                return ntp_time;
            }
        }
    }

    // NTP 全部失败，使用系统时间并缓存零偏移
    NTP_INITIALIZED.store(true, Ordering::Relaxed);
    system_time
}

fn next_monotonic_jwt_timestamp_seconds() -> i64 {
    let now = current_unix_seconds();
    loop {
        let prev = LAST_JWT_TIMESTAMP.load(Ordering::Relaxed);
        let next = if now > prev { now } else { prev + 1 };
        if LAST_JWT_TIMESTAMP
            .compare_exchange(prev, next, Ordering::Relaxed, Ordering::Relaxed)
            .is_ok()
        {
            return next;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let t2 = auth.get_token();
        assert!(auth.verify_jwt(&t2));
        assert!(!auth.is_token_expired());
        let _ = t1;
    }

    #[test]
    fn test_expired_token_triggers_refresh() {
        let mut auth = JwtAuth::new("user.secret").unwrap();
        let t1 = auth.get_token();
        auth.token_expiry = Some(0);
        assert!(auth.is_token_expired());
        std::thread::sleep(std::time::Duration::from_millis(2));
        let t2 = auth.get_token();
        assert_ne!(t1, t2, "Expired token should be replaced with a new one");
        assert!(auth.verify_jwt(&t2));
    }
}
