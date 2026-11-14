//! `robot.state` 流 → 界面需要的数据，以及站姿判定。
//!
//! 站姿判定逻辑与官方 `robotd/src/posture.rs` 一致（阈值、运动学模型都相同）。`robotd` 是守护进程
//! 二进制，无法作为库引入手机，所以这里调用同一个 `kinematics` crate 重做这 20 行；
//! 测试用的是官方 posture.rs 里的同一组样本。

use duck_ipc_proto as proto;
use kinematics::Quat;

pub const LYING_TILT_DEG: f64 = 45.0;
pub const SEATED_BELOW: f64 = 0.5;
pub const STANDING_ABOVE: f64 = 0.8;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Posture {
    Standing,
    Seated,
    Lying,
    Unsure,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct PostureReading {
    pub posture: Posture,
    /// 躯干离脚高度 / 模型站立高度。
    pub height_ratio: f64,
    /// 躯干向上方向与世界向上方向的夹角（度）。
    pub tilt_deg: f64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DuckState {
    pub t: f64,
    /// 实测关节角（弧度，`JOINT_NAMES` 顺序）。
    pub joints: Vec<f64>,
    /// 指令关节角。
    pub targets: Vec<f64>,
    /// 躯干姿态四元数（标量在前），未读到 IMU 时为 `None`。
    pub quat: Option<Vec<f64>>,
    /// 哪个策略在驱动：`walk`、`stand` 或 `held`。
    pub policy: String,
    pub fallen: bool,
    pub limp: bool,
    pub picked_up: bool,
    /// 头部 `[neck_pitch, head_pitch, head_yaw, head_roll]`。
    pub head: Vec<f64>,
    /// 实际执行的 `[vx, vy, vyaw]`。
    pub applied: Vec<f64>,
    pub posture: Option<PostureReading>,
}

impl DuckState {
    pub fn from_proto(s: &proto::RobotState) -> Self {
        let quat = s.imu.as_ref().map(|i| i.quat);
        let posture = quat.filter(|_| s.joints.len() == proto::JOINT_NAMES.len()).map(|q| classify(&s.joints, q));
        Self {
            t: s.t,
            joints: s.joints.clone(),
            targets: s.targets.clone(),
            quat: quat.map(|q| q.to_vec()),
            policy: s.policy.clone(),
            fallen: s.safety.fallen,
            limp: s.safety.limp,
            picked_up: s.safety.picked_up,
            head: s.head.to_vec(),
            applied: s.movement.applied.to_vec(),
            posture,
        }
    }
}

/// 策略是否在驱动，从 `robot.state` 的 `policy` 读（真机 0.17.8 实测的取值）：
/// `walk` / `stand` 是行走 / 站立策略；`sit` / `rise` 是驱动中的坐下锁定与起身；`held` 是没有策略在跑。
/// `homing`、`rest`、`limp_fall` / `limp_pose`（摔倒保护）以及技能等其他取值是过渡态，返回 `None`。
pub fn policy_driving(policy: &str) -> Option<bool> {
    match policy {
        "walk" | "stand" | "sit" | "rise" => Some(true),
        "held" => Some(false),
        _ => None,
    }
}

/// App 的"电源"状态（是否已启动）只是本地记的，机器人重启、被手柄或别的设备操作后会对不上。
/// 这里用状态流校正：同一判定持续 [`DRIVING_SETTLE_S`] 秒、且与 App 的认识不同，才报告一次。
/// 刚按下启动、机器人还没反应的那半秒不会误报。
#[derive(uniffi::Object)]
pub struct DrivingTracker {
    inner: std::sync::Mutex<Option<(bool, f64)>>,
}

/// 判定需要稳定多久才算数（秒，按机器人时钟 `DuckState::t`）。
pub const DRIVING_SETTLE_S: f64 = 1.0;

#[uniffi::export]
impl DrivingTracker {
    #[uniffi::constructor]
    pub fn new() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self { inner: std::sync::Mutex::new(None) })
    }

    /// 喂一帧状态。返回 `Some(驱动中)` 表示 App 应改成这个认识；`None` 表示不用动。
    pub fn observe(&self, policy: String, t: f64, app_driving: bool) -> Option<bool> {
        let mut cand = self.inner.lock().unwrap();
        let Some(driving) = policy_driving(&policy) else {
            *cand = None;
            return None;
        };
        match *cand {
            // 时钟倒退（机器人重启）也重新计时
            Some((d, since)) if d == driving && t >= since => {
                (driving != app_driving && t - since >= DRIVING_SETTLE_S).then_some(driving)
            }
            _ => {
                *cand = Some((driving, t));
                None
            }
        }
    }
}

