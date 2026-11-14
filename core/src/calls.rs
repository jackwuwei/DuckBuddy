//! 平台层能发起的全部调用，类型化。每个变体都映射到官方 `proto::Call`，
//! 方法名和参数形状由 `duck-ipc-proto` 决定——协议改了这里就编译失败。

use duck_ipc_proto as proto;

/// 鸭子固件自带的 7 种叫声（官方 `SoundTag`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Quack {
    Chirp,
    Greet,
    Inquire,
    Coo,
    Wheee,
    Alarm,
    Peck,
}

impl From<Quack> for proto::SoundTag {
    fn from(q: Quack) -> Self {
        match q {
            Quack::Chirp => Self::Chirp,
            Quack::Greet => Self::Greet,
            Quack::Inquire => Self::Inquire,
            Quack::Coo => Self::Coo,
            Quack::Wheee => Self::Wheee,
            Quack::Alarm => Self::Alarm,
            Quack::Peck => Self::Peck,
        }
    }
}

/// 双腿 / 轮子。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LocoMode {
    Walk,
    Roller,
}

impl LocoMode {
    pub fn wire(self) -> &'static str {
        match self {
            Self::Walk => "walk",
            Self::Roller => "roller",
        }
    }
}

/// 策略槽位加载目标。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SlotTarget {
    /// 恢复官方（不带路径）。
    Official,
    /// 关闭此槽位（行走槽不可关闭，由机器人拒绝）。
    Off,
    /// 加载指定 `.onnx`（绝对路径，来自 `policy.fetch` 的结果）。
    File { path: String },
}

/// 手柄键绑定目标。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PadTarget {
    Skill { name: String },
    /// 不绑定（`""`）。
    Off,
    /// 恢复出厂（不带字段）。
    Default,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum DuckCall {
    // system / 连接
    SystemInfo,
    SystemSetName { name: String },
    SystemReboot,
    // robot
    RobotHealth,
    RobotEnable { on: bool },
    RobotToggleEnable,
    RobotInit,
    RobotRest,
    RobotShutdown,
    RobotRebootMotors { ids: Vec<u8> },
    RobotDo { skill: String },
    RobotSound { quack: Quack, hold: Option<bool> },
    RobotMove { vx: f64, vy: f64, vyaw: f64 },
    RobotHead { neck_pitch: f64, head_pitch: f64, head_yaw: f64, head_roll: f64 },
    RobotStop,
    RobotSubscribe { hz: Option<u32> },
    RobotMode,
    RobotSetMode { mode: LocoMode },
    RobotPolicies,
    RobotLoadPolicy { slot: String, target: SlotTarget },
    RobotSkills,
    RobotAddSkill { name: String, path: String, duration: f64 },
    RobotDisableSkill { name: String },
    RobotRemoveSkill { name: String },
    // policy
    PolicyCheck,
    PolicySearch { query: String },
    PolicyFetch { repo: String, revision: Option<String> },
    // net
    NetStatus,
    NetScan,
    NetConnect { ssid: String, password: Option<String> },
    NetForget { ssid: String },
    // pad
    PadBindings,
    PadBind { button: String, target: PadTarget },
}

impl DuckCall {
    /// 转成官方调用。
    pub fn to_proto(&self) -> proto::Call {
        use proto::Call as C;
        match self.clone() {
            Self::SystemInfo => C::SystemInfo,
            Self::SystemSetName { name } => C::SystemSetName(proto::SetNameParams { name }),
            Self::SystemReboot => C::SystemReboot,
            Self::RobotHealth => C::RobotHealth,
            Self::RobotEnable { on } => C::RobotEnable(proto::EnableParams { on, toggle: false }),
            Self::RobotToggleEnable => C::RobotEnable(proto::EnableParams { on: true, toggle: true }),
            Self::RobotInit => C::RobotInit,
            Self::RobotRest => C::RobotRest,
            Self::RobotShutdown => C::RobotShutdown,
            Self::RobotRebootMotors { ids } => C::RobotRebootMotors(proto::RebootMotorsParams { ids }),
            Self::RobotDo { skill } => C::RobotDo(proto::DoParams { skill }),
            Self::RobotSound { quack, hold } => C::RobotSound(proto::SoundParams { tag: quack.into(), hold }),
            Self::RobotMove { vx, vy, vyaw } => C::RobotMove(proto::MoveParams { vx, vy, vyaw }),
            Self::RobotHead { neck_pitch, head_pitch, head_yaw, head_roll } => {
                C::RobotHead(proto::HeadParams { neck_pitch, head_pitch, head_yaw, head_roll })
            }
            Self::RobotStop => C::RobotStop,
            Self::RobotSubscribe { hz } => C::RobotSubscribe(proto::SubscribeParams { hz }),
            Self::RobotMode => C::RobotMode,
            Self::RobotSetMode { mode } => C::RobotSetMode(proto::SetModeParams { mode: mode.wire().into() }),
            Self::RobotPolicies => C::RobotPolicies,
            Self::RobotLoadPolicy { slot, target } => C::RobotLoadPolicy(proto::LoadPolicyParams {
                slot: Some(slot),
                path: match target {
                    SlotTarget::Official => None,
                    SlotTarget::Off => Some("none".into()),
                    SlotTarget::File { path } => Some(path),
                },
            }),
            Self::RobotSkills => C::RobotSkills,
            Self::RobotAddSkill { name, path, duration } => C::RobotSetSkill(skill(name, Some(path), Some(duration))),
            // 停用内置技能 = 路径 "none"（技术方案 3.6）
            Self::RobotDisableSkill { name } => C::RobotSetSkill(skill(name, Some("none".into()), None)),
            Self::RobotRemoveSkill { name } => C::RobotRemoveSkill(proto::SkillNameParams { name }),
            Self::PolicyCheck => C::PolicyCheck,
            Self::PolicySearch { query } => C::PolicySearch(proto::PolicySearchParams { query }),
            Self::PolicyFetch { repo, revision } => {
                C::PolicyFetch(proto::PolicyFetchParams { repo, revision, file: None })
            }
            Self::NetStatus => C::NetStatus,
            Self::NetScan => C::NetScan,
            Self::NetConnect { ssid, password } => C::NetConnect(proto::NetConnectParams { ssid, psk: password }),
            Self::NetForget { ssid } => C::NetForget(proto::NetForgetParams { ssid }),
            Self::PadBindings => C::PadBindings,
            Self::PadBind { button, target } => C::PadBind(proto::PadBindParams {
                button,
                skill: match target {
                    PadTarget::Skill { name } => Some(name),
                    PadTarget::Off => Some(String::new()),
                    PadTarget::Default => None,
                },
            }),
        }
    }

