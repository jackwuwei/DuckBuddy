//! `md1:<名字>:<64 位十六进制>` 设置码（authenticated-app-mvp.md）。
//!
//! 名字是机器人由 SoC 序列号派生的 `duck-xxxx` 首名，改名不变；密钥 32 字节。

use crate::CoreError;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SetupCode {
    /// 机器人首名（Noise prologue 里绑定的身份）。
    pub robot_id: String,
    /// 32 字节预共享密钥。
    pub key: Vec<u8>,
}

/// 解析设置码。容忍前后空白和输入法自动大写的前缀（`MD1:`）。
#[uniffi::export]
pub fn parse_setup_code(text: &str) -> Result<SetupCode, CoreError> {
    let text = text.trim();
    let (prefix, rest) = text.split_once(':').ok_or(CoreError::BadSetupCode)?;
    if !prefix.eq_ignore_ascii_case("md1") {
        return Err(CoreError::BadSetupCode);
    }
    let (id, hex) = rest.rsplit_once(':').ok_or(CoreError::BadSetupCode)?;
    if id.is_empty() || id.len() > 128 || !id.is_ascii() || id.chars().any(char::is_whitespace) {
        return Err(CoreError::BadSetupCode);
    }
    if hex.len() != 64 {
        return Err(CoreError::BadSetupCode);
    }
    let mut key = Vec::with_capacity(32);
    for i in 0..32 {
        let byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).map_err(|_| CoreError::BadSetupCode)?;
        key.push(byte);
    }
    Ok(SetupCode { robot_id: id.to_owned(), key })
}

/// 设置码里的名字是否就是这台广播出来的机器人（不一致时拒绝，防止对错鸭子握手）。
#[uniffi::export]
pub fn setup_code_matches(code: &SetupCode, advertised_name: &str) -> bool {
    code.robot_id == advertised_name
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_tolerates_capitalised_prefix() {
        let code = parse_setup_code(&format!("  MD1:duck-1a2b:{}\n", "ab".repeat(32))).unwrap();
        assert_eq!(code.robot_id, "duck-1a2b");
        assert_eq!(code.key, vec![0xab; 32]);
        assert!(setup_code_matches(&code, "duck-1a2b"));
        assert!(!setup_code_matches(&code, "duck-ffff"));
    }

    #[test]
    fn rejects_bad_codes() {
        for bad in [
            "",
            "md1:duck-1a2b",
            &format!("md2:duck:{}", "00".repeat(32)),
            &format!("md1::{}", "00".repeat(32)),
            &format!("md1:duck:{}", "0".repeat(63)),
            &format!("md1:duck:{}", "zz".repeat(32)),
        ] {
            assert!(parse_setup_code(bad).is_err(), "{bad}");
        }
    }
}
