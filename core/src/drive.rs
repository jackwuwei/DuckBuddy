//! 驾驶页的纯计算：摇杆映射、读数、偏差着色、电量。两端共用，保证手感一致。

use crate::calls::DuckCall;

// 与机器人 `padd`（蓝牙手柄）一致：robotd-params 的 `[pad_axes] deadzone` 与 `[pad_drive]` /
// `[pad_roller]` 默认值。死区内归零、死区外不重新缩放（官方 `AxisBinding::evaluate`）。
pub const DEADZONE: f64 = 0.1;
pub const MAX_VX: f64 = 0.4;
pub const MIN_VX: f64 = -0.4;
pub const MAX_VY: f64 = 0.3;
pub const MAX_VYAW: f64 = 1.0;
pub const ROLLER_MAX_VX: f64 = 0.6;
pub const ROLLER_MIN_VX: f64 = -0.5;
pub const ROLLER_MAX_VYAW: f64 = 0.3;
/// robotd 按 |(vx, vy, vyaw)| ≤ 0.05（平滑后）每拍在站立网络和行走网络之间切换，增益和动作
/// 幅度也随之切换。手指在小幅度上抖动会让指令在 0.05 附近来回穿越，两个网络来回切换就会摔倒。
/// 所以 App 发出的速度要么是 0，要么模长不小于 `WALK_ENTER`；正在走时，降到 `WALK_EXIT`
/// 以下才停，中间抬到 `WALK_ENTER`。
pub const WALK_ENTER: f64 = 0.08;
pub const WALK_EXIT: f64 = 0.03;
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
    /// 本次是否发出了非零速度；下一拍作为 `was_moving` 传回。
    pub moving: bool,
}

fn dz(v: f64) -> f64 {
    let v = v.clamp(-1.0, 1.0);
    if !v.is_finite() || v.abs() < DEADZONE { 0.0 } else { v }
}

/// 官方 `PadDriveParams::scale`：正向乘 max，负向乘 |min|。
fn scale(d: f64, min: f64, max: f64) -> f64 {
    if d >= 0.0 { d * max } else { -d * min }
}

/// 避开 robotd 站立 / 行走切换阈值附近（见 [`WALK_ENTER`]）。
fn shape(twist: [f64; 3], was_moving: bool) -> [f64; 3] {
    let m = twist.iter().map(|v| v * v).sum::<f64>().sqrt();
    let floor = if was_moving { WALK_EXIT } else { WALK_ENTER };
    if m < floor {
        [0.0; 3]
    } else if m < WALK_ENTER {
        twist.map(|v| v * WALK_ENTER / m)
    } else {
        twist
    }
}

fn head(yaw: f64, pitch: f64, roll: f64) -> DuckCall {
    DuckCall::RobotHead { neck_pitch: 0.0, head_pitch: pitch, head_yaw: yaw, head_roll: roll }
}

