//! 状态页 3D 机器人：解析 `duck-web-mouth-v2.bin`（DHD2 格式，保留官方 MJCF 运动学树和原始三角面），
//! 由关节角 + 躯干姿态算出每个部件的世界矩阵，以及正交相机参数。
//!
//! 与本仓库 `tools/xl330-calibration/duck-view.js` 的算法逐行对应；平台层（Metal / GLES）只负责画。

use std::sync::Arc;

use crate::CoreError;

/// App 里的视窗：让模型尽量占满渲染区域（技术方案 3.4）。
pub const WINDOW_METRES: f32 = 0.29;
pub const LOOK_AT_Z: f32 = 0.135;
pub const DEFAULT_AZIMUTH: f32 = -0.7;
pub const DEFAULT_ELEVATION: f32 = 0.32;

#[derive(Clone, Copy)]
struct Pose {
    r: [[f32; 3]; 3],
    t: [f32; 3],
}

impl Pose {
    const IDENTITY: Self = Self { r: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]], t: [0.0; 3] };

    fn apply(&self, v: [f32; 3]) -> [f32; 3] {
        let r = &self.r;
        [
            r[0][0] * v[0] + r[0][1] * v[1] + r[0][2] * v[2] + self.t[0],
            r[1][0] * v[0] + r[1][1] * v[1] + r[1][2] * v[2] + self.t[1],
            r[2][0] * v[0] + r[2][1] * v[1] + r[2][2] * v[2] + self.t[2],
        ]
    }

    fn then(&self, local: &Pose) -> Pose {
        let mut r = [[0.0; 3]; 3];
        for (row, out) in r.iter_mut().enumerate() {
            for (col, cell) in out.iter_mut().enumerate() {
                *cell = (0..3).map(|k| self.r[row][k] * local.r[k][col]).sum();
            }
        }
        Pose { r, t: self.apply(local.t) }
    }

    fn quat(q: [f32; 4], t: [f32; 3]) -> Pose {
        let m = q.iter().map(|v| v * v).sum::<f32>().sqrt();
        if m < 1e-9 {
            return Pose { t, ..Self::IDENTITY };
        }
        let [w, x, y, z] = q.map(|v| v / m);
        Pose {
            r: [
                [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - w * z), 2.0 * (x * z + w * y)],
                [2.0 * (x * y + w * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - w * x)],
                [2.0 * (x * z - w * y), 2.0 * (y * z + w * x), 1.0 - 2.0 * (x * x + y * y)],
            ],
            t,
        }
    }

    fn axis(a: [f32; 3], angle: f32) -> Pose {
        let n = (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).sqrt();
        let [x, y, z] = if n < 1e-9 { [0.0; 3] } else { a.map(|v| v / n) };
        let (s, c) = angle.sin_cos();
        let i = 1.0 - c;
        Pose {
            r: [
                [c + x * x * i, x * y * i - z * s, x * z * i + y * s],
                [y * x * i + z * s, c + y * y * i, y * z * i - x * s],
                [z * x * i - y * s, z * y * i + x * s, c + z * z * i],
            ],
            t: [0.0; 3],
        }
    }

    /// 列主序 4×4（Metal / GLES 通用）。
    fn matrix(&self) -> [f32; 16] {
        let r = &self.r;
        [
            r[0][0], r[1][0], r[2][0], 0.0, r[0][1], r[1][1], r[2][1], 0.0, r[0][2], r[1][2], r[2][2], 0.0,
            self.t[0], self.t[1], self.t[2], 1.0,
        ]
    }
}

struct Mesh {
    vertices: Vec<f32>,
    indices: Vec<u32>,
    min: [f32; 3],
    max: [f32; 3],
}

