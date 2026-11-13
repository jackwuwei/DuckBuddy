//! 策略 manifest 兼容判定（下载前，官方 `docs/policy-manifest.md`）。
//! 字段缺失不算不兼容；明确写了且不符才算。

use serde_json::Value;

pub const OBS_LEN: u64 = 61;
pub const ACTION_LEN: u64 = 14;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum Incompatibility {
    ObsLen { found: u64, expected: u64 },
    ActionLen { found: u64, expected: u64 },
    RobotModel { found: String },
    /// `phase` / `posture_flag` 编码的策略不能作为一次性技能。
    NotASkill { encoding: String },
    Unreadable,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Compatibility {
    pub as_slot: Vec<Incompatibility>,
    pub as_skill: Vec<Incompatibility>,
}

#[uniffi::export]
pub fn check_manifest(json: &str) -> Compatibility {
    let Ok(v) = serde_json::from_str::<Value>(json) else {
        return Compatibility { as_slot: vec![Incompatibility::Unreadable], as_skill: vec![Incompatibility::Unreadable] };
    };
    let mut common = vec![];
    if let Some(n) = v.get("obs_len").and_then(Value::as_u64).filter(|n| *n != OBS_LEN) {
        common.push(Incompatibility::ObsLen { found: n, expected: OBS_LEN });
    }
    if let Some(n) = v.get("action_len").and_then(Value::as_u64).filter(|n| *n != ACTION_LEN) {
        common.push(Incompatibility::ActionLen { found: n, expected: ACTION_LEN });
    }
    if let Some(m) = v.pointer("/robot/model").and_then(Value::as_str).filter(|m| !m.contains("microduck")) {
        common.push(Incompatibility::RobotModel { found: m.to_owned() });
    }
    let mut as_skill = common.clone();
    if let Some(enc) = v.pointer("/command/encoding").and_then(Value::as_str)
        && matches!(enc, "phase" | "posture_flag")
    {
        as_skill.push(Incompatibility::NotASkill { encoding: enc.to_owned() });
    }
    Compatibility { as_slot: common, as_skill }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_fields_are_compatible() {
        assert_eq!(check_manifest("{}"), Compatibility { as_slot: vec![], as_skill: vec![] });
        let c = check_manifest(r#"{"obs_len":51,"command":{"encoding":"phase"}}"#);
        assert_eq!(c.as_slot, vec![Incompatibility::ObsLen { found: 51, expected: 61 }]);
        assert_eq!(c.as_skill.len(), 2);
    }
}
