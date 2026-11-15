//! 蓝牙会话：一条 RPC 特征上的 NDJSON，安全模式下每行再包一层 Noise 信封。
//!
//! 平台层只负责：连接 → 读一次 RPC 特征（触发系统配对）→ 订阅通知 → 把 [`DuckLink::open`] 返回的
//! 字节写出去 → 每条通知交给 [`DuckLink::receive`] → 按返回的事件写字节或更新界面。
//!
//! 两种模式（authenticated-app-mvp.md）：
//! - **安全模式**（有 `md1:` 设置码）：`start → challenge → confirm → ready`，Noise
//!   `NNpsk0_25519_ChaChaPoly_SHA256`，之后全部 RPC 在 `data` 信封里加密；再发 `hello`。
//! - **PIN 模式**（没有设置码的机器人）：`hello` → `system.authenticate`。先静默发已保存的 PIN，没有就发
//!   出厂 PIN `000000`（开发板）。机器人看不出要不要 PIN（`hello` 和广播都不说），所以只能试：
//!   被拒时给出 [`LinkEvent::PinRequired`]，会话停在 [`LinkPhase::AwaitingPin`]，平台层请用户输入标签上的
//!   PIN 后调 [`DuckLink::submit_pin`]。贴了标签的机器人默认 PIN 是标签序列号的最后 6 位（configd
//!   `identity::default_pin`）。btd 每个会话给 3 次机会，用完就断开。

use std::sync::{Arc, Mutex};

use duck_auth::wire::{Frame, MAX_CLIENT_LINE, MAX_ROBOT_LINE};
use duck_auth::{ClientConfirm, ClientStart, Session};
use duck_ble::framing::{self, Reassembler};
use duck_ipc_proto as proto;

use crate::calls::DuckCall;
use crate::setup_code::SetupCode;
use crate::state::DuckState;
use crate::{CoreError, MIN_API_VERSION};