/// 与官方 posture.rs 相同的判定。
pub fn classify(positions: &[f64], quat: [f64; 4]) -> PostureReading {
    let model = kinematics::Model::alpha();
    let angles: Vec<f64> = model
        .joint_names()
        .map(|name| {
            proto::JOINT_NAMES
                .iter()
                .position(|wire| *wire == name)
                .and_then(|i| positions.get(i).copied())
                .unwrap_or(0.0)
        })
        .collect();
    let foot = |name: &str| model.site(name).map_or([0.0; 3], |site| model.site_pose(site, &angles).pos);
    let (left, right) = (foot("left_foot"), foot("right_foot"));
    let feet = [(left[0] + right[0]) / 2.0, (left[1] + right[1]) / 2.0, (left[2] + right[2]) / 2.0];
    let [w, x, y, z] = quat;
    let attitude = Quat::new(w, x, y, z).normalized();
    let height = -attitude.rotate(feet)[2];
    let up = attitude.rotate([0.0, 0.0, 1.0]);
    let tilt_deg = up[2].clamp(-1.0, 1.0).acos().to_degrees();
    let height_ratio = height / model.trunk_height_m();
    let posture = if tilt_deg > LYING_TILT_DEG {
        Posture::Lying
    } else if height_ratio < SEATED_BELOW {
        Posture::Seated
    } else if height_ratio > STANDING_ABOVE {
        Posture::Standing
    } else {
        Posture::Unsure
    };
    PostureReading { posture, height_ratio, tilt_deg }
}

/// 平台层直接调用的版本（状态页离线预览、测试）。
#[uniffi::export]
pub fn classify_posture(joints: Vec<f64>, quat: Vec<f64>) -> Option<PostureReading> {
    let q: [f64; 4] = quat.try_into().ok()?;
    (joints.len() == proto::JOINT_NAMES.len()).then(|| classify(&joints, q))
}

#[cfg(test)]
mod tests {
    use super::*;

    // 官方 posture.rs 中的样本。
    const LYING: ([f64; 15], [f64; 4]) = (
        [
            0.0951, -0.4418, -0.4525, -0.0476, 0.4541, 0.1058, -0.7440, 0.3942, 0.0936, 0.0015, -0.0583, 0.1381,
            0.3712, -0.3651, -0.4633,
        ],
        [0.1588, 0.6902, -0.2091, 0.6742],
    );
    const SEATED_HIPS: ([f64; 15], [f64; 4]) = (
        [
            -0.0644, 0.5783, -1.5524, 0.2086, 0.4571, 1.0017, 1.4788, -0.0261, -0.0491, 0.0031, -0.2761, -0.4479,
            1.0677, -0.8207, -0.6811,
        ],
        [0.7972, 0.0264, -0.0984, 0.5951],
    );

    #[test]
    fn official_samples() {
        assert_eq!(classify(&LYING.0, LYING.1).posture, Posture::Lying);
        let seated = classify(&SEATED_HIPS.0, SEATED_HIPS.1);
        assert!(seated.tilt_deg < LYING_TILT_DEG);
        assert_ne!(seated.posture, Posture::Standing);
    }

    #[test]
    fn upright_zero_pose_is_tall() {
        let r = classify(&[0.0; 15], [1.0, 0.0, 0.0, 0.0]);
        assert!(r.tilt_deg < 1.0);
        assert!(r.height_ratio > SEATED_BELOW, "{r:?}");
    }

    #[test]
    fn driving_tracker_waits_for_a_stable_state() {
        let tr = DrivingTracker::new();
        // App 以为在走，机器人重启后一直是 held：1 s 后报告"没在驱动"
        assert_eq!(tr.observe("held".into(), 10.0, true), None);
        assert_eq!(tr.observe("held".into(), 10.5, true), None);
        assert_eq!(tr.observe("held".into(), 11.1, true), Some(false));
        // App 已改正，不再报告
        assert_eq!(tr.observe("held".into(), 12.0, false), None);
        // 刚按启动：held 不满 1 s 就进 homing（过渡态），不误报
        let tr = DrivingTracker::new();
        assert_eq!(tr.observe("held".into(), 0.0, true), None);
        assert_eq!(tr.observe("homing".into(), 0.4, true), None);
        assert_eq!(tr.observe("held".into(), 0.6, true), None);
        assert_eq!(tr.observe("held".into(), 1.2, true), None);
        // 别处启动了它：walk 稳定后报告"在驱动"
        let tr = DrivingTracker::new();
        tr.observe("walk".into(), 5.0, false);
        assert_eq!(tr.observe("walk".into(), 6.0, false), Some(true));
        // 时钟倒退重新计时
        let tr = DrivingTracker::new();
        tr.observe("held".into(), 100.0, true);
        assert_eq!(tr.observe("held".into(), 0.5, true), None);
        assert_eq!(tr.observe("held".into(), 1.6, true), Some(false));
        assert_eq!(policy_driving("limp_fall"), None);
        assert_eq!(policy_driving("sit"), Some(true));
    }
}