struct Body {
    parent: i16,
    joint: i16,
    position: [f32; 3],
    quaternion: [f32; 4],
    axis: [f32; 3],
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct ModelPart {
    pub mesh: u16,
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

struct Part {
    body: u16,
    info: ModelPart,
    /// 材质角色（颜色第 4 字节），见 [`Role`]；0 表示未标注，用烘焙进模型的颜色。
    role: u8,
    pose: Pose,
}

/// 官方四种配色（pollen-robotics.com/microduck 的 Cream / Graphite / Lavender / Sky）。
/// 外壳颜色不同，机构件一样；同一只鸭子换配色不影响别的东西。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Colourway {
    Cream,
    Graphite,
    Lavender,
    Sky,
}

impl Colourway {
    pub const ALL: [Colourway; 4] = [Colourway::Cream, Colourway::Graphite, Colourway::Lavender, Colourway::Sky];

    /// 持久化用的稳定名字（与官网 VARIANT_LABELS 一致，小写）。
    pub fn key(self) -> &'static str {
        match self {
            Colourway::Cream => "cream",
            Colourway::Graphite => "graphite",
            Colourway::Lavender => "lavender",
            Colourway::Sky => "sky",
        }
    }
}

/// 官网色板上的色块（VARIANT_SWATCH_HEX），0xRRGGBB。
#[uniffi::export]
pub fn colourway_swatch(colourway: Colourway) -> u32 {
    match colourway {
        Colourway::Cream => 0xf7e6cb,
        Colourway::Graphite => 0x6c6a68,
        Colourway::Lavender => 0xbfa9cf,
        Colourway::Sky => 0xa9dbe8,
    }
}

#[uniffi::export]
pub fn colourway_all() -> Vec<Colourway> {
    Colourway::ALL.to_vec()
}

#[uniffi::export]
pub fn colourway_key(colourway: Colourway) -> String {
    colourway.key().into()
}

/// 未知或空的名字回落到默认的 Cream。
#[uniffi::export]
pub fn colourway_from_key(key: Option<String>) -> Colourway {
    Colourway::ALL.into_iter().find(|c| Some(c.key()) == key.as_deref()).unwrap_or(Colourway::Cream)
}

/// 材质角色，编号写在模型每个部件颜色的第 4 字节（由官网 `meshMaterialsFor` 按网格名映射而来）。
#[derive(Clone, Copy)]
#[repr(u8)]
enum Role {
    HeadDome = 1,
    FacePlate,
    Trim,
    BeakUpper,
    BeakLower,
    Tongue,
    EyeRing,
    Lens,
    BodyShell,
    SideShells,
    LegShells,
    Feet,
    Soles,
    Hips,
    MechDark,
    MechGray,
}

impl Role {
    fn from_u8(v: u8) -> Option<Role> {
        use Role::*;
        [HeadDome, FacePlate, Trim, BeakUpper, BeakLower, Tongue, EyeRing, Lens, BodyShell, SideShells, LegShells, Feet, Soles, Hips, MechDark, MechGray]
            .into_iter()
            .find(|r| *r as u8 == v)
    }
}