/// 出厂 PIN：公开在官方仓库里，不保护任何东西，所以静默发送。
const FACTORY_PIN: &str = "000000";

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkPhase {
    Idle,
    /// Noise 握手中（安全模式）。15 秒内未完成机器人会断开。
    Handshaking,
    /// `hello` / PIN 认证中。
    Authenticating,
    /// PIN 被拒，等平台层 [`DuckLink::submit_pin`]。
    AwaitingPin,
    Ready,
    Closed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LinkFailure {
    /// 机器人低于 App 的版本下限，提示用 `duckctl update apply` 升级（mobile-app.md §6）。
    RobotTooOld { api_version: u32, minimum: u32 },
    /// 设置码与机器人不符（Noise 校验失败）。
    WrongKey,
    /// PIN 被拒绝且机会用完（btd 随即断开），或机器人无法校验 PIN。
    PinRejected { message: String },
    /// 字节流无法分帧或解密，会话必须丢弃。
    Framing,
    Protocol { detail: String },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum LinkEvent {
    /// 需要写到 RPC 特征上的字节（已按 MTU 切好）。
    Write { chunks: Vec<Vec<u8>> },
    /// 这只机器人要 PIN：请用户输入后调 [`DuckLink::submit_pin`]。`wrong_pin` 为真表示刚才试的是
    /// 用户给的（或保存的）PIN，而不是出厂 PIN。
    PinRequired { attempts_remaining: u32, wrong_pin: bool },
    /// 会话可用：之后可以发 [`DuckLink::request`]。
    Authenticated { api_version: u32, daemon_version: Option<String> },
    /// 某个请求的成功回复，`result_json` 交给 [`crate::results`] 的解码函数。
    Reply { id: u64, result_json: String },
    /// 某个请求被拒绝；`message` 为机器人原文，可直接显示。
    Refused { id: u64, code: i32, message: String },
    /// `robot.state` 流的一帧（WebRTC 上的订阅）。
    State { state: DuckState },
    /// 其他通知（如更新进度），原样上交。
    Notification { method: String, params_json: String },
    Failed { failure: LinkFailure },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OutboundRequest {
    pub id: u64,
    pub chunks: Vec<Vec<u8>>,
}

enum Secure {
    None,
    Start(ClientStart),
    Confirm(ClientConfirm),
    Ready(Session),
}

struct Inner {
    credential: Option<SetupCode>,
    mtu: u16,
    phase: LinkPhase,
    secure: Secure,
    inbound: Reassembler,
    next_id: u64,
    hello_id: Option<u64>,
    auth_id: Option<u64>,
    hello: Option<proto::HelloResult>,
    /// 下一次认证发的 PIN；`None` 时发出厂 PIN。
    pin: Option<String>,
    /// 正在校验的 PIN 是否来自用户（而非出厂 PIN）。
    custom_pin_sent: bool,
}

#[derive(uniffi::Object)]
pub struct DuckLink {
    inner: Mutex<Inner>,
}

#[uniffi::export]
impl DuckLink {
    /// `credential` 为 `None` 时走 PIN 模式；`pin` 是之前保存的 PIN（没有就先试出厂 PIN）。
    #[uniffi::constructor]
    pub fn new(credential: Option<SetupCode>, pin: Option<String>) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(Inner {
                credential,
                mtu: 23,
                phase: LinkPhase::Idle,
                secure: Secure::None,
                inbound: Reassembler::for_replies(),
                next_id: 1,
                hello_id: None,
                auth_id: None,
                hello: None,
                pin: pin.filter(|p| is_valid_pin(p.clone())),
                custom_pin_sent: false,
            }),
        })
    }

    /// 平台层拿到协商后的 ATT MTU 时调用（iOS `maximumWriteValueLength + 3`，Android `onMtuChanged`）。
    pub fn set_mtu(&self, mtu: u16) {
        self.inner.lock().unwrap().mtu = mtu;
    }

    pub fn phase(&self) -> LinkPhase {
        self.inner.lock().unwrap().phase
    }

    pub fn is_secure(&self) -> bool {
        self.inner.lock().unwrap().credential.is_some()
    }

    /// 机器人已回复 `hello`。PIN 模式下迟迟没有回复，多半是要设置码的机器人（安全模式的 btd 不理明文）。
    pub fn hello_answered(&self) -> bool {
        self.inner.lock().unwrap().hello.is_some()
    }

    /// 认证通过时用的 PIN（出厂 PIN 为 `None`）：平台层据此保存，下次静默重连。
    pub fn pin(&self) -> Option<String> {
        let s = self.inner.lock().unwrap();
        if s.phase == LinkPhase::Ready && s.custom_pin_sent { s.pin.clone() } else { None }
    }

    /// 用户输入 PIN 后调用（仅在 [`LinkPhase::AwaitingPin`]）：返回要写的字节。
    pub fn submit_pin(&self, pin: String) -> Result<Vec<Vec<u8>>, CoreError> {
        let mut s = self.inner.lock().unwrap();
        if s.phase != LinkPhase::AwaitingPin {
            return Err(CoreError::NotReady);
        }
        if !is_valid_pin(pin.clone()) {
            return Err(CoreError::BadPin);
        }
        s.pin = Some(pin);
        s.phase = LinkPhase::Authenticating;
        s.send_authenticate()
    }

    /// 链路（重新）建立后调用：返回第一批要写的字节。断线重连时重新调用即可，状态全部重置。
    pub fn open(&self) -> Result<Vec<Vec<u8>>, CoreError> {
        let mut s = self.inner.lock().unwrap();
        s.inbound = Reassembler::for_replies();
        s.hello = None;
        s.hello_id = None;
        s.auth_id = None;
        match s.credential.clone() {
            Some(code) => {
                let key: [u8; 32] = code.key.as_slice().try_into().map_err(|_| CoreError::BadSetupCode)?;
                let (start, first) = ClientStart::begin(&key, &code.robot_id).map_err(|_| CoreError::BadSetupCode)?;
                s.secure = Secure::Start(start);
                s.phase = LinkPhase::Handshaking;
                s.frame_out(Frame::Start(first))
            }
            None => {
                s.secure = Secure::None;
                s.phase = LinkPhase::Authenticating;
                s.send_hello()
            }
        }
    }

    /// 平台层收到一条通知时调用。
    pub fn receive(&self, chunk: Vec<u8>) -> Vec<LinkEvent> {
        let mut s = self.inner.lock().unwrap();
        let lines = match s.inbound.push(&chunk) {
            Ok(lines) => lines,
            Err(_) => return s.fail(LinkFailure::Framing),
        };
        let mut events = Vec::new();
        for line in lines {
            events.extend(s.on_line(&line));
            if s.phase == LinkPhase::Closed {
                break;
            }
        }
        events
    }

    /// 发一个请求。会话未认证时返回 [`CoreError::NotReady`]。
    pub fn request(&self, call: DuckCall) -> Result<OutboundRequest, CoreError> {
        let mut s = self.inner.lock().unwrap();
        if s.phase != LinkPhase::Ready {
            return Err(CoreError::NotReady);
        }
        let id = s.take_id();
        let line = request_line(id, &call.to_proto());
        let chunks = s.line_out(&line)?;
        Ok(OutboundRequest { id, chunks })
    }

    /// 链路断开时调用。认证会话不跨链路保留（btd 在中心断开时丢弃会话）。
    pub fn shutdown(&self) {
        let mut s = self.inner.lock().unwrap();
        s.phase = LinkPhase::Closed;
        s.secure = Secure::None;
    }
}

