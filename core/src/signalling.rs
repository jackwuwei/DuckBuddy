//! WebRTC 信令（`mediad` 内置的 gst-plugins-rs `webrtcsink` 信令服务，局域网 `ws://<ip>:8443`）。
//!
//! 纯状态机：平台层把 WebSocket 文本帧交进来，按返回的动作建 PeerConnection、设远端 SDP、加 ICE；
//! 本地 answer / ICE 也经这里编码。流程照机器人自带的网页客户端（`mediad/webclient/index.html`）：
//!
//! `welcome` → 发 `list` → 选第一个 producer → `startSession`（不带 offer：机器人出 offer，我们答）
//! → `sessionStarted` → 建 PeerConnection → `peer{sdp offer}` → 回 `peer{sdp answer}`，ICE 双向 trickle。
//! 数据通道 `control` 由机器人创建，App 只接收（自己再开一个会是不被路由的第二个通道）。
//!
//! 局域网上没有认证（remote-webrtc.md §4）。

use std::sync::Mutex;

use serde_json::{Value, json};

/// 信令服务端口（`mediad` 的 `--port`）。
pub const SIGNALLING_PORT: u16 = 8443;

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SignalAction {
    /// 把这一帧发到 WebSocket。
    Send { text: String },
    /// 会话已开始：现在建 PeerConnection（接收视频、等机器人创建的数据通道）。
    CreatePeer,
    /// 机器人的 offer：设为远端描述，生成 answer 后交给 [`Signalling::answer`]。
    RemoteOffer { sdp: String },
    /// 机器人的 ICE 候选。
    RemoteIce { candidate: String, sdp_mline_index: u32 },
    /// 机器人上没有视频生产者（`mediad` 的管线还没跑起来）。
    NoProducer,
    /// 会话结束（机器人结束、或服务端报错）。平台层关掉 PeerConnection，稍后可重新 [`Signalling::restart`]。
    Ended { reason: String },
}

/// 机器人自报的名字等（producer 的 `meta`），会话建立前就能显示。
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProducerInfo {
    pub id: String,
    pub name: Option<String>,
    pub release: Option<String>,
}

#[derive(Default)]
struct State {
    session_id: Option<String>,
    starting: bool,
    wanted: bool,
    producer: Option<ProducerInfo>,
}

#[derive(uniffi::Object)]
pub struct Signalling {
    state: Mutex<State>,
}

fn s(v: &Value) -> Option<String> {
    v.as_str().map(str::to_owned)
}