/// 官网 three.js 材质颜色（线性 RGB），逐字抄自其 VARIANTS 表。
fn linear_colour(colourway: Colourway, role: Role) -> [f32; 3] {
    use Colourway::*;
    use Role::*;
    const ORANGE: [f32; 3] = [0.93, 0.3, 0.002];
    const RED_ORANGE: [f32; 3] = [0.95, 0.15, 0.003];
    const YELLOW: [f32; 3] = [0.92, 0.6, 0.05];
    const CREAM: [f32; 3] = [0.95, 0.79, 0.58];
    const MECH_DARK: [f32; 3] = [0.012, 0.012, 0.014];
    const MECH_GRAY: [f32; 3] = [0.256, 0.256, 0.279];
    const LENS: [f32; 3] = [0.01, 0.012, 0.02];
    const FACE: [f32; 3] = [0.328, 0.312, 0.283];
    const CHARCOAL: [f32; 3] = [0.11, 0.11, 0.118];
    const PLUM: [f32; 3] = [0.36, 0.23, 0.48];
    const SKY: [f32; 3] = [0.32, 0.73, 0.86];
    const LAVENDER: [f32; 3] = [0.52, 0.38, 0.66];
    match (role, colourway) {
        (Lens, _) => LENS,
        (Hips | MechGray, _) => MECH_GRAY,
        (MechDark, _) => MECH_DARK,
        (HeadDome | BodyShell | SideShells | LegShells, Cream) => CREAM,
        (HeadDome, Graphite) => [0.15, 0.144, 0.14],
        (BodyShell | SideShells | LegShells, Graphite) => CHARCOAL,
        (HeadDome | BodyShell | SideShells | LegShells, Lavender) => LAVENDER,
        (HeadDome | BodyShell | SideShells | LegShells, Sky) => SKY,
        (FacePlate, Graphite) => [0.185, 0.178, 0.172],
        (FacePlate, _) => FACE,
        (Trim | BeakLower | Feet, Cream | Sky) => RED_ORANGE,
        (Trim | BeakLower | Feet, Graphite | Lavender) => YELLOW,
        (BeakUpper | Tongue, Cream | Sky) => ORANGE,
        (BeakUpper | Tongue, Graphite | Lavender) => PLUM,
        (EyeRing, Cream | Sky) => ORANGE,
        (EyeRing, Graphite) => [0.28, 0.15, 0.55],
        (EyeRing, Lavender) => SKY,
        (Soles, Cream | Sky) => YELLOW,
        (Soles, Graphite | Lavender) => PLUM,
    }
}

fn to_srgb(c: f32) -> f32 {
    if c <= 0.003_130_8 { 12.92 * c } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 }
}

