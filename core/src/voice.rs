//! 语音控制一"轮"的逻辑（技术方案 3.3）：豆包实时语音事件 → 转写 / 播报 / 工具调用，
//! 工具调用先攒住，松手到"发送"才规划执行；执行前按状态检查，移动限时限速由这里强制。
//!
//! WebSocket 连接、麦克风采集、扬声器播放由平台层实现（URLSessionWebSocketTask / OkHttp），
//! 这里只处理 JSON 文本帧，便于用录制的事件流回放测试。

use std::sync::{Arc, Mutex};

use base64::Engine as _;
use serde_json::{Value, json};

use crate::calls::{DuckCall, Quack};

pub const DOUBAO_URL: &str = "wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue";
pub const MODEL: &str = "1.2.6.1";
pub const VOICE: &str = "zh_female_vv_jupiter_bigtts";
/// 语音触发的移动上限（不信任模型参数）。
pub const MAX_MOVE_SECONDS: f64 = 5.0;
pub const DEFAULT_MOVE_SECONDS: f64 = 2.0;
/// 单句播报上限（秒），超出淡出截断。
pub const MAX_UTTERANCE_SECONDS: f64 = 4.0;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum DoubaoCredential {
    ApiKey { key: String },
    AppToken { app_id: String, access_token: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Header {
    pub name: String,
    pub value: String,
}

/// WebSocket 握手头。`request_id` 由平台层每次生成 UUID。
#[uniffi::export]
pub fn doubao_headers(credential: DoubaoCredential, request_id: String) -> Vec<Header> {
    let h = |n: &str, v: &str| Header { name: n.into(), value: v.into() };
    match credential {
        DoubaoCredential::ApiKey { key } => vec![h("X-Api-Key", &key), h("X-Api-Request-Id", &request_id)],
        DoubaoCredential::AppToken { app_id, access_token } => vec![
            h("X-Api-App-Id", &app_id),
            h("X-Api-Access-Key", &access_token),
            h("X-Api-Resource-Id", "volc.speech.dialog"),
            h("X-Api-App-Key", "PlgvMymc7f3tQnJ6"),
            h("X-Api-Request-Id", &request_id),
        ],
    }
}

#[uniffi::export]
pub fn doubao_url() -> String {
    DOUBAO_URL.into()
}

/// 每轮开始前给模型的当前状态。
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RobotContext {
    pub enabled: bool,
    pub sitting: bool,
    pub lying: bool,
    pub roller: bool,
    /// WebRTC teleop 通道是否连上（移动需要它）。
    pub teleop_ready: bool,
    /// 全局操作锁（加载策略、切换模式、配网）。
    pub busy: bool,
    pub skills: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum VoiceEvent {
    /// 实时转写；`final` 为 true 时整体替换。
    Transcript { text: String, is_final: bool },
    /// 播报音频（24 kHz s16le 单声道），已按松手前后决定是否放行。
    Speech { pcm: Vec<u8> },
    /// 播报字幕增量。
    Caption { text: String },
    /// 本轮模型输出结束。
    ResponseDone,
    /// 鉴权类错误：密钥失效，设置页标为不可用。
    AuthFailed { message: String },
    Error { message: String },
}

/// 规划好的一步。平台层按顺序执行，执行完用 [`VoiceTurn::tool_results`] 回传。
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum VoiceStep {
    /// 叫声与动作同时发出。`move_seconds` 不为空时，`call` 是 `robot.move`，平台以 20 Hz 发送到时发零速。
    Act { call_id: String, call: Option<DuckCall>, move_seconds: Option<f64>, quack: Option<Quack>, quack_times: u8, note: String },
    /// 前置条件不满足：叫 alarm，把原因回传模型。
    Refuse { call_id: String, reason: String },
    /// 停止：零速并清空后续步骤。
    Stop { call_id: String },
}

#[derive(Default)]
struct Turn {
    released: bool,
    sent: bool,
    transcript: String,
    pending_audio: Vec<Vec<u8>>,
    calls: Vec<(String, String, Value)>,
}

#[derive(uniffi::Object)]
pub struct VoiceTurn {
    event_id: Mutex<u64>,
    turn: Mutex<Turn>,
}

fn quack_of(s: &str) -> Option<Quack> {
    Some(match s {
        "chirp" => Quack::Chirp,
        "greet" => Quack::Greet,
        "inquire" => Quack::Inquire,
        "coo" => Quack::Coo,
        "wheee" => Quack::Wheee,
        "alarm" => Quack::Alarm,
        "peck" => Quack::Peck,
        _ => return None,
    })
}

const QUACKS: [&str; 7] = ["chirp", "greet", "inquire", "coo", "wheee", "alarm", "peck"];

#[uniffi::export]
impl VoiceTurn {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self { event_id: Mutex::new(0), turn: Mutex::new(Turn::default()) })
    }

    fn next_event(&self) -> u64 {
        let mut id = self.event_id.lock().unwrap();
        *id += 1;
        *id
    }

    /// `session.create` 帧。
    pub fn session_create(&self, session_id: String, duck_name: String, skills: Vec<String>) -> String {
        let quack = json!({"type":"string","enum":QUACKS});
        let tools = json!([
            {"type":"function","name":"duck_move","description":"让鸭子移动一段时间",
             "parameters":{"type":"object","properties":{
                "direction":{"type":"string","enum":["forward","backward","left","right","turn_left","turn_right"]},
                "seconds":{"type":"number","minimum":0.5,"maximum":5},"sound":quack},"required":["direction"]}},
            {"type":"function","name":"duck_stop","description":"立即停下","parameters":{"type":"object","properties":{}}},
            {"type":"function","name":"duck_posture","description":"坐下或站起来",
             "parameters":{"type":"object","properties":{"action":{"type":"string","enum":["sit","stand"]},"sound":quack},"required":["action"]}},
            {"type":"function","name":"duck_head","description":"头部动作",
             "parameters":{"type":"object","properties":{"action":{"type":"string","enum":["nod","shake","look_left","look_right","look_up","look_down","center"]},"sound":quack},"required":["action"]}},
            {"type":"function","name":"duck_skill","description":"做一个技能动作",
             "parameters":{"type":"object","properties":{"name":{"type":"string","enum":skills},"sound":quack},"required":["name"]}},
            {"type":"function","name":"duck_quack","description":"让鸭子叫",
             "parameters":{"type":"object","properties":{"tag":quack,"times":{"type":"integer","minimum":1,"maximum":3}},"required":["tag"]}}
        ]);
        let instructions = format!(
            "你是小鸭子机器人「{duck_name}」的遥控助手，用动作和叫声让鸭子回应用户。每次回应都必须调用工具。\
             说话只报状态和结果，每句不超过15个字，不寒暄、不解释、不反问。调用工具前最多说一句开始语，拿到工具结果后说一句结果。\
             工具返回失败时照原因简短说出。能连着做就按顺序调用多个工具。只是聊天时调用 duck_quack。\
             听不清时调用 duck_quack(tag=inquire)。一步约1秒，不超过5秒，没说时长按2秒。"
        );
        json!({
            "type":"session.create","event_id":self.next_event(),
            "session":{"id":session_id,"model":MODEL,"instructions":instructions,
                "audio":{"input":{"format":{"type":"pcm","rate":16000}},
                         "output":{"format":{"type":"pcm_s16le","rate":24000},"voice":VOICE}},
                "tools":tools},
            "extension":{"dialog":{"extra":{"strict_audit":false,"enable_music":false}}}
        })
        .to_string()
    }

    /// 每轮开始前更新状态（系统消息）。
    pub fn context_update(&self, ctx: RobotContext) -> String {
        let text = format!(
            "当前状态：{}，{}，{}模式，视频通道{}，技能：{}",
            if ctx.enabled { "已启动" } else { "未启动" },
            if ctx.lying { "躺倒" } else if ctx.sitting { "坐着" } else { "站着" },
            if ctx.roller { "轮子" } else { "双腿" },
            if ctx.teleop_ready { "已连上" } else { "未连上" },
            ctx.skills.join("、")
        );
        json!({"type":"conversation.item.create","event_id":self.next_event(),
               "item":{"type":"message","role":"system","content":[{"type":"input_text","text":text}]}})
        .to_string()
    }

    /// 按下：新的一轮。
    pub fn begin(&self) {
        *self.turn.lock().unwrap() = Turn::default();
    }

    /// 512 采样（32 ms）16 kHz s16le 一包。
    pub fn audio_append(&self, pcm: Vec<u8>) -> String {
        let audio = base64::engine::general_purpose::STANDARD.encode(pcm);
        json!({"type":"input_audio_buffer.append","event_id":self.next_event(),"audio":audio}).to_string()
    }

    pub fn commit(&self) -> String {
        json!({"type":"input_audio_buffer.commit","event_id":self.next_event()}).to_string()
    }

    pub fn session_close(&self) -> String {
        json!({"type":"session.close","event_id":self.next_event()}).to_string()
    }

    /// 松手。`send` 为 true（上划到"发送"）时返回松手前缓存的播报；取消时一律丢弃。
    pub fn release(&self, send: bool) -> Vec<VoiceEvent> {
        let mut t = self.turn.lock().unwrap();
        t.released = true;
        t.sent = send;
        let audio = std::mem::take(&mut t.pending_audio);
        if !send {
            return vec![];
        }
        audio.into_iter().map(|pcm| VoiceEvent::Speech { pcm }).collect()
    }

    /// 服务端一条文本帧。
    pub fn on_server_event(&self, text: String) -> Vec<VoiceEvent> {
        // 语音增量占下行绝大部分：只看头部判断类型，直接定位 "delta":" 解码，不做完整 JSON 解析。
        if text.contains("\"response.output_audio.delta\"") {
            let Some(start) = text.find("\"delta\":\"").map(|i| i + 9) else { return vec![] };
            let Some(len) = text[start..].find('"') else { return vec![] };
            let Ok(pcm) = base64::engine::general_purpose::STANDARD.decode(&text[start..start + len]) else {
                return vec![];
            };
            let mut t = self.turn.lock().unwrap();
            return match (t.released, t.sent) {
                (false, _) => {
                    t.pending_audio.push(pcm);
                    vec![]
                }
                (true, true) => vec![VoiceEvent::Speech { pcm }],
                (true, false) => vec![],
            };
        }
        let Ok(v) = serde_json::from_str::<Value>(&text) else { return vec![] };
        let kind = v["type"].as_str().unwrap_or_default();
        let mut t = self.turn.lock().unwrap();
        let cancelled = t.released && !t.sent;
        match kind {
            "conversation.item.input_audio_transcription.delta" if !cancelled => {
                t.transcript.push_str(v["delta"].as_str().unwrap_or_default());
                vec![VoiceEvent::Transcript { text: t.transcript.clone(), is_final: false }]
            }
            "conversation.item.input_audio_transcription.completed" if !cancelled => {
                let text = v["transcript"].as_str().or(v["text"].as_str()).unwrap_or_default().to_owned();
                t.transcript = text.clone();
                vec![VoiceEvent::Transcript { text, is_final: true }]
            }
            "response.function_call_arguments.done" => {
                let items = v["items"].as_array().cloned().unwrap_or_else(|| vec![v.clone()]);
                for item in items {
                    let name = item["name"].as_str().unwrap_or_default().to_owned();
                    let call_id = item["call_id"].as_str().unwrap_or_default().to_owned();
                    let args = item["arguments"]
                        .as_str()
                        .and_then(|a| serde_json::from_str(a).ok())
                        .unwrap_or_else(|| item["arguments"].clone());
                    t.calls.push((call_id, name, args));
                }
                vec![]
            }
            "response.output_text.delta" if !cancelled => {
                vec![VoiceEvent::Caption { text: v["delta"].as_str().unwrap_or_default().to_owned() }]
            }
            "response.done" => vec![VoiceEvent::ResponseDone],
            "error" => {
                let message = v["error"]["message"].as_str().or(v["message"].as_str()).unwrap_or("error").to_owned();
                let code = v["error"]["code"].to_string();
                if code.contains("auth") || code.contains("401") || code.contains("403") || message.contains("auth") {
                    vec![VoiceEvent::AuthFailed { message }]
                } else {
                    vec![VoiceEvent::Error { message }]
                }
            }
            _ => vec![],
        }
    }

    /// 本轮是否收到了工具调用（没有则按"没听懂"处理）。
    pub fn has_calls(&self) -> bool {
        !self.turn.lock().unwrap().calls.is_empty()
    }

    /// 把攒住的工具调用规划成步骤。取消的轮次返回空。
    pub fn plan(&self, ctx: RobotContext) -> Vec<VoiceStep> {
        let t = self.turn.lock().unwrap();
        if !t.sent {
            return vec![];
        }
        t.calls.iter().map(|(id, name, args)| plan_one(id, name, args, &ctx)).collect()
    }

    /// 取消的轮次也要把调用回传为"没有执行"，让模型上下文和实际一致。
    pub fn cancelled_results(&self) -> Vec<String> {
        let calls = self.turn.lock().unwrap().calls.clone();
        calls.iter().map(|(id, _, _)| self.tool_result(id.clone(), "用户取消了，没有执行".into())).collect()
    }

    /// 一个工具结果。全部回传后再发一次 [`Self::commit`]，模型才会说结果语。
    pub fn tool_result(&self, call_id: String, text: String) -> String {
        json!({"type":"conversation.item.create","event_id":self.next_event(),
               "item":{"type":"function_call_output","role":"tool","call_id":call_id,
                       "content":[{"type":"input_text","text":text}]}})
        .to_string()
    }
}

fn plan_one(id: &str, name: &str, args: &Value, ctx: &RobotContext) -> VoiceStep {
    let refuse = |reason: &str| VoiceStep::Refuse { call_id: id.into(), reason: reason.into() };
    let sound = args["sound"].as_str().and_then(quack_of);
    let act = |call: Option<DuckCall>, move_seconds: Option<f64>, default: Quack, note: String| VoiceStep::Act {
        call_id: id.into(),
        call,
        move_seconds,
        quack: Some(sound.unwrap_or(default)),
        quack_times: 1,
        note,
    };
    let physical = name != "duck_quack" && name != "duck_stop";
    if physical {
        if ctx.busy {
            return refuse("鸭子正在忙");
        }
        if !ctx.enabled {
            return refuse("鸭子还没启动");
        }
        if ctx.lying {
            return refuse("鸭子摔倒了");
        }
    }
    match name {
        "duck_stop" => VoiceStep::Stop { call_id: id.into() },
        "duck_move" => {
            if ctx.sitting {
                return refuse("鸭子坐着，先站起来");
            }
            if !ctx.teleop_ready {
                return refuse("没连上 Wi-Fi，只能原地动作");
            }
            let secs = args["seconds"].as_f64().unwrap_or(DEFAULT_MOVE_SECONDS).clamp(0.5, MAX_MOVE_SECONDS);
            let (vx, vy, vyaw) = match args["direction"].as_str().unwrap_or_default() {
                "forward" => (0.15, 0.0, 0.0),
                "backward" => (-0.15, 0.0, 0.0),
                "left" if !ctx.roller => (0.0, 0.1, 0.0),
                "right" if !ctx.roller => (0.0, -0.1, 0.0),
                "turn_left" => (0.0, 0.0, 0.75),
                "turn_right" => (0.0, 0.0, -0.75),
                _ => return refuse("鸭子不会这个"),
            };
            act(Some(DuckCall::RobotMove { vx, vy, vyaw }), Some(secs), Quack::Chirp, format!("移动 {secs:.1} 秒"))
        }
        "duck_posture" => {
            let want_sit = args["action"].as_str() == Some("sit");
            let call = (want_sit != ctx.sitting).then(|| DuckCall::RobotDo { skill: "sit_toggle".into() });
            let default = if want_sit { Quack::Coo } else { Quack::Greet };
            let note = match (&call, want_sit) {
                (None, true) => "已经坐着".to_owned(),
                (None, false) => "已经站着".to_owned(),
                (_, true) => "坐下".to_owned(),
                (_, false) => "站起".to_owned(),
            };
            act(call, None, default, note)
        }
        "duck_head" => {
            let a = args["action"].as_str().unwrap_or("center");
            let default = if a == "shake" { Quack::Inquire } else { Quack::Chirp };
            // 预设轨迹由平台层按 note 播放（点头 / 摇头为多段 robot.head），这里给出终点姿态。
            let (yaw, pitch) = match a {
                "look_left" => (0.6, 0.0),
                "look_right" => (-0.6, 0.0),
                "look_up" => (0.0, -0.3),
                "look_down" => (0.0, 0.3),
                _ => (0.0, 0.0),
            };
            act(
                Some(DuckCall::RobotHead { neck_pitch: 0.0, head_pitch: pitch, head_yaw: yaw, head_roll: 0.0 }),
                None,
                default,
                a.to_owned(),
            )
        }
        "duck_skill" => {
            let skill = args["name"].as_str().unwrap_or_default();
            if !ctx.skills.iter().any(|s| s == skill) {
                return refuse("鸭子不会这个");
            }
            if ctx.sitting && skill != "sit_toggle" {
                return refuse("鸭子坐着，先站起来");
            }
            let default = if skill.contains("roul") || skill.contains("roll") { Quack::Wheee } else { Quack::Chirp };
            act(Some(DuckCall::RobotDo { skill: skill.into() }), None, default, skill.into())
        }
        "duck_quack" => VoiceStep::Act {
            call_id: id.into(),
            call: None,
            move_seconds: None,
            quack: Some(args["tag"].as_str().and_then(quack_of).unwrap_or(Quack::Chirp)),
            quack_times: args["times"].as_u64().unwrap_or(1).clamp(1, 3) as u8,
            note: "叫".into(),
        },
        _ => refuse("鸭子不会这个"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> RobotContext {
        RobotContext {
            enabled: true,
            sitting: false,
            lying: false,
            roller: false,
            teleop_ready: true,
            busy: false,
            skills: vec!["kick_left".into(), "roulade".into()],
        }
    }

    fn call(name: &str, args: &str) -> String {
        json!({"type":"response.function_call_arguments.done",
               "items":[{"name":name,"call_id":"c1","arguments":args}]})
        .to_string()
    }

    #[test]
    fn calls_wait_for_send_and_are_limited() {
        let v = VoiceTurn::new();
        v.begin();
        v.on_server_event(call("duck_move", r#"{"direction":"forward","seconds":30}"#));
        assert!(v.plan(ctx()).is_empty(), "未松手不执行");
        v.release(true);
        let steps = v.plan(ctx());
        let VoiceStep::Act { move_seconds, call, .. } = &steps[0] else { panic!("{steps:?}") };
        assert_eq!(*move_seconds, Some(MAX_MOVE_SECONDS));
        assert_eq!(*call, Some(DuckCall::RobotMove { vx: 0.15, vy: 0.0, vyaw: 0.0 }));
    }

    #[test]
    fn cancel_discards_everything() {
        let v = VoiceTurn::new();
        v.begin();
        v.on_server_event(call("duck_skill", r#"{"name":"roulade"}"#));
        let audio = json!({"type":"response.output_audio.delta","delta":"AAAA"}).to_string();
        assert!(v.on_server_event(audio.clone()).is_empty());
        assert!(v.release(false).is_empty());
        assert!(v.on_server_event(audio).is_empty());
        assert!(v.plan(ctx()).is_empty());
        assert_eq!(v.cancelled_results().len(), 1);
    }

    #[test]
    fn prechecks_refuse() {
        let v = VoiceTurn::new();
        v.begin();
        v.on_server_event(call("duck_move", r#"{"direction":"forward"}"#));
        v.release(true);
        let mut c = ctx();
        c.sitting = true;
        assert_eq!(v.plan(c)[0], VoiceStep::Refuse { call_id: "c1".into(), reason: "鸭子坐着，先站起来".into() });
        let mut c = ctx();
        c.enabled = false;
        assert!(matches!(&v.plan(c)[0], VoiceStep::Refuse { reason, .. } if reason == "鸭子还没启动"));
    }
}
