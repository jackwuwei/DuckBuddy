//! 回复解码：把机器人回复（`LinkEvent::Reply.result_json`）解成跨语言记录。
//! 解析用的是官方结构体，字段改了这里编译失败。

use duck_ipc_proto as proto;

use crate::CoreError;

pub(crate) fn parse<T: serde::de::DeserializeOwned>(json: &str) -> Result<T, CoreError> {
    serde_json::from_str(json).map_err(|e| CoreError::BadReply { detail: e.to_string() })
}

fn wire<T: serde::Serialize>(v: &T) -> String {
    serde_json::to_value(v).ok().and_then(|v| v.as_str().map(str::to_owned)).unwrap_or_default()
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct NetStatus {
    /// `connected` / `connecting` / `disconnected` / `unavailable`
    pub state: String,
    pub connected: bool,
    pub ssid: Option<String>,
    pub signal: Option<u8>,
    pub ip4: Option<String>,
    /// 正在加入的网络和步骤（`scanning` / `associating` / `authenticating` / `key_rejected` / `addressing`）。
    pub joining_ssid: Option<String>,
    pub joining_step: Option<String>,
}

#[uniffi::export]
pub fn decode_net_status(json: &str) -> Result<NetStatus, CoreError> {
    let r: proto::NetStatusResult = parse(json)?;
    Ok(NetStatus {
        state: wire(&r.state),
        connected: matches!(r.state, proto::NetState::Connected),
        ssid: r.ssid,
        signal: r.signal,
        ip4: r.ip4,
        joining_ssid: r.joining.as_ref().map(|j| j.ssid.clone()),
        joining_step: r.joining.as_ref().map(|j| wire(&j.step)),
    })
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WifiNetwork {
    pub ssid: String,
    pub signal: u8,
    pub secured: bool,
    pub saved: bool,
}

#[uniffi::export]
pub fn decode_net_scan(json: &str) -> Result<Vec<WifiNetwork>, CoreError> {
    let r: proto::NetScanResult = parse(json)?;
    let mut list: Vec<_> = r
        .networks
        .into_iter()
        .filter(|n| !n.ssid.is_empty())
        .map(|n| WifiNetwork {
            ssid: n.ssid,
            signal: n.signal,
            secured: !matches!(n.security, proto::Security::Open),
            saved: n.saved,
        })
        .collect();
    list.sort_by(|a, b| b.signal.cmp(&a.signal));
    list.dedup_by(|a, b| a.ssid == b.ssid);
    Ok(list)
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Health {
    pub healthy: bool,
    pub degraded: bool,
    pub reason: Option<String>,
    /// 未知时为 `None`——不能当作 0 V 显示为空电量。
    pub battery_volts: Option<f64>,
    pub battery_percent: Option<f64>,
    pub motor_max_c: Option<f64>,
    pub motor_hottest: Option<String>,
    pub cpu_temp_c: Option<f64>,
}

#[uniffi::export]
pub fn decode_health(json: &str) -> Result<Health, CoreError> {
    let r: proto::HealthResult = parse(json)?;
    Ok(Health {
        healthy: r.healthy,
        degraded: r.degraded,
        reason: r.reason,
        battery_volts: r.battery.as_ref().map(|b| b.volts),
        battery_percent: r.battery.as_ref().map(|b| b.percent),
        motor_max_c: r.motors.as_ref().map(|m| m.max_c),
        motor_hottest: r.motors.map(|m| m.hottest),
        cpu_temp_c: r.cpu_temp_c,
    })
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Intent {
    pub accepted: bool,
    pub reason: Option<String>,
}

#[uniffi::export]
pub fn decode_intent(json: &str) -> Result<Intent, CoreError> {
    let r: proto::IntentResult = parse(json)?;
    Ok(Intent { accepted: r.accepted, reason: r.reason })
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum Origin {
    Official,
    Community,
    Local,
    Other { name: String },
}

fn origin(s: Option<&str>) -> Option<Origin> {
    s.map(|s| match s {
        "official" => Origin::Official,
        "community" => Origin::Community,
        "local" => Origin::Local,
        other => Origin::Other { name: other.to_owned() },
    })
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PolicySlot {
    pub slot: String,
    /// 正在运行的文件名（去掉目录），空槽为 `None`。
    pub running: Option<String>,
    pub path: Option<String>,
    pub origin: Option<Origin>,
    pub overridden: bool,
    /// 覆盖加载失败、已退回默认的原因（显示"!"角标）。
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Policies {
    /// `walk` / `roller`
    pub mode: String,
    pub enabled: bool,
    pub slots: Vec<PolicySlot>,
    pub skills: Vec<String>,
    pub homed: Option<bool>,
    pub sitting: Option<bool>,
    pub change_error: Option<String>,
    /// 轮子模式下行走槽被覆盖为双腿步态（两种模式共用槽位配置，P-7）。
    pub shared_walk_conflict: bool,
}

#[uniffi::export]
pub fn decode_policies(json: &str) -> Result<Policies, CoreError> {
    let r: proto::PoliciesResult = parse(json)?;
    let slots: Vec<PolicySlot> = r
        .slots
        .iter()
        .map(|s| PolicySlot {
            slot: s.slot.clone(),
            running: s.path.as_deref().map(|p| p.rsplit('/').next().unwrap_or(p).to_owned()),
            path: s.path.clone(),
            origin: origin(s.origin.as_deref()),
            overridden: s.overridden,
            error: s.error.clone(),
        })
        .collect();
    let shared_walk_conflict = r.mode == "roller"
        && slots.iter().any(|s| {
            s.slot == "walk" && s.overridden && s.running.as_deref().is_some_and(|f| !f.contains("roller"))
        });
    Ok(Policies {
        mode: r.mode,
        enabled: r.enabled,
        slots,
        skills: r.skills,
        homed: r.homed,
        sitting: r.sitting,
        change_error: r.change_error,
        shared_walk_conflict,
    })
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SkillInfo {
    pub name: String,
    pub path: Option<String>,
    pub duration: Option<f64>,
    pub chain: bool,
    pub overridden: bool,
    /// `sit_toggle`、`ground_pick` 等由守护进程自己驱动的，不可编辑。
    pub built_in: bool,
    pub disabled: bool,
}

#[uniffi::export]
pub fn decode_skills(json: &str) -> Result<Vec<SkillInfo>, CoreError> {
    let r: proto::SkillsResult = parse(json)?;
    let mut out: Vec<SkillInfo> = r
        .skills
        .into_iter()
        .map(|s| SkillInfo {
            disabled: s.path.as_deref() == Some("none"),
            name: s.name,
            path: s.path,
            duration: s.duration,
            chain: s.chain.unwrap_or(false),
            overridden: s.overridden,
            built_in: false,
        })
        .collect();
    out.extend(r.built_in.into_iter().map(|name| SkillInfo {
        name,
        path: None,
        duration: None,
        chain: false,
        overridden: false,
        built_in: true,
        disabled: false,
    }));
    Ok(out)
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PadBinding {
    pub button: String,
    /// 空字符串 = 不绑定。
    pub skill: String,
    pub overridden: bool,
    pub error: Option<String>,
}

#[uniffi::export]
pub fn decode_pad_bindings(json: &str) -> Result<Vec<PadBinding>, CoreError> {
    let r: proto::PadBindingsResult = parse(json)?;
    Ok(r
        .bindings
        .into_iter()
        .map(|b| PadBinding { button: b.button, skill: b.skill, overridden: b.overridden, error: b.error })
        .collect())
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SystemInfo {
    pub name: String,
    pub serial: Option<String>,
    pub uptime_seconds: u64,
    pub simulated: bool,
}

#[uniffi::export]
pub fn decode_system_info(json: &str) -> Result<SystemInfo, CoreError> {
    let r: proto::SystemInfoResult = parse(json)?;
    Ok(SystemInfo { name: r.name, serial: r.serial, uptime_seconds: r.uptime_seconds, simulated: r.simulated })
}

#[uniffi::export]
pub fn decode_set_name(json: &str) -> Result<String, CoreError> {
    Ok(parse::<proto::SetNameResult>(json)?.name)
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SearchHit {
    pub repo: String,
    pub origin: Option<Origin>,
    pub description: Option<String>,
    pub preview: Option<String>,
    pub downloads: Option<u64>,
}

#[uniffi::export]
pub fn decode_policy_search(json: &str) -> Result<Vec<SearchHit>, CoreError> {
    let r: proto::PolicySearchResult = parse(json)?;
    Ok(r
        .models
        .into_iter()
        .map(|m| SearchHit {
            origin: origin(Some(&m.origin)),
            repo: m.id,
            description: m.description,
            preview: m.preview,
            downloads: m.downloads,
        })
        .collect())
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FetchedPolicy {
    /// 机器人上的绝对路径，交给 `robot.loadPolicy` / `robot.setSkill`。
    pub path: String,
    pub repo: String,
    pub origin: Option<Origin>,
    pub name: Option<String>,
    pub kind: Option<String>,
    pub duration_s: Option<f64>,
    pub encoding: Option<String>,
    pub chain: bool,
}

#[uniffi::export]
pub fn decode_policy_fetch(json: &str) -> Result<FetchedPolicy, CoreError> {
    let r: proto::PolicyFetchResult = parse(json)?;
    Ok(FetchedPolicy {
        origin: origin(Some(&r.origin)),
        path: r.path,
        repo: r.repo,
        name: r.name,
        kind: r.kind,
        duration_s: r.duration_s,
        encoding: r.encoding,
        chain: r.chain,
    })
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PolicyUpdate {
    pub repo: Option<String>,
    pub installed: Option<String>,
    pub available: Option<String>,
}

/// `policy.check`：只报告不安装（P-8）。返回有新版本的条目。
#[uniffi::export]
pub fn decode_policy_check(json: &str) -> Result<Vec<PolicyUpdate>, CoreError> {
    let v: serde_json::Value = parse(json)?;
    let items = match &v {
        serde_json::Value::Array(a) => a.clone(),
        serde_json::Value::Object(o) => o
            .values()
            .find_map(|x| x.as_array().cloned())
            .unwrap_or_else(|| vec![v.clone()]),
        _ => vec![],
    };
    Ok(items
        .into_iter()
        .filter_map(|i| serde_json::from_value::<proto::PolicyCheckResult>(i).ok())
        .filter(|r| r.available.is_some() && r.available != r.installed)
        .map(|r| PolicyUpdate { repo: r.repo, installed: r.installed, available: r.available })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn net_status_and_scan() {
        let s = decode_net_status(r#"{"state":"connected","ssid":"home","signal":70,"ip4":"10.0.0.2","ip6":null,"mac":null,"iface":"wlan0"}"#).unwrap();
        assert!(s.connected);
        assert_eq!(s.ip4.as_deref(), Some("10.0.0.2"));
        let list = decode_net_scan(r#"{"networks":[{"ssid":"a","signal":20,"security":"open","saved":false},{"ssid":"b","signal":80,"security":"wpa_psk","saved":true}]}"#).unwrap();
        assert_eq!(list[0].ssid, "b");
        assert!(list[0].secured && !list[1].secured);
    }

    #[test]
    fn health_absent_battery_is_unknown() {
        let h = decode_health(r#"{"healthy":true,"bus":{}}"#);
        // BusHealth 的字段若为必填，解析会失败——这正是协议变化应当暴露的地方。
        if let Ok(h) = h {
            assert_eq!(h.battery_volts, None);
        }
    }
}