#[uniffi::export]
impl Signalling {
    #[uniffi::constructor]
    pub fn new() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self { state: Mutex::new(State { wanted: true, ..Default::default() }) })
    }

    /// 信令地址。
    pub fn url(&self, ip: String) -> String {
        format!("ws://{ip}:{SIGNALLING_PORT}")
    }

    pub fn producer(&self) -> Option<ProducerInfo> {
        self.state.lock().unwrap().producer.clone()
    }

    pub fn session_id(&self) -> Option<String> {
        self.state.lock().unwrap().session_id.clone()
    }

    /// 服务端一帧。
    pub fn on_message(&self, text: String) -> Vec<SignalAction> {
        let Ok(msg) = serde_json::from_str::<Value>(&text) else { return vec![] };
        let mut st = self.state.lock().unwrap();
        match msg["type"].as_str().unwrap_or_default() {
            "welcome" => vec![SignalAction::Send { text: json!({"type":"list"}).to_string() }],
            "list" => {
                let producers = msg["producers"].as_array().cloned().unwrap_or_default();
                let Some(p) = producers.first() else { return vec![SignalAction::NoProducer] };
                let meta = &p["meta"];
                let info = ProducerInfo { id: s(&p["id"]).unwrap_or_default(), name: s(&meta["name"]), release: s(&meta["release"]) };
                st.producer = Some(info.clone());
                // 已有会话、正在开、或没人要：这是机器人上下线的通知，不是开会话的邀请。
                if st.session_id.is_some() || st.starting || !st.wanted {
                    return vec![];
                }
                st.starting = true;
                vec![SignalAction::Send { text: json!({"type":"startSession","peerId":info.id}).to_string() }]
            }
            "sessionStarted" => {
                st.starting = false;
                st.session_id = s(&msg["sessionId"]);
                vec![SignalAction::CreatePeer]
            }
            "peer" => {
                if st.session_id.is_none() || s(&msg["sessionId"]) != st.session_id {
                    return vec![];
                }
                if msg["sdp"]["type"] == "offer" {
                    return vec![SignalAction::RemoteOffer { sdp: s(&msg["sdp"]["sdp"]).unwrap_or_default() }];
                }
                match s(&msg["ice"]["candidate"]) {
                    Some(c) if !c.is_empty() => vec![SignalAction::RemoteIce {
                        candidate: c,
                        sdp_mline_index: msg["ice"]["sdpMLineIndex"].as_u64().unwrap_or(0) as u32,
                    }],
                    _ => vec![],
                }
            }
            "endSession" => {
                st.session_id = None;
                st.starting = false;
                vec![SignalAction::Ended { reason: s(&msg["reason"]).unwrap_or_else(|| "ended by robot".into()) }]
            }
            "error" => {
                st.starting = false;
                vec![SignalAction::Ended { reason: s(&msg["details"]).unwrap_or_else(|| "signalling error".into()) }]
            }
            _ => vec![],
        }
    }

    /// 本地 answer。
    pub fn answer(&self, sdp: String) -> Option<String> {
        let sid = self.state.lock().unwrap().session_id.clone()?;
        Some(json!({"type":"peer","sessionId":sid,"sdp":{"type":"answer","sdp":sdp}}).to_string())
    }

    /// 本地 ICE 候选。
    pub fn ice(&self, candidate: String, sdp_mline_index: u32) -> Option<String> {
        let sid = self.state.lock().unwrap().session_id.clone()?;
        Some(json!({"type":"peer","sessionId":sid,"ice":{"candidate":candidate,"sdpMLineIndex":sdp_mline_index}}).to_string())
    }

    /// 结束当前会话（如视频卡住后重开、App 进后台）。返回要发的帧。
    pub fn end(&self) -> Option<String> {
        let mut st = self.state.lock().unwrap();
        st.starting = false;
        let sid = st.session_id.take()?;
        Some(json!({"type":"endSession","sessionId":sid}).to_string())
    }

    /// 在同一条信令连接上重新开会话：先结束旧的（若有），再 `list`，收到列表后自动 `startSession`。
    pub fn restart(&self) -> Vec<String> {
        let mut out: Vec<String> = self.end().into_iter().collect();
        self.state.lock().unwrap().wanted = true;
        out.push(json!({"type":"list"}).to_string());
        out
    }
}

/// `media.video` 的回答 / 通知：画面尺寸与相机安装角度。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct VideoInfo {
    pub width: u32,
    pub height: u32,
    /// 相机相对正立顺时针安装的角度（0 / 90 / 180 / 270）。画面需顺时针转这么多度才正（同网页客户端）。
    pub rotate: u32,
}

fn video_info(v: &Value) -> Option<VideoInfo> {
    let rotate = v["rotate"].as_i64().unwrap_or(0).rem_euclid(360) as u32;
    Some(VideoInfo { width: v["width"].as_u64()? as u32, height: v["height"].as_u64()? as u32, rotate })
}

/// `media.video` 的回复（`result` JSON）。
#[uniffi::export]
pub fn decode_video_info(json: &str) -> Option<VideoInfo> {
    video_info(&serde_json::from_str(json).ok()?)
}

/// 数据通道上的通知若是 `media.video`（机器人在画面角度变化时推送），解出画面信息。
#[uniffi::export]
pub fn video_info_notification(method: String, params_json: String) -> Option<VideoInfo> {
    if method != MEDIA_VIDEO {
        return None;
    }
    decode_video_info(&params_json)
}

/// `mediad` 自己回答的方法（不经 `duck-ipc-proto`：当前锁定的协议版本里还没有这个调用）。
pub const MEDIA_VIDEO: &str = "media.video";

#[cfg(test)]
mod tests {
    use super::*;

    fn sent(a: &[SignalAction]) -> Value {
        let SignalAction::Send { text } = &a[0] else { panic!("{a:?}") };
        serde_json::from_str(text).unwrap()
    }

