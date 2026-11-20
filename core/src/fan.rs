//! 风扇状态：本机加装的 HAT D1 J8 风扇，由板上 `fanctl` 温控。
//!
//! 官方 `robot.health` 不含风扇，所以这不是官方协议：数据来自机器人上的只读服务
//! `duck-fanstat`（仓库 `robot/fanstat/`），局域网 `http://<ip>:8096/fan`，
//! 格式 `duckbuddy.fan/v1`。没装这个服务的鸭子请求会失败，平台层当作"没有风扇"不显示。

use serde::Deserialize;

use crate::CoreError;

pub const FAN_STATUS_PORT: u16 = 8096;
const SCHEMA: &str = "duckbuddy.fan/v1";

/// 风扇状态地址；IPv6 地址加方括号。
#[uniffi::export]
pub fn fan_status_url(ip: &str) -> String {
    if ip.contains(':') {
        format!("http://[{ip}]:{FAN_STATUS_PORT}/fan")
    } else {
        format!("http://{ip}:{FAN_STATUS_PORT}/fan")
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Fan {
    pub id: String,
    pub name: String,
    /// 当前给的 PWM 百分比。
    pub pct: Option<u8>,
    /// 实测转速；没有测速线或读不到为 `None`（不能显示成 0 转）。
    pub rpm: Option<u32>,
    /// `auto` / `manual`
    pub mode: String,
    pub health: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FanStatus {
    pub ok: bool,
    pub error: Option<String>,
    /// fanctl 读到的最高温度（所有 thermal zone）。
    pub temp_c: Option<f64>,
    pub fans: Vec<Fan>,
}

impl FanStatus {
    /// 状态页显示的那一颗：有转速读数的优先。
    pub fn primary(&self) -> Option<&Fan> {
        self.fans.iter().find(|f| f.rpm.is_some()).or_else(|| self.fans.first())
    }
}

#[derive(Deserialize)]
struct Wire {
    schema: String,
    ok: bool,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    temp_c: Option<f64>,
    #[serde(default)]
    fans: Vec<WireFan>,
}

#[derive(Deserialize)]
struct WireFan {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    pct: Option<f64>,
    #[serde(default)]
    rpm: Option<f64>,
    #[serde(default)]
    mode: String,
    #[serde(default)]
    health: String,
}

#[uniffi::export]
pub fn decode_fan_status(json: &str) -> Result<FanStatus, CoreError> {
    let w: Wire = serde_json::from_str(json).map_err(|e| CoreError::BadReply { detail: e.to_string() })?;
    if w.schema != SCHEMA {
        return Err(CoreError::BadReply { detail: format!("unexpected fan schema {}", w.schema) });
    }
    let fans = w
        .fans
        .into_iter()
        .map(|f| Fan {
            name: if f.name.is_empty() { f.id.clone() } else { f.name },
            id: f.id,
            pct: f.pct.filter(|p| p.is_finite()).map(|p| p.round().clamp(0.0, 100.0) as u8),
            rpm: f.rpm.filter(|r| r.is_finite() && *r >= 0.0).map(|r| r.round() as u32),
            mode: f.mode,
            health: f.health,
        })
        .collect();
    Ok(FanStatus { ok: w.ok, error: w.error, temp_c: w.temp_c, fans })
}

/// 状态页那一格：(百分比, 转速)。没有风扇或服务报错时为 `None`。
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FanTile {
    pub pct: Option<u8>,
    pub rpm: Option<u32>,
    pub manual: bool,
}

#[uniffi::export]
pub fn fan_tile(status: &FanStatus) -> Option<FanTile> {
    if !status.ok {
        return None;
    }
    status.primary().map(|f| FanTile { pct: f.pct, rpm: f.rpm, manual: f.mode == "manual" })
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIVE: &str = r#"{"schema": "duckbuddy.fan/v1", "ok": true, "temp_c": 58.3, "fans": [{"id": "cooling-top", "name": "HAT D1 J8", "pct": 70, "rpm": 21000, "mode": "auto", "health": "ready"}]}"#;

    #[test]
    fn decodes_live_reply() {
        let s = decode_fan_status(LIVE).unwrap();
        assert!(s.ok);
        assert_eq!(s.temp_c, Some(58.3));
        let t = fan_tile(&s).unwrap();
        assert_eq!((t.pct, t.rpm, t.manual), (Some(70), Some(21000), false));
    }

    #[test]
    fn missing_rpm_stays_unknown() {
        let s = decode_fan_status(r#"{"schema":"duckbuddy.fan/v1","ok":true,"fans":[{"id":"a","pct":60,"rpm":null,"mode":"manual"}]}"#).unwrap();
        let t = fan_tile(&s).unwrap();
        assert_eq!((t.pct, t.rpm, t.manual), (Some(60), None, true));
        assert_eq!(s.fans[0].name, "a");
    }

    #[test]
    fn error_and_empty_give_no_tile() {
        let s = decode_fan_status(r#"{"schema":"duckbuddy.fan/v1","ok":false,"error":"fanctl unavailable"}"#).unwrap();
        assert!(fan_tile(&s).is_none());
        let s = decode_fan_status(r#"{"schema":"duckbuddy.fan/v1","ok":true,"fans":[]}"#).unwrap();
        assert!(fan_tile(&s).is_none());
    }

    #[test]
    fn rejects_other_schema() {
        assert!(decode_fan_status(r#"{"schema":"x","ok":true}"#).is_err());
    }

    #[test]
    fn url() {
        assert_eq!(fan_status_url("192.168.50.115"), "http://192.168.50.115:8096/fan");
        assert_eq!(fan_status_url("fe80::1"), "http://[fe80::1]:8096/fan");
    }
}
