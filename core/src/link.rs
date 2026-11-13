//! 蓝牙会话：一条 RPC 特征上的 NDJSON，安全模式下每行再包一层 Noise 信封。
//!
//! 平台层只负责：连接 → 读一次 RPC 特征（触发系统配对）→ 订阅通知 → 把 [`DuckLink::open`] 返回的
//! 字节写出去 → 每条通知交给 [`DuckLink::receive`] → 按返回的事件写字节或更新界面。
//!
//! 两种模式（authenticated-app-mvp.md）：
//! - **安全模式**（有 `md1:` 设置码）：`start → challenge → confirm → ready`，Noise
//!   `NNpsk0_25519_ChaChaPoly_SHA256`，之后全部 RPC 在 `data` 信封里加密；再发 `hello`。
//! - **PIN 模式**（旧机器人 / 开发板）：`hello` → `system.authenticate {pin: "000000"}`，出厂 PIN 由 App
//!   静默发送，不出现 PIN 输入页（mobile-app.md §8）。

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
    Ready,
    Closed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LinkFailure {
    /// 机器人低于 App 的版本下限，提示用 `duckctl update apply` 升级（mobile-app.md §6）。
    RobotTooOld { api_version: u32, minimum: u32 },
    /// 设置码与机器人不符（Noise 校验失败）。
    WrongKey,
    /// PIN 被拒绝（出厂 PIN 已改）。
    PinRejected { message: String },
    /// 字节流无法分帧或解密，会话必须丢弃。
    Framing,
    Protocol { detail: String },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum LinkEvent {
    /// 需要写到 RPC 特征上的字节（已按 MTU 切好）。
    Write { chunks: Vec<Vec<u8>> },
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
}

#[derive(uniffi::Object)]
pub struct DuckLink {
    inner: Mutex<Inner>,
}

#[uniffi::export]
impl DuckLink {
    /// `credential` 为 `None` 时走 PIN 模式。
    #[uniffi::constructor]
    pub fn new(credential: Option<SetupCode>) -> Arc<Self> {
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
    pub fn close(&self) {
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
                let id = self.take_id();
                self.auth_id = Some(id);
                let call = proto::Call::SystemAuthenticate(proto::AuthenticateParams { pin: FACTORY_PIN.into() });
                vec![Self::write(self.line_out(&request_line(id, &call)))]
            }
            Decoded::Reply { id, result } if Some(id) == self.auth_id => {
                self.auth_id = None;
                match serde_json::from_value::<proto::AuthenticateResult>(result) {
                    Ok(r) if r.authenticated => vec![self.ready()],
                    Ok(r) => self.fail(LinkFailure::PinRejected { message: format!("attempts_remaining={}", r.attempts_remaining) }),
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
        let link = DuckLink::new(None);
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

    #[test]
    fn refuses_old_robot() {
        let link = DuckLink::new(None);
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
        let link = DuckLink::new(Some(code));
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
        let link = DuckLink::new(Some(SetupCode { robot_id: "duck-test".into(), key: vec![1; 32] }));
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