impl Inner {
    fn take_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    fn chunk(&self, line: &str) -> Vec<Vec<u8>> {
        framing::chunks(line, framing::notification_payload(self.mtu))
    }

    fn frame_out(&self, frame: Frame) -> Result<Vec<Vec<u8>>, CoreError> {
        let line = frame.encode(MAX_CLIENT_LINE).map_err(|_| CoreError::TooLarge)?;
        Ok(self.chunk(&line))
    }

    /// 一行明文 JSON-RPC 写出：安全模式加密成 `data` 信封，否则原样。
    fn line_out(&mut self, line: &str) -> Result<Vec<Vec<u8>>, CoreError> {
        if self.credential.is_none() {
            if line.len() + 1 > framing::MAX_LINE {
                return Err(CoreError::TooLarge);
            }
            return Ok(self.chunk(line));
        }
        let Secure::Ready(session) = &mut self.secure else { return Err(CoreError::NotReady) };
        let sealed = session.seal(line.as_bytes()).map_err(|_| CoreError::Closed)?;
        self.frame_out(Frame::Data(sealed))
    }

    fn send_hello(&mut self) -> Result<Vec<Vec<u8>>, CoreError> {
        let id = self.take_id();
        self.hello_id = Some(id);
        let line = request_line(id, &proto::Call::Hello(proto::HelloParams { api_version: proto::API_VERSION }));
        self.line_out(&line)
    }

    fn send_authenticate(&mut self) -> Result<Vec<Vec<u8>>, CoreError> {
        let id = self.take_id();
        self.auth_id = Some(id);
        self.custom_pin_sent = self.pin.is_some();
        let pin = self.pin.clone().unwrap_or_else(|| FACTORY_PIN.into());
        let call = proto::Call::SystemAuthenticate(proto::AuthenticateParams { pin });
        self.line_out(&request_line(id, &call))
    }

    fn fail(&mut self, failure: LinkFailure) -> Vec<LinkEvent> {
        self.phase = LinkPhase::Closed;
        self.secure = Secure::None;
        vec![LinkEvent::Failed { failure }]
    }

    fn write(result: Result<Vec<Vec<u8>>, CoreError>) -> LinkEvent {
        match result {
            Ok(chunks) => LinkEvent::Write { chunks },
            Err(e) => LinkEvent::Failed { failure: LinkFailure::Protocol { detail: e.to_string() } },
        }
    }

    fn on_line(&mut self, line: &str) -> Vec<LinkEvent> {
        if self.credential.is_none() {
            return self.on_plain(line);
        }
        let Ok(frame) = Frame::decode(line, MAX_ROBOT_LINE) else { return self.fail(LinkFailure::Framing) };
        match (std::mem::replace(&mut self.secure, Secure::None), frame) {
            (Secure::Start(start), Frame::Challenge(challenge)) => match start.receive(&challenge) {
                Ok((confirm, proof)) => {
                    self.secure = Secure::Confirm(confirm);
                    vec![Self::write(self.frame_out(Frame::Confirm(proof)))]
                }
                Err(_) => self.fail(LinkFailure::WrongKey),
            },
            (Secure::Confirm(confirm), Frame::Ready(reply)) => match confirm.receive(&reply) {
                Ok(session) => {
                    self.secure = Secure::Ready(session);
                    self.phase = LinkPhase::Authenticating;
                    vec![Self::write(self.send_hello())]
                }
                Err(_) => self.fail(LinkFailure::WrongKey),
            },
            (Secure::Ready(mut session), Frame::Data(sealed)) => {
                let opened = session.open(&sealed);
                self.secure = Secure::Ready(session);
                match opened.ok().and_then(|p| String::from_utf8(p).ok()) {
                    Some(plain) => self.on_plain(&plain),
                    None => self.fail(LinkFailure::Framing),
                }
            }
            _ => self.fail(LinkFailure::Protocol { detail: "unexpected secure frame".into() }),
        }
    }

