//! 三个玩法：追激光、自己踢球、自由活动（官方 `robot.laserTrack`、`robot.soccer`、`robot.autonomous`）。
//!
//! 它们都是开关，不是数据流：打开后由机器人自己的摄像头和大脑带着它走，和碰一下 NFC 模式卡一样。
//! 手机只负责开关，摇杆照常可用（推动摇杆时摇杆优先）。一次只玩一个，切换规则照抄 NFC 模式卡
//! （`nfc/src/modes.rs`）：开一个就把另外两个关掉。机器人自己也让踢球和激光互斥。
//!
//! 版本：激光 API 52、踢球 58、自由活动 60；`robot.mode` 报告哪个开着从 67 起才全
//! （之前只有踢球和自由活动）。蓝牙（btd）从 0.23.0（API 67）起才转发这些调用，更早的机器人
//! 只能走视频通道（`mediad` 的 `control`）。

use duck_ipc_proto as proto;

use crate::calls::DuckCall;
use crate::results::parse;
use crate::CoreError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Game {
    /// 追激光点：头跟着地上的红点，走过去。
    Laser,
    /// 自己踢球：找紫色的球，走过去，用近的那只脚踢。
    Soccer,
    /// 自由活动（`autod`）：没人操控时自己逛、追激光、玩球、避开障碍。
    Autonomous,
}

const ALL: [Game; 3] = [Game::Laser, Game::Soccer, Game::Autonomous];

/// 蓝牙开始转发玩法开关和 `robot.mode` 的 API 版本（robot 0.23.0）。
pub const GAMES_OVER_BLE_API_VERSION: u32 = 67;

fn since(game: Game) -> u32 {
    match game {
        Game::Laser => 52,
        Game::Soccer => 58,
        Game::Autonomous => 60,
    }
}

/// 这台机器人有的玩法。`over_media`：视频通道开着（`mediad` 早就转发这些调用）。
/// 只有蓝牙时要 API 67 才行。
#[uniffi::export]
pub fn available_games(api_version: u32, over_media: bool) -> Vec<Game> {
    if !over_media && api_version < GAMES_OVER_BLE_API_VERSION {
        return vec![];
    }
    ALL.into_iter().filter(|g| api_version >= since(*g)).collect()
}

/// 机器人报告的玩法状态（`robot.mode` 的回复）。
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct Games {
    pub laser: bool,
    pub soccer: bool,
    pub autonomous: bool,
}

impl Games {
    pub fn is_on(&self, game: Game) -> bool {
        match game {
            Game::Laser => self.laser,
            Game::Soccer => self.soccer,
            Game::Autonomous => self.autonomous,
        }
    }
}

#[uniffi::export]
pub fn decode_games(json: &str) -> Result<Games, CoreError> {
    let r: proto::ModeResult = parse(json)?;
    Ok(Games { laser: r.laser, soccer: r.soccer.is_some_and(|s| s.active), autonomous: r.autonomous })
}

/// `game` 现在是否开着（平台层不用自己写 match）。
#[uniffi::export]
pub fn game_is_on(games: Games, game: Game) -> bool {
    games.is_on(game)
}

/// 打开 / 关掉一个玩法要依次发的调用。打开时先关掉另外两个（机器人不支持的跳过），
/// 和 NFC 模式卡一样一次只玩一个。踢球用自主踢球（手动踢球模式只是把踢球放到手柄肩键上，
/// App 的驾驶页本来就有踢球键）。
#[uniffi::export]
pub fn game_calls(game: Game, on: bool, api_version: u32) -> Vec<DuckCall> {
    let switch = |g: Game, active: bool| match g {
        Game::Laser => DuckCall::RobotLaserTrack { active },
        Game::Soccer => DuckCall::RobotSoccer { active, autonomous: active },
        Game::Autonomous => DuckCall::RobotAutonomous { active },
    };
    if !on {
        return vec![switch(game, false)];
    }
    let mut calls: Vec<DuckCall> = ALL
        .into_iter()
        .filter(|g| *g != game && api_version >= since(*g))
        // 激光和踢球由机器人互斥，开其中一个时不必再关另一个。
        .filter(|g| !matches!((game, g), (Game::Laser, Game::Soccer) | (Game::Soccer, Game::Laser)))
        .map(|g| switch(g, false))
        .collect();
    calls.push(switch(game, true));
    calls
}

/// 走 `robot.state` 之外的哪条路：玩法开关和 `robot.mode` 在视频通道开着时优先走 `control`
/// （任何版本的 `mediad` 都转发），否则走蓝牙。
#[uniffi::export]
pub fn prefers_media(call: &DuckCall) -> bool {
    matches!(
        call,
        DuckCall::RobotLaserTrack { .. }
            | DuckCall::RobotSoccer { .. }
            | DuckCall::RobotAutonomous { .. }
            | DuckCall::RobotMode
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn availability_follows_versions_and_transport() {
        assert!(available_games(44, false).is_empty());
        assert!(available_games(66, false).is_empty());
        assert_eq!(available_games(66, true), ALL.to_vec());
        assert_eq!(available_games(58, true), vec![Game::Laser, Game::Soccer]);
        assert_eq!(available_games(67, false), ALL.to_vec());
    }

    #[test]
    fn one_game_at_a_time() {
        assert_eq!(
            game_calls(Game::Autonomous, true, 67),
            vec![
                DuckCall::RobotLaserTrack { active: false },
                DuckCall::RobotSoccer { active: false, autonomous: false },
                DuckCall::RobotAutonomous { active: true },
            ]
        );
        assert_eq!(
            game_calls(Game::Soccer, true, 67),
            vec![DuckCall::RobotAutonomous { active: false }, DuckCall::RobotSoccer { active: true, autonomous: true }]
        );
        // 没有自由活动的机器人不发它。
        assert_eq!(game_calls(Game::Laser, true, 58), vec![DuckCall::RobotLaserTrack { active: true }]);
        assert_eq!(game_calls(Game::Soccer, false, 67), vec![DuckCall::RobotSoccer { active: false, autonomous: false }]);
    }

    #[test]
    fn wire_shapes() {
        let codec = crate::link::RpcCodec::new();
        let v = |c: DuckCall| serde_json::from_str::<serde_json::Value>(&codec.encode(c).line).unwrap();
        let s = v(DuckCall::RobotSoccer { active: true, autonomous: true });
        assert_eq!(s["method"], proto::method::ROBOT_SOCCER);
        assert_eq!(s["params"], serde_json::json!({"active": true, "autonomous": true}));
        assert_eq!(v(DuckCall::RobotLaserTrack { active: false })["method"], proto::method::ROBOT_LASER_TRACK);
        assert_eq!(v(DuckCall::RobotAutonomous { active: true })["method"], proto::method::ROBOT_AUTONOMOUS);
    }

    #[test]
    fn decodes_robot_mode() {
        assert_eq!(decode_games(r#"{"mode":"walk"}"#).unwrap(), Games::default());
        let g = decode_games(r#"{"mode":"walk","soccer":{"active":true,"autonomous":true},"laser":true}"#).unwrap();
        assert!(g.soccer && g.laser && !g.autonomous);
        assert!(decode_games(r#"{"mode":"walk","autonomous":true}"#).unwrap().autonomous);
    }
}