    /// 连续意图：走 WebRTC `teleop` 不可靠通道，作为通知发送（无 id，后写覆盖先写）。
    pub fn is_continuous(&self) -> bool {
        matches!(self, Self::RobotMove { .. } | Self::RobotHead { .. })
    }
}

/// 坐下 / 站起该发哪个调用。依据 `robot.policies` 的 `sitting` / `homed`，加上策略是否在驱动
/// （App 的电源状态不是"关"），规则来自真机（0.17.8，2026-11-14）：
/// - 策略没在驱动 → `robot.enable on`：机器人自己回零位（未回零位时）、从座位起身，最后进入行走策略；
///   此时 `sit_toggle` 会被拒绝（"the policy is not driving"）。`robot.init` 只会把趴着的鸭子送到座位。
/// - 策略在驱动、坐姿锁住 → `robot.do sit_toggle` 起身；站着 → `sit_toggle` 坐下。
///
/// 已经是想要的姿态、或当前做不到（没驱动时坐下）时返回 `None`。
#[uniffi::export]
pub fn posture_call(want_sit: bool, sitting: bool, homed: bool, driving: bool) -> Option<DuckCall> {
    let toggle = || DuckCall::RobotDo { skill: "sit_toggle".into() };
    let standing = homed && !sitting;
    match (want_sit, driving) {
        (false, _) if standing => None,
        (false, false) => Some(DuckCall::RobotEnable { on: true }),
        // 驱动中却未回零位：enable 会先回零位再起身（真机已验证从休息状态直接 enable）。
        (false, true) if !homed => Some(DuckCall::RobotEnable { on: true }),
        (false, true) => Some(toggle()),
        (true, true) if standing => Some(toggle()),
        (true, _) => None,
    }
}

fn skill(name: String, path: Option<String>, duration: Option<f64>) -> proto::SkillParams {
    proto::SkillParams {
        name,
        path,
        duration,
        command: None,
        unwind: None,
        unwind_s: None,
        chain: None,
        action_scale: None,
        gain_ratio: None,
        overridden: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standing_up_uses_the_right_call() {
        let toggle = Some(DuckCall::RobotDo { skill: "sit_toggle".into() });
        let enable = Some(DuckCall::RobotEnable { on: true });
        // 没驱动：不论在座位上还是休息后未回零位，站起都是 enable（真机验证）。
        assert_eq!(posture_call(false, true, true, false), enable);
        assert_eq!(posture_call(false, false, false, false), enable);
        // 驱动中：锁住的坐姿用 sit_toggle 起身。
        assert_eq!(posture_call(false, true, true, true), toggle);
        assert_eq!(posture_call(false, false, true, true), None);
        // 坐下：只有驱动中的站立鸭子能 sit_toggle；没驱动时 sit_toggle 会被拒绝。
        assert_eq!(posture_call(true, false, true, true), toggle);
        assert_eq!(posture_call(true, false, true, false), None);
        assert_eq!(posture_call(true, true, true, true), None);
        assert_eq!(posture_call(true, false, false, true), None);
    }

    #[test]
    fn calls_use_official_methods() {
        let call = DuckCall::NetConnect { ssid: "home".into(), password: Some("pw".into()) }.to_proto();
        assert_eq!(call.method(), proto::method::NET_CONNECT);
        let req = proto::Request::call(proto::Id::Number(1), &call);
        let json = serde_json::to_value(&req).unwrap();
        assert_eq!(json["params"]["ssid"], "home");
        assert_eq!(json["params"]["psk"], "pw");

        let off = DuckCall::PadBind { button: "x".into(), target: PadTarget::Off }.to_proto();
        let json = serde_json::to_value(proto::Request::call(proto::Id::Number(2), &off)).unwrap();
        assert_eq!(json["params"]["skill"], "");
        let def = DuckCall::PadBind { button: "x".into(), target: PadTarget::Default }.to_proto();
        let json = serde_json::to_value(proto::Request::call(proto::Id::Number(3), &def)).unwrap();
        assert!(json["params"].get("skill").is_none());
    }
}