    fn on_plain(&mut self, line: &str) -> Vec<LinkEvent> {
        let Some(event) = decode_line(line) else {
            return vec![];
        };
        match event {
            Decoded::Reply { id, result } if Some(id) == self.hello_id => {
                self.hello_id = None;
                let hello: proto::HelloResult = match serde_json::from_value(result) {
                    Ok(h) => h,
                    Err(e) => return self.fail(LinkFailure::Protocol { detail: e.to_string() }),
                };
                if hello.api_version < MIN_API_VERSION {
                    return self.fail(LinkFailure::RobotTooOld {
                        api_version: hello.api_version,
                        minimum: MIN_API_VERSION,
                    });
                }
                self.hello = Some(hello.clone());
                if self.credential.is_some() {
                    return vec![self.ready()];
                }
                vec![Self::write(self.send_authenticate())]
            }
            Decoded::Reply { id, result } if Some(id) == self.auth_id => {
                self.auth_id = None;
                match serde_json::from_value::<proto::AuthenticateResult>(result) {
                    Ok(r) if r.authenticated => vec![self.ready()],
                    Ok(r) if r.attempts_remaining == 0 => {
                        self.fail(LinkFailure::PinRejected { message: "attempts_remaining=0".into() })
                    }
                    Ok(r) => {
                        self.phase = LinkPhase::AwaitingPin;
                        vec![LinkEvent::PinRequired { attempts_remaining: r.attempts_remaining, wrong_pin: self.custom_pin_sent }]
                    }
                    Err(e) => self.fail(LinkFailure::Protocol { detail: e.to_string() }),
                }
            }
            Decoded::Error { id, message, .. } if id.is_some() && (id == self.hello_id || id == self.auth_id) => {
                if id == self.auth_id {
                    self.fail(LinkFailure::PinRejected { message })
                } else {
                    self.fail(LinkFailure::Protocol { detail: message })
                }
            }
            other => vec![other.into_event()],
        }
    }

    fn ready(&mut self) -> LinkEvent {
        self.phase = LinkPhase::Ready;
        let hello = self.hello.clone().expect("hello before ready");
        LinkEvent::Authenticated {
            api_version: hello.api_version,
            daemon_version: hello.daemon_version.map(|v| v.to_string()),
        }
    }
}

/// PIN 是 6 位数字（configd `store::PIN_DIGITS`），按字符串比较，`000042` 与 `42` 不同。
#[uniffi::export]
pub fn is_valid_pin(pin: String) -> bool {
    pin.len() == 6 && pin.bytes().all(|b| b.is_ascii_digit())
}

fn request_line(id: u64, call: &proto::Call) -> String {
    serde_json::to_string(&proto::Request::call(proto::Id::Number(id), call)).expect("requests serialise")
}

enum Decoded {
    Reply { id: u64, result: serde_json::Value },
    Error { id: Option<u64>, code: i32, message: String },
    Notification(proto::Request),
}

impl Decoded {
    fn into_event(self) -> LinkEvent {
        match self {
            Self::Reply { id, result } => LinkEvent::Reply { id, result_json: result.to_string() },
            Self::Error { id, code, message } => LinkEvent::Refused { id: id.unwrap_or(0), code, message },
            Self::Notification(req) => match req.as_state() {
                Some(state) => LinkEvent::State { state: DuckState::from_proto(&state) },
                None => LinkEvent::Notification {
                    method: req.method.clone(),
                    params_json: req.params.map(|p| p.to_string()).unwrap_or_else(|| "null".into()),
                },
            },
        }
    }
}

