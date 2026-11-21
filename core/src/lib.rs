//! DuckBuddy 共享协议核心（duck-core）。
//!
//! 只做纯逻辑，不碰任何系统 API：平台层（Swift / Kotlin）把蓝牙通知、WebRTC 数据通道的字节交进来，
//! 核心返回要写出的字节和类型化的事件。协议类型直接来自官方 `duck-ipc-proto`、`duck-ble`、
//! `duck-auth`（mobile-app.md §3），所以 Kotlin / Swift 代码里不出现任何 RPC 方法名。
//!
//! | 模块 | 内容 |
//! | --- | --- |
//! | [`setup_code`] | `md1:` 设置码解析 |
//! | [`advert`] | BLE 广播解析（名字、IPv4、可连接性） |
//! | [`calls`] | 类型化调用 [`calls::DuckCall`] → 官方 `proto::Call` |
//! | [`link`] | 蓝牙会话：Noise 握手 / PIN 模式、分帧、请求编号、回复分发 |
//! | [`results`] | 回复解码为跨语言记录 |
//! | [`state`] | `robot.state` 流 → 驾驶 / 状态页数据，站姿判定 |
//! | [`drive`] | 摇杆映射、偏差着色、电量 |
//! | [`games`] | 三个玩法开关（激光、踢球、自由活动）与 `robot.mode` |
//! | [`emotion`] | 机器人自带的情绪动作清单（`robot.do <情绪>`） |
//! | [`manifest`] | 策略 manifest 兼容判定 |
//! | [`signalling`] | WebRTC 信令（`mediad` 的 webrtcsink 协议）、`media.video` 画面信息 |
//! | [`voice`] | 语音"按住说话"一轮的攒住 / 发送 / 取消与执行前检查 |

uniffi::setup_scaffolding!();

pub mod advert;
pub mod calls;
pub mod drive;
pub mod emotion;
pub mod fan;
pub mod games;
pub mod link;
pub mod manifest;
pub mod results;
pub mod setup_code;
pub mod signalling;
pub mod state;
pub mod viewer;
pub mod voice;

/// App 接受的最低机器人 API 版本（mobile-app.md §6：robot 0.14）。
pub const MIN_API_VERSION: u32 = 31;

/// 本核心编译时所依据的协议版本。
#[uniffi::export]
pub fn protocol_api_version() -> u32 {
    duck_ipc_proto::API_VERSION
}

/// 官方关节顺序（`JOINT_NAMES`），状态页按此顺序列出 15 个舵机。
#[uniffi::export]
pub fn joint_names() -> Vec<String> {
    duck_ipc_proto::JOINT_NAMES.iter().map(|s| (*s).to_owned()).collect()
}

/// 与 [`joint_names`] 同序的舵机 ID：左腿 20–24、头部 30–34、右腿 10–14。
#[uniffi::export]
pub fn joint_ids() -> Vec<u8> {
    vec![20, 21, 22, 23, 24, 30, 31, 32, 33, 34, 10, 11, 12, 13, 14]
}

/// 核心对平台层报告的错误。
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("设置码格式不对")]
    BadSetupCode,
    #[error("PIN 是 6 位数字")]
    BadPin,
    #[error("会话尚未认证")]
    NotReady,
    #[error("会话已关闭")]
    Closed,
    #[error("消息过大")]
    TooLarge,
    #[error("回复格式不对：{detail}")]
    BadReply { detail: String },
}