/// 摇杆 → 调用，映射与 `padd` 的 drive / head_drive 相同。松手（两个摇杆都在死区内）时，
/// 移动类模式发零速。`roller` 时使用官方轮子预设（`[pad_roller]`）：无平移。
/// `was_moving` 是上一拍的 [`DriveOutput::moving`]。
#[uniffi::export]
pub fn map_sticks(mode: StickMode, left: Stick, right: Stick, roller: bool, was_moving: bool) -> DriveOutput {
    let (lx, ly, rx, ry) = (dz(left.x), dz(left.y), dz(right.x), dz(right.y));
    let deg = |r: f64| r.to_degrees();
    // 屏幕 y 向下，手柄 y 向上：前推是 -y。
    let vx = if roller { scale(-ly, ROLLER_MIN_VX, ROLLER_MAX_VX) } else { scale(-ly, MIN_VX, MAX_VX) };
    let max_vyaw = if roller { ROLLER_MAX_VYAW } else { MAX_VYAW };
    match mode {
        StickMode::Walk => {
            let vy = if roller { 0.0 } else { -lx * MAX_VY };
            let [vx, vy, vyaw] = shape([vx, vy, -rx * max_vyaw], was_moving);
            DriveOutput {
                calls: vec![DuckCall::RobotMove { vx, vy, vyaw }],
                readout_primary: format!("{:.2} m/s", (vx * vx + vy * vy).sqrt()),
                readout_secondary: format!("{vyaw:.2} rad/s"),
                reticle_x: 0.0,
                reticle_y: 0.0,
                moving: vx != 0.0 || vy != 0.0 || vyaw != 0.0,
            }
        }
        StickMode::Head => {
            let (yaw, pitch, roll) = (-lx * HEAD_YAW_MAX, ly * HEAD_PITCH_MAX, rx * HEAD_ROLL_MAX);
            DriveOutput {
                // 与 padd 的头部模式一样，同一帧里显式发零速，身体不带着上一次的速度走。
                calls: vec![DuckCall::RobotMove { vx: 0.0, vy: 0.0, vyaw: 0.0 }, head(yaw, pitch, roll)],
                readout_primary: format!("{:.0}°", deg(yaw)),
                readout_secondary: format!("{:.0}°", deg(pitch)),
                reticle_x: lx,
                reticle_y: ly,
                moving: false,
            }
        }
        StickMode::WalkLook => {
            let [vx, _, vyaw] = shape([vx, 0.0, -lx * max_vyaw], was_moving);
            let (yaw, pitch) = (-rx * HEAD_YAW_MAX, ry * HEAD_PITCH_MAX);
            DriveOutput {
                calls: vec![DuckCall::RobotMove { vx, vy: 0.0, vyaw }, head(yaw, pitch, 0.0)],
                readout_primary: format!("{vx:.2} m/s"),
                readout_secondary: format!("{:.0}°", deg(yaw)),
                reticle_x: rx,
                reticle_y: ry,
                moving: vx != 0.0 || vyaw != 0.0,
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
                moving: false,
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

    fn walk(l: (f64, f64), r: (f64, f64), was_moving: bool) -> (f64, f64, f64) {
        let out = map_sticks(StickMode::Walk, Stick { x: l.0, y: l.1 }, Stick { x: r.0, y: r.1 }, false, was_moving);
        match out.calls[..] {
            [DuckCall::RobotMove { vx, vy, vyaw }] => (vx, vy, vyaw),
            _ => panic!("{:?}", out.calls),
        }
    }

    #[test]
    fn deadzone_and_release() {
        assert_eq!(walk((0.09, -0.09), (0.0, 0.0), true), (0.0, 0.0, 0.0));
        assert_eq!(walk((0.0, -1.0), (1.0, 0.0), false), (MAX_VX, 0.0, -MAX_VYAW));
    }

    /// 与 padd 默认值逐项一致：前后 ±0.4、平移 ±0.3、转向 ±1.0，死区外不重新缩放。
    #[test]
    fn matches_the_gamepad() {
        assert_eq!(walk((0.0, 1.0), (0.0, 0.0), false), (-0.4, 0.0, 0.0), "full back");
        assert_eq!(walk((1.0, 0.0), (0.0, 0.0), false), (0.0, -0.3, 0.0), "full right strafes right");
        assert_eq!(walk((0.0, 0.0), (-1.0, 0.0), false), (0.0, 0.0, 1.0), "right stick left turns left");
        let (vx, _, _) = walk((0.0, 0.5), (0.0, 0.0), false);
        assert!((vx + 0.2).abs() < 1e-12, "half back is -0.2, not rescaled: {vx}");
    }

    /// 发出的速度模长要么是 0，要么不小于 WALK_ENTER，避开 robotd 的 0.05 切换阈值。
    #[test]
    fn never_hovers_at_the_stand_walk_threshold() {
        let mag = |(a, b, c): (f64, f64, f64)| (a * a + b * b + c * c).sqrt();
        // 起步：deflection 0.12 → vx 0.048，低于进入阈值，不走。
        assert_eq!(walk((0.0, -0.12), (0.0, 0.0), false), (0.0, 0.0, 0.0));
        // 走着时同样的小幅度被抬到 WALK_ENTER，方向不变。
        let t = walk((0.0, -0.12), (0.0, 0.0), true);
        assert!((mag(t) - WALK_ENTER).abs() < 1e-12 && t.0 > 0.0, "{t:?}");
        for i in 0..=400 {
            let d = i as f64 / 400.0;
            for was in [false, true] {
                for t in [walk((0.0, d), (0.0, 0.0), was), walk((d, 0.0), (0.0, 0.0), was), walk((0.0, 0.0), (d, 0.0), was)] {
                    let m = mag(t);
                    assert!(m == 0.0 || m >= WALK_ENTER - 1e-12, "d={d} was={was} {t:?}");
                }
            }
        }
    }

    #[test]
    fn roller_uses_the_official_preset() {
        let out = map_sticks(StickMode::Walk, Stick { x: 1.0, y: 1.0 }, Stick { x: 1.0, y: 0.0 }, true, false);
        assert_eq!(out.calls, vec![DuckCall::RobotMove { vx: ROLLER_MIN_VX, vy: 0.0, vyaw: -ROLLER_MAX_VYAW }]);
    }

    #[test]
    fn head_mode_holds_the_body_still() {
        let out = map_sticks(StickMode::Head, Stick { x: 1.0, y: 0.0 }, Stick::default(), false, true);
        assert_eq!(out.calls[0], DuckCall::RobotMove { vx: 0.0, vy: 0.0, vyaw: 0.0 });
        assert!(!out.moving);
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