    #[test]
    fn follows_the_robots_web_client() {
        let sig = Signalling::new();
        assert_eq!(sent(&sig.on_message(r#"{"type":"welcome","peerId":"me"}"#.into()))["type"], "list");
        let list = r#"{"type":"list","producers":[{"id":"p1","meta":{"name":"fanduck","release":"0.17.8","api_version":"44"}}]}"#;
        let start = sent(&sig.on_message(list.into()));
        assert_eq!(start, json!({"type":"startSession","peerId":"p1"}));
        assert_eq!(sig.producer().unwrap().name.as_deref(), Some("fanduck"));
        // 第二份列表（机器人上下线通知）不再开会话
        assert!(sig.on_message(list.into()).is_empty());
        assert_eq!(sig.on_message(r#"{"type":"sessionStarted","peerId":"p1","sessionId":"s1"}"#.into()), vec![SignalAction::CreatePeer]);
        assert_eq!(
            sig.on_message(r#"{"type":"peer","sessionId":"s1","sdp":{"type":"offer","sdp":"v=0"}}"#.into()),
            vec![SignalAction::RemoteOffer { sdp: "v=0".into() }]
        );
        assert_eq!(
            sig.on_message(r#"{"type":"peer","sessionId":"s1","ice":{"candidate":"candidate:1 1 UDP 1 1.2.3.4 5 typ host","sdpMLineIndex":0}}"#.into()),
            vec![SignalAction::RemoteIce { candidate: "candidate:1 1 UDP 1 1.2.3.4 5 typ host".into(), sdp_mline_index: 0 }]
        );
        let ans: Value = serde_json::from_str(&sig.answer("v=0 a".into()).unwrap()).unwrap();
        assert_eq!(ans, json!({"type":"peer","sessionId":"s1","sdp":{"type":"answer","sdp":"v=0 a"}}));
        let ice: Value = serde_json::from_str(&sig.ice("candidate:x".into(), 1).unwrap()).unwrap();
        assert_eq!(ice["ice"]["sdpMLineIndex"], 1);
        // 别的会话的消息不理
        assert!(sig.on_message(r#"{"type":"peer","sessionId":"other","sdp":{"type":"offer","sdp":"x"}}"#.into()).is_empty());
    }

    #[test]
    fn restart_ends_then_lists_again() {
        let sig = Signalling::new();
        sig.on_message(r#"{"type":"list","producers":[{"id":"p1","meta":{}}]}"#.into());
        sig.on_message(r#"{"type":"sessionStarted","sessionId":"s1"}"#.into());
        let frames: Vec<Value> = sig.restart().iter().map(|t| serde_json::from_str(t).unwrap()).collect();
        assert_eq!(frames[0], json!({"type":"endSession","sessionId":"s1"}));
        assert_eq!(frames[1]["type"], "list");
        assert_eq!(sent(&sig.on_message(r#"{"type":"list","producers":[{"id":"p1","meta":{}}]}"#.into()))["type"], "startSession");
    }

    #[test]
    fn no_producer_and_robot_ending() {
        let sig = Signalling::new();
        assert_eq!(sig.on_message(r#"{"type":"list","producers":[]}"#.into()), vec![SignalAction::NoProducer]);
        sig.on_message(r#"{"type":"list","producers":[{"id":"p1"}]}"#.into());
        sig.on_message(r#"{"type":"sessionStarted","sessionId":"s1"}"#.into());
        assert!(matches!(&sig.on_message(r#"{"type":"endSession","sessionId":"s1"}"#.into())[0], SignalAction::Ended { .. }));
        assert!(sig.session_id().is_none());
    }

    #[test]
    fn video_rotation() {
        assert_eq!(decode_video_info(r#"{"width":1280,"height":720,"rotate":-90}"#), Some(VideoInfo { width: 1280, height: 720, rotate: 270 }));
        assert_eq!(video_info_notification("media.video".into(), r#"{"width":1280,"height":720,"rotate":90}"#.into()).unwrap().rotate, 90);
        assert!(video_info_notification("robot.state".into(), "{}".into()).is_none());
    }
}