fn decode_line(line: &str) -> Option<Decoded> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    if value.get("method").is_some() {
        return serde_json::from_value::<proto::Request>(value).ok().map(Decoded::Notification);
    }
    let response: proto::Response = serde_json::from_value(value).ok()?;
    let id = match response.id {
        Some(proto::Id::Number(n)) => Some(n),
        Some(proto::Id::Text(t)) => t.parse().ok(),
        None => None,
    };
    if let Some(err) = response.error {
        return Some(Decoded::Error { id, code: err.code, message: err.message });
    }
    Some(Decoded::Reply { id: id?, result: response.result.unwrap_or(serde_json::Value::Null) })
}

/// WebRTC 数据通道上的 JSON-RPC：同一套消息，不分块、不加密（通道本身已经过网关认证）。
#[derive(uniffi::Object)]
pub struct RpcCodec {
    next_id: Mutex<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OutboundLine {
    /// 连续意图是通知，没有 id。
    pub id: Option<u64>,
    /// 一行 JSON（不含换行）。
    pub line: String,
    /// 发到不可靠的 `teleop` 通道（否则 `control` 通道）。
    pub teleop: bool,
}

#[uniffi::export]
impl RpcCodec {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self { next_id: Mutex::new(1) })
    }

    pub fn encode(&self, call: DuckCall) -> OutboundLine {
        let proto_call = call.to_proto();
        if call.is_continuous() {
            let line = serde_json::to_string(&proto::Request::notify(&proto_call)).expect("requests serialise");
            return OutboundLine { id: None, line, teleop: true };
        }
        let mut next = self.next_id.lock().unwrap();
        let id = *next;
        *next += 1;
        OutboundLine { id: Some(id), line: request_line(id, &proto_call), teleop: false }
    }

    pub fn decode(&self, line: String) -> Option<LinkEvent> {
        decode_line(&line).map(Decoded::into_event)
    }

    /// `media.video`（画面尺寸、相机安装角度），走 `control` 通道，回复用
    /// [`crate::signalling::decode_video_info`] 解。
    pub fn encode_media_video(&self) -> OutboundLine {
        let mut next = self.next_id.lock().unwrap();
        let id = *next;
        *next += 1;
        let line = serde_json::json!({"jsonrpc":"2.0","id":id,"method":crate::signalling::MEDIA_VIDEO,"params":{}}).to_string();
        OutboundLine { id: Some(id), line, teleop: false }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use duck_auth::RobotConfirm;

    fn reassemble(chunks: &[Vec<u8>]) -> String {
        let mut r = Reassembler::new();
        let mut out = vec![];
        for c in chunks {
            out.extend(r.push(c).unwrap());
        }
        assert_eq!(out.len(), 1);
        out.remove(0)
    }

    fn to_robot_chunks(line: &str) -> Vec<Vec<u8>> {
        framing::chunks(line, 20)
    }

    fn hello_reply(id: u64, api: u32) -> String {
        format!(r#"{{"jsonrpc":"2.0","id":{id},"result":{{"api_version":{api},"daemon_version":"0.20.1","revision":null}}}}"#)
    }

    #[test]
    fn pin_mode_hello_then_factory_pin() {
        let link = DuckLink::new(None, None);
        let first = reassemble(&link.open().unwrap());
        let req: serde_json::Value = serde_json::from_str(&first).unwrap();
        assert_eq!(req["method"], proto::method::HELLO);
        let id = req["id"].as_u64().unwrap();

        let mut events = vec![];
        for c in to_robot_chunks(&hello_reply(id, proto::API_VERSION)) {
            events.extend(link.receive(c));
        }
        let LinkEvent::Write { chunks } = &events[0] else { panic!("{events:?}") };
        let auth: serde_json::Value = serde_json::from_str(&reassemble(chunks)).unwrap();
        assert_eq!(auth["params"]["pin"], "000000");
        let reply = format!(r#"{{"jsonrpc":"2.0","id":{},"result":{{"authenticated":true,"attempts_remaining":3}}}}"#, auth["id"]);
        let events: Vec<_> = to_robot_chunks(&reply).into_iter().flat_map(|c| link.receive(c)).collect();
        assert!(matches!(events[0], LinkEvent::Authenticated { .. }));
        assert_eq!(link.phase(), LinkPhase::Ready);
        assert!(link.request(DuckCall::NetStatus).is_ok());
    }

    fn feed(link: &DuckLink, line: &str) -> Vec<LinkEvent> {
        to_robot_chunks(line).into_iter().flat_map(|c| link.receive(c)).collect()
    }

    /// hello 之后的认证请求：返回 (id, pin)。
    fn auth_after_hello(link: &DuckLink) -> (u64, String) {
        let first = reassemble(&link.open().unwrap());
        let id = serde_json::from_str::<serde_json::Value>(&first).unwrap()["id"].as_u64().unwrap();
        let events = feed(link, &hello_reply(id, proto::API_VERSION));
        assert!(link.hello_answered());
        let LinkEvent::Write { chunks } = &events[0] else { panic!("{events:?}") };
        auth_request(chunks)
    }

    fn auth_request(chunks: &[Vec<u8>]) -> (u64, String) {
        let auth: serde_json::Value = serde_json::from_str(&reassemble(chunks)).unwrap();
        assert_eq!(auth["method"], proto::method::SYSTEM_AUTHENTICATE);
        (auth["id"].as_u64().unwrap(), auth["params"]["pin"].as_str().unwrap().to_owned())
    }

    fn auth_reply(id: u64, ok: bool, left: u32) -> String {
        format!(r#"{{"jsonrpc":"2.0","id":{id},"result":{{"authenticated":{ok},"attempts_remaining":{left}}}}}"#)
    }

    /// 贴了标签的机器人：出厂 PIN 被拒 → 请用户输入 → 输错一次 → 输对。
    #[test]
    fn labelled_robot_asks_for_the_pin() {
        let link = DuckLink::new(None, None);
        let (id, pin) = auth_after_hello(&link);
        assert_eq!(pin, "000000");
        assert_eq!(feed(&link, &auth_reply(id, false, 2)), vec![LinkEvent::PinRequired { attempts_remaining: 2, wrong_pin: false }]);
        assert_eq!(link.phase(), LinkPhase::AwaitingPin);
        assert!(matches!(link.request(DuckCall::NetStatus), Err(CoreError::NotReady)));
        assert!(matches!(link.submit_pin("12345".into()), Err(CoreError::BadPin)));

        let (id, pin) = auth_request(&link.submit_pin("111111".into()).unwrap());
        assert_eq!(pin, "111111");
        assert_eq!(feed(&link, &auth_reply(id, false, 1)), vec![LinkEvent::PinRequired { attempts_remaining: 1, wrong_pin: true }]);

        let (id, pin) = auth_request(&link.submit_pin("004242".into()).unwrap());
        assert_eq!(pin, "004242");
        assert!(matches!(feed(&link, &auth_reply(id, true, 3))[0], LinkEvent::Authenticated { .. }));
        assert_eq!(link.pin().as_deref(), Some("004242"));
    }

    #[test]
    fn saved_pin_is_sent_first_and_factory_pin_is_not_saved() {
        let link = DuckLink::new(None, Some("004242".into()));
        let (id, pin) = auth_after_hello(&link);
        assert_eq!(pin, "004242");
        assert!(matches!(feed(&link, &auth_reply(id, true, 3))[0], LinkEvent::Authenticated { .. }));
        assert_eq!(link.pin().as_deref(), Some("004242"));

        let link = DuckLink::new(None, None);
        let (id, _) = auth_after_hello(&link);
        feed(&link, &auth_reply(id, true, 3));
        assert_eq!(link.pin(), None);
    }

    #[test]
    fn last_wrong_pin_ends_the_session() {
        let link = DuckLink::new(None, Some("111111".into()));
        let (id, _) = auth_after_hello(&link);
        assert_eq!(feed(&link, &auth_reply(id, false, 0)), vec![LinkEvent::Failed { failure: LinkFailure::PinRejected { message: "attempts_remaining=0".into() } }]);
        assert_eq!(link.phase(), LinkPhase::Closed);
    }

    #[test]
    fn refuses_old_robot() {
        let link = DuckLink::new(None, None);
        let first = reassemble(&link.open().unwrap());
        let id = serde_json::from_str::<serde_json::Value>(&first).unwrap()["id"].as_u64().unwrap();
        let events: Vec<_> = to_robot_chunks(&hello_reply(id, 30)).into_iter().flat_map(|c| link.receive(c)).collect();
        assert_eq!(
            events,
            vec![LinkEvent::Failed { failure: LinkFailure::RobotTooOld { api_version: 30, minimum: 31 } }]
        );
    }

    /// 与官方 `duck-auth` 机器人端互通：握手 → 加密 hello → 加密请求。
    #[test]
    fn secure_mode_interoperates_with_robot_side() {
        let key = [0x71u8; 32];
        let code = SetupCode { robot_id: "duck-test".into(), key: key.to_vec() };
        let link = DuckLink::new(Some(code), None);
        let start = Frame::decode(&reassemble(&link.open().unwrap()), MAX_CLIENT_LINE).unwrap();
        let Frame::Start(first) = start else { panic!() };
        let (robot, challenge) = RobotConfirm::respond(&key, "duck-test", &first).unwrap();
        let line = Frame::Challenge(challenge).encode(MAX_ROBOT_LINE).unwrap();
        let events: Vec<_> = to_robot_chunks(&line).into_iter().flat_map(|c| link.receive(c)).collect();
        let LinkEvent::Write { chunks } = &events[0] else { panic!() };
        let Frame::Confirm(proof) = Frame::decode(&reassemble(chunks), MAX_CLIENT_LINE).unwrap() else { panic!() };
        let (mut session, ready) = robot.receive(&proof).unwrap();
        let line = Frame::Ready(ready).encode(MAX_ROBOT_LINE).unwrap();
        let events: Vec<_> = to_robot_chunks(&line).into_iter().flat_map(|c| link.receive(c)).collect();
        let LinkEvent::Write { chunks } = &events[0] else { panic!() };
        let Frame::Data(sealed) = Frame::decode(&reassemble(chunks), MAX_CLIENT_LINE).unwrap() else { panic!() };
        let hello: serde_json::Value = serde_json::from_slice(&session.open(&sealed).unwrap()).unwrap();
        assert_eq!(hello["method"], proto::method::HELLO);

        let reply = session.seal(hello_reply(hello["id"].as_u64().unwrap(), proto::API_VERSION).as_bytes()).unwrap();
        let line = Frame::Data(reply).encode(MAX_ROBOT_LINE).unwrap();
        let events: Vec<_> = to_robot_chunks(&line).into_iter().flat_map(|c| link.receive(c)).collect();
        assert!(matches!(events[0], LinkEvent::Authenticated { .. }), "{events:?}");

        let out = link.request(DuckCall::NetScan).unwrap();
        let Frame::Data(sealed) = Frame::decode(&reassemble(&out.chunks), MAX_CLIENT_LINE).unwrap() else { panic!() };
        let req: serde_json::Value = serde_json::from_slice(&session.open(&sealed).unwrap()).unwrap();
        assert_eq!(req["method"], proto::method::NET_SCAN);
    }

    #[test]
    fn wrong_key_never_opens_a_session() {
        let link = DuckLink::new(Some(SetupCode { robot_id: "duck-test".into(), key: vec![1; 32] }), None);
        let Frame::Start(first) = Frame::decode(&reassemble(&link.open().unwrap()), MAX_CLIENT_LINE).unwrap() else {
            panic!()
        };
        // 机器人用另一把钥匙：无法解开第一条消息，会直接断开。
        assert!(RobotConfirm::respond(&[2; 32], "duck-test", &first).is_err());
        assert_eq!(link.phase(), LinkPhase::Handshaking);
        assert!(matches!(link.request(DuckCall::NetStatus), Err(CoreError::NotReady)));
    }

    #[test]
    fn datachannel_teleop_is_a_notification() {
        let codec = RpcCodec::new();
        let out = codec.encode(DuckCall::RobotMove { vx: 0.1, vy: 0.0, vyaw: 0.0 });
        assert!(out.teleop && out.id.is_none());
        let v: serde_json::Value = serde_json::from_str(&out.line).unwrap();
        assert_eq!(v["method"], proto::method::ROBOT_MOVE);
        let out = codec.encode(DuckCall::RobotDo { skill: "kick_left".into() });
        assert_eq!(out.id, Some(1));
    }
}