#[derive(uniffi::Object)]
pub struct DuckModel {
    meshes: Vec<Mesh>,
    bodies: Vec<Body>,
    parts: Vec<Part>,
}

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn take(&mut self, n: usize) -> Result<&[u8], CoreError> {
        let end = self.at.checked_add(n).filter(|e| *e <= self.b.len()).ok_or_else(bad)?;
        let s = &self.b[self.at..end];
        self.at = end;
        Ok(s)
    }
    fn u16(&mut self) -> Result<u16, CoreError> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn i16(&mut self) -> Result<i16, CoreError> {
        Ok(i16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32, CoreError> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn f32(&mut self) -> Result<f32, CoreError> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn vec3(&mut self) -> Result<[f32; 3], CoreError> {
        Ok([self.f32()?, self.f32()?, self.f32()?])
    }
    fn quat(&mut self) -> Result<[f32; 4], CoreError> {
        Ok([self.f32()?, self.f32()?, self.f32()?, self.f32()?])
    }
}

fn bad() -> CoreError {
    CoreError::BadReply { detail: "model".into() }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ViewParams {
    pub right: Vec<f32>,
    pub up: Vec<f32>,
    pub forward: Vec<f32>,
    pub light: Vec<f32>,
    pub scale_x: f32,
    pub scale_y: f32,
    pub look_at: f32,
}



#[uniffi::export]
impl DuckModel {
    /// 解析模型二进制（App 包内资源，后台线程调用）。
    #[uniffi::constructor]
    pub fn load(bytes: Vec<u8>) -> Result<Arc<Self>, CoreError> {
        let mut r = Reader { b: &bytes, at: 0 };
        if r.take(4)? != b"DHD2" || r.u32()? != 2 {
            return Err(bad());
        }
        let (mesh_n, body_n, part_n) = (r.u16()?, r.u16()?, r.u16()?);
        r.u16()?;
        if mesh_n == 0 || mesh_n > 128 || body_n == 0 || body_n > 128 || part_n > 512 {
            return Err(bad());
        }
        let mut meshes = Vec::new();
        for _ in 0..mesh_n {
            let (vn, tn) = (r.u32()? as usize, r.u32()? as usize);
            if vn == 0 || vn > 200_000 || tn == 0 || tn > 300_000 {
                return Err(bad());
            }
            let vertices: Vec<f32> = r.take(vn * 12)?.chunks_exact(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())).collect();
            let indices: Vec<u32> = r.take(tn * 12)?.chunks_exact(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect();
            if indices.iter().any(|i| *i as usize >= vn) {
                return Err(bad());
            }
            let mut min = [f32::INFINITY; 3];
            let mut max = [f32::NEG_INFINITY; 3];
            for v in vertices.chunks_exact(3) {
                for a in 0..3 {
                    min[a] = min[a].min(v[a]);
                    max[a] = max[a].max(v[a]);
                }
            }
            meshes.push(Mesh { vertices, indices, min, max });
        }
        let mut bodies = Vec::new();
        for _ in 0..body_n {
            bodies.push(Body { parent: r.i16()?, joint: r.i16()?, position: r.vec3()?, quaternion: r.quat()?, axis: r.vec3()? });
        }
        let mut parts = Vec::new();
        for _ in 0..part_n {
            let body = r.u16()?;
            let mesh = r.u16()?;
            let c = r.take(4)?.to_vec();
            let (position, quaternion) = (r.vec3()?, r.quat()?);
            parts.push(Part {
                body,
                info: ModelPart { mesh, r: c[0] as f32 / 255.0, g: c[1] as f32 / 255.0, b: c[2] as f32 / 255.0 },
                role: c[3],
                pose: Pose::quat(quaternion, position),
            });
        }
        let valid = bodies.iter().enumerate().all(|(i, b)| (b.parent as isize) < i as isize && b.joint < 15)
            && parts.iter().all(|p| (p.body as usize) < bodies.len() && (p.info.mesh as usize) < meshes.len());
        if !valid || r.at != bytes.len() {
            return Err(bad());
        }
        Ok(Arc::new(Self { meshes, bodies, parts }))
    }

    pub fn mesh_count(&self) -> u32 {
        self.meshes.len() as u32
    }

    /// 顶点（xyz 交错，米）。
    pub fn mesh_vertices(&self, mesh: u32) -> Vec<f32> {
        self.meshes.get(mesh as usize).map(|m| m.vertices.clone()).unwrap_or_default()
    }

    pub fn mesh_indices(&self, mesh: u32) -> Vec<u32> {
        self.meshes.get(mesh as usize).map(|m| m.indices.clone()).unwrap_or_default()
    }

    pub fn parts(&self) -> Vec<ModelPart> {
        self.parts.iter().map(|p| p.info).collect()
    }

    /// 每个部件在该配色下的显示颜色（sRGB 0–1，rgb 三个一组，按 [`Self::parts`] 顺序）。
    /// 未标注角色的部件用模型里烘焙的颜色。
    pub fn part_colours(&self, colourway: Colourway) -> Vec<f32> {
        self.parts
            .iter()
            .flat_map(|p| match Role::from_u8(p.role) {
                Some(role) => linear_colour(colourway, role).map(to_srgb),
                None => [p.info.r, p.info.g, p.info.b],
            })
            .collect()
    }

    /// 每个部件的列主序 4×4 世界矩阵（16 个一组，按 [`Self::parts`] 顺序）。
    /// `quat` 为躯干姿态（标量在前），根节点乘以它，躺倒、后仰才能正确显示；整体落地（最低点 z = 0）。
    pub fn part_matrices(&self, joints: Vec<f64>, quat: Option<Vec<f64>>) -> Vec<f32> {
        let root = quat
            .filter(|q| q.len() == 4)
            .map(|q| Pose::quat([q[0] as f32, q[1] as f32, q[2] as f32, q[3] as f32], [0.0; 3]))
            .unwrap_or(Pose::IDENTITY);
        let mut poses: Vec<Pose> = Vec::with_capacity(self.bodies.len());
        for b in &self.bodies {
            let parent = if b.parent < 0 { root } else { poses[b.parent as usize] };
            let mut pose = parent.then(&Pose::quat(b.quaternion, b.position));
            if b.joint >= 0 {
                let angle = joints.get(b.joint as usize).copied().unwrap_or(0.0) as f32;
                pose = pose.then(&Pose::axis(b.axis, angle));
            }
            poses.push(pose);
        }
        let part_poses: Vec<Pose> = self.parts.iter().map(|p| poses[p.body as usize].then(&p.pose)).collect();
        let floor = part_poses
            .iter()
            .zip(&self.parts)
            .map(|(pose, p)| {
                let m = &self.meshes[p.info.mesh as usize];
                let mut lowest = f32::INFINITY;
                for x in [m.min[0], m.max[0]] {
                    for y in [m.min[1], m.max[1]] {
                        for z in [m.min[2], m.max[2]] {
                            lowest = lowest.min(pose.apply([x, y, z])[2]);
                        }
                    }
                }
                lowest
            })
            .fold(f32::INFINITY, f32::min);
        let floor = if floor.is_finite() { floor } else { 0.0 };
        part_poses
            .iter()
            .flat_map(|p| {
                let mut m = p.matrix();
                m[14] -= floor;
                m
            })
            .collect()
    }
}

/// 正交相机（与 duck-view 相同）：方位角、仰角（弧度）、视口像素。
#[uniffi::export]
pub fn view_params(azimuth: f32, elevation: f32, width: f32, height: f32) -> ViewParams {
    let (sa, ca) = azimuth.sin_cos();
    let (se, ce) = elevation.sin_cos();
    let forward = [-ce * ca, -ce * sa, -se];
    let norm = |v: [f32; 3]| {
        let n = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
        if n < 1e-9 { [0.0; 3] } else { v.map(|x| x / n) }
    };
    let cross = |a: [f32; 3], b: [f32; 3]| [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
    let right = norm(cross(forward, [0.0, 0.0, 1.0]));
    let up = cross(right, forward);
    let light = norm([0, 1, 2].map(|i| 0.35 * right[i] + 0.72 * up[i] - 0.62 * forward[i]));
    let px = (width / WINDOW_METRES).min(height / WINDOW_METRES);
    ViewParams {
        right: right.to_vec(),
        up: up.to_vec(),
        forward: forward.to_vec(),
        light: light.to_vec(),
        scale_x: 2.0 * px / width.max(1.0),
        scale_y: 2.0 * px / height.max(1.0),
        look_at: LOOK_AT_Z * up[2],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_the_bundled_model() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../shared/models/duck-web-mouth-v2.bin");
        let Ok(bytes) = std::fs::read(path) else { return };
        let model = DuckModel::load(bytes).unwrap();
        let n = model.parts().len();
        assert!(n > 0);
        let m = model.part_matrices(vec![0.0; 15], Some(vec![1.0, 0.0, 0.0, 0.0]));
        assert_eq!(m.len(), n * 16);
        assert!(m.iter().all(|v| v.is_finite()));
        // 每个部件都标了官方材质角色，四种配色都给出颜色。
        assert!(model.parts.iter().all(|p| Role::from_u8(p.role).is_some()));
        for c in Colourway::ALL {
            let colours = model.part_colours(c);
            assert_eq!(colours.len(), n * 3);
            assert!(colours.iter().all(|v| (0.0..=1.0).contains(v)));
        }
    }

    #[test]
    fn colourway_matches_the_official_swatch() {
        // 头壳颜色换算到 sRGB 后应接近官网色块。
        for c in Colourway::ALL {
            let head = linear_colour(c, Role::HeadDome).map(|v| (to_srgb(v) * 255.0).round() as i32);
            let s = colourway_swatch(c);
            let swatch = [(s >> 16) as i32 & 0xff, (s >> 8) as i32 & 0xff, s as i32 & 0xff];
            let off = head.iter().zip(swatch).map(|(a, b)| (a - b).abs()).max().unwrap();
            assert!(off <= 40, "{c:?}: head {head:?} vs swatch {swatch:?}");
        }
        assert_eq!(colourway_from_key(Some("sky".into())), Colourway::Sky);
        assert_eq!(colourway_from_key(None), Colourway::Cream);
        assert_eq!(colourway_from_key(Some("nope".into())), Colourway::Cream);
    }
}
