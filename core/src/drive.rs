//! 驾驶页的纯计算：摇杆映射、读数、偏差着色、电量。两端共用，保证手感一致。

use crate::calls::DuckCall;

pub const DEADZONE: f64 = 0.08;
pub const MAX_VX: f64 = 0.3;
pub const MAX_VY: f64 = 0.3;
pub const MAX_VYAW: f64 = 1.5;
pub const HEAD_YAW_MAX: f64 = 60.0 * std::f64::consts::PI / 180.0;
pub const HEAD_PITCH_MAX: f64 = 30.0 * std::f64::consts::PI / 180.0;
pub const HEAD_ROLL_MAX: f64 = 25.0 * std::f64::consts::PI / 180.0;
pub const BATTERY_EMPTY_V: f64 = 6.6;
pub const BATTERY_FULL_V: f64 = 8.2;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StickMode {
    /// 左摇杆移动、右摇杆转向。
    Walk,
    /// 左摇杆转头 / 点头、右摇杆歪头。
    Head,
    /// 左摇杆前进转弯、右摇杆看。
    WalkLook,
    /// 左摇杆高低 / 侧倾、右摇杆看。
    Height,
}

/// 摇杆位置：x 向右、y 向下（屏幕坐标），范围 [-1, 1]。
#[derive(Debug, Clone, Copy, PartialEq, Default, uniffi::Record)]
pub struct Stick {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DriveOutput {
    /// 要发到 `teleop` 通道的调用（0–2 个）。
    pub calls: Vec<DuckCall>,
    /// 视频底部读数左、右两段，如 `0.21 m/s`、`0.80 rad/s`。
    pub readout_primary: String,
    pub readout_secondary: String,
    /// 准星位置（-1..1），随头部朝向移动。
    pub reticle_x: f64,
    pub reticle_y: f64,
}

fn dz(v: f64) -> f64 {
    let v = v.clamp(-1.0, 1.0);
    if v.abs() < DEADZONE { 0.0 } else { v.signum() * (v.abs() - DEADZONE) / (1.0 - DEADZONE) }
}

fn head(yaw: f64, pitch: f64, roll: f64) -> DuckCall {
    DuckCall::RobotHead { neck_pitch: 0.0, head_pitch: pitch, head_yaw: yaw, head_roll: roll }
}

/// 摇杆 → 调用。松手（两个摇杆都在死区内）时，移动类模式发零速。
/// `roller` 时使用轮子预设：无平移，后退限幅为前进的一半。
#[uniffi::export]
pub fn map_sticks(mode: StickMode, left: Stick, right: Stick, roller: bool) -> DriveOutput {
    let (lx, ly, rx, ry) = (dz(left.x), dz(left.y), dz(right.x), dz(right.y));
    let deg = |r: f64| r.to_degrees();
    let mut vx = -ly * MAX_VX;
    if roller && vx < 0.0 {
        vx *= 0.5;
    }
    match mode {
        StickMode::Walk => {
            let vy = if roller { 0.0 } else { -lx * MAX_VY };
            let vyaw = -rx * MAX_VYAW;
            DriveOutput {
                calls: vec![DuckCall::RobotMove { vx, vy, vyaw }],
                readout_primary: format!("{:.2} m/s", (vx * vx + vy * vy).sqrt()),
                readout_secondary: format!("{vyaw:.2} rad/s"),
                reticle_x: 0.0,
                reticle_y: 0.0,
            }
        }
        StickMode::Head => {
            let (yaw, pitch, roll) = (-lx * HEAD_YAW_MAX, ly * HEAD_PITCH_MAX, rx * HEAD_ROLL_MAX);
            DriveOutput {
                calls: vec![head(yaw, pitch, roll)],
                readout_primary: format!("{:.0}°", deg(yaw)),
                readout_secondary: format!("{:.0}°", deg(pitch)),
                reticle_x: lx,
                reticle_y: ly,
            }
        }
        StickMode::WalkLook => {
            let vyaw = -lx * MAX_VYAW;
            let (yaw, pitch) = (-rx * HEAD_YAW_MAX, ry * HEAD_PITCH_MAX);
            DriveOutput {
                calls: vec![DuckCall::RobotMove { vx, vy: 0.0, vyaw }, head(yaw, pitch, 0.0)],
                readout_primary: format!("{vx:.2} m/s"),
                readout_secondary: format!("{:.0}°", deg(yaw)),
                reticle_x: rx,
                reticle_y: ry,
            }
        }
        StickMode::Height => {
            // 机身高度 / 侧倾接口待官方确认（技术方案 §8.1），此处只发头部朝向，读数照常显示。
            let height = (1.0 - ly) / 2.0;
            let roll = lx * HEAD_ROLL_MAX;
            let (yaw, pitch) = (-rx * HEAD_YAW_MAX, ry * HEAD_PITCH_MAX);
            DriveOutput {
                calls: vec![head(yaw, pitch, 0.0)],
                readout_primary: format!("{:.0}%", height * 100.0),
                readout_secondary: format!("{:.0}°", deg(roll)),
                reticle_x: rx,
                reticle_y: ry,
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DeviationLevel {
    /// < 1°
    Fine,
    /// 1–3°
    Warn,
    /// > 3°
    Bad,
}

/// 关节跟踪偏差着色（状态页 S-4）。
#[uniffi::export]
pub fn deviation_level(measured_rad: f64, commanded_rad: f64) -> DeviationLevel {
    let d = (measured_rad - commanded_rad).to_degrees().abs();
    if d < 1.0 {
        DeviationLevel::Fine
    } else if d <= 3.0 {
        DeviationLevel::Warn
    } else {
        DeviationLevel::Bad
    }
}

/// 机器人没给百分比时，按 2S 直供 6.6–8.2 V 换算（0..1）。低于 6.6 V 为空。
#[uniffi::export]
pub fn battery_fraction(volts: f64) -> f64 {
    ((volts - BATTERY_EMPTY_V) / (BATTERY_FULL_V - BATTERY_EMPTY_V)).clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deadzone_and_release() {
        let out = map_sticks(StickMode::Walk, Stick { x: 0.05, y: -0.05 }, Stick::default(), false);
        assert_eq!(out.calls, vec![DuckCall::RobotMove { vx: 0.0, vy: 0.0, vyaw: 0.0 }]);
        let out = map_sticks(StickMode::Walk, Stick { x: 0.0, y: -1.0 }, Stick { x: 1.0, y: 0.0 }, false);
        assert_eq!(out.calls, vec![DuckCall::RobotMove { vx: MAX_VX, vy: 0.0, vyaw: -MAX_VYAW }]);
    }

    #[test]
    fn roller_has_no_strafe_and_soft_reverse() {
        let out = map_sticks(StickMode::Walk, Stick { x: 1.0, y: 1.0 }, Stick::default(), true);
        assert_eq!(out.calls, vec![DuckCall::RobotMove { vx: -MAX_VX * 0.5, vy: 0.0, vyaw: 0.0 }]);
    }

    #[test]
    fn deviation_thresholds() {
        assert_eq!(deviation_level(0.0, 0.5f64.to_radians()), DeviationLevel::Fine);
        assert_eq!(deviation_level(0.0, 2f64.to_radians()), DeviationLevel::Warn);
        assert_eq!(deviation_level(0.0, 4f64.to_radians()), DeviationLevel::Bad);
        assert_eq!(battery_fraction(6.0), 0.0);
        assert!((battery_fraction(7.9) - 0.8125).abs() < 1e-9);
    }
}
