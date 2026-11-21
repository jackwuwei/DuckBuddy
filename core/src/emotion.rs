//! 情绪动作：机器人自带的一组"头 + 身体 + 嘴 + 声音"的关键帧动画（官方 `robotd/emotions/`）。
//!
//! 从 robot 0.18.8（API 49）起，每个发布都带着 Microduck 的 13 个情绪，名字就是技能名：
//! `robot.do sad` 播放，也能像技能一样绑到手柄键上。0.23.0 仍是这 13 个。
//! 机器人只在 `robot.subscribe` 的回复里列出它们（`robot.policies` / `robot.skills` 都不列），
//! 蓝牙上拿不到这个回复，所以清单放在核心里，按 API 版本给出。
//!
//! 机器人的规则（robotd `can_emote`）：策略正在驱动、没有在摔倒或关机坐下、没有其他技能在跑；
//! 一次只播一个，播放中再请求会被丢掉。播放期间摇杆不起作用。`devastated` 播到最后会坐下，
//! 之后保持坐姿。

/// 机器人开始自带情绪的 API 版本（robot 0.18.8）。
pub const EMOTIONS_API_VERSION: u32 = 49;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct EmotionInfo {
    /// `robot.do` 的技能名。
    pub name: String,
    /// 动画时长（最后一个关键帧），秒。
    pub seconds: f64,
    /// 播完会让鸭子坐下。
    pub sits: bool,
}

/// 情绪托盘的顺序：常用的在前。时长取自 0.23.0 自带的关键帧文件。
const SHIPPED: [(&str, f64, bool); 13] = [
    ("yes", 1.4, false),
    ("no", 1.7, false),
    ("excited", 3.3, false),
    ("laugh", 2.9, false),
    ("curious", 2.9, false),
    ("mmh", 1.9, false),
    ("sad", 7.5, false),
    ("angry", 2.5, false),
    ("impatient", 2.5, false),
    ("defiant", 2.1, false),
    ("mock", 2.5, false),
    ("devastated", 8.5, true),
    ("yes_fast", 1.4, false),
];

/// 这个 API 版本的机器人自带的情绪；还不知道版本（演示模式除外）或版本太旧时为空。
#[uniffi::export]
pub fn shipped_emotions(api_version: u32) -> Vec<EmotionInfo> {
    if api_version < EMOTIONS_API_VERSION {
        return vec![];
    }
    SHIPPED
        .iter()
        .map(|&(name, seconds, sits)| EmotionInfo { name: name.to_owned(), seconds, sits })
        .collect()
}

/// `name` 是不是机器人自带的情绪（手柄绑定页用来给出中文名）。
#[uniffi::export]
pub fn is_shipped_emotion(name: &str) -> bool {
    SHIPPED.iter().any(|(n, ..)| *n == name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn older_robots_have_none() {
        assert!(shipped_emotions(44).is_empty());
        assert_eq!(shipped_emotions(EMOTIONS_API_VERSION).len(), 13);
    }

    #[test]
    fn only_devastated_sits() {
        let sits: Vec<_> = shipped_emotions(67).into_iter().filter(|e| e.sits).map(|e| e.name).collect();
        assert_eq!(sits, ["devastated"]);
        assert!(is_shipped_emotion("yes_fast") && !is_shipped_emotion("kick_left"));
    }

    /// 情绪名就是 `robot.do` 的技能名，经 `RpcCodec` 原样上线。
    #[test]
    fn plays_through_robot_do() {
        let out = crate::link::RpcCodec::new().encode(crate::calls::DuckCall::RobotDo { skill: "laugh".into() });
        let line: serde_json::Value = serde_json::from_str(&out.line).unwrap();
        assert_eq!(line["method"], duck_ipc_proto::method::ROBOT_DO);
        assert_eq!(line["params"]["skill"], "laugh");
    }
}
