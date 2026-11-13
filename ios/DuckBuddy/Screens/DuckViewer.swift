import MetalKit
import SwiftUI

/// 状态页 3D 机器人（Metal）。模型解析与正向运动学在 duck-core（`DuckModel`），这里只画：
/// 正交相机、按屏幕导数求面法线的平直着色，与设计稿 / duck-view.js 的 WebGL 着色器一致。
struct DuckViewer: UIViewRepresentable {
    var joints: [Double]
    var quat: [Double]?
    @Binding var resetToken: Int
    var onState: (Renderer.LoadState) -> Void

    func makeCoordinator() -> Renderer { Renderer(onState: onState) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Renderer.pan(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Renderer.reset))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let r = context.coordinator
        if r.resetToken != resetToken { r.resetToken = resetToken; r.reset() }
        r.update(joints: joints, quat: quat)
    }

    @MainActor
    final class Renderer: NSObject, MTKViewDelegate {
        enum LoadState { case loading, ready, failed }

        var resetToken = 0
        private let onState: (LoadState) -> Void
        private weak var view: MTKView?
        private var pipeline: MTLRenderPipelineState?
        private var depth: MTLDepthStencilState?
        private var meshes: [(MTLBuffer, MTLBuffer, Int)] = []
        private var parts: [ModelPart] = []
        private var model: DuckModel?
        private var grid: (MTLBuffer, Int)?
        private var matrices: [Float] = []
        private var azimuth: Float = -0.7, elevation: Float = 0.32
        private var lastFrame = Date.distantPast
        private var pending = false

        private let defaultAzimuth: Float = -0.7
        private let defaultElevation: Float = 0.32

        init(onState: @escaping (LoadState) -> Void) { self.onState = onState }

        func attach(_ view: MTKView) {
            self.view = view
            guard let device = view.device else { onState(.failed); return }
            do {
                let lib = try device.makeLibrary(source: Self.shader, options: nil)
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = lib.makeFunction(name: "vtx")
                desc.fragmentFunction = lib.makeFunction(name: "frag")
                desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
                desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
                let vd = MTLVertexDescriptor()
                vd.attributes[0].format = .float3
                vd.attributes[0].offset = 0
                vd.attributes[0].bufferIndex = 0
                vd.layouts[0].stride = 12
                desc.vertexDescriptor = vd
                pipeline = try device.makeRenderPipelineState(descriptor: desc)
                let dd = MTLDepthStencilDescriptor()
                dd.depthCompareFunction = .less
                dd.isDepthWriteEnabled = true
                depth = device.makeDepthStencilState(descriptor: dd)
            } catch {
                onState(.failed); return
            }
            var lines: [Float] = []
            let reach: Float = 0.30, step: Float = 0.05
            var v = -reach
            while v <= reach + 1e-4 {
                lines += [v, -reach, 0, v, reach, 0, -reach, v, 0, reach, v, 0]
                v += step
            }
            grid = (device.makeBuffer(bytes: lines, length: lines.count * 4)!, lines.count / 3)
            onState(.loading)
            Task.detached(priority: .userInitiated) {
                guard let url = Bundle.main.url(forResource: "duck-web-mouth-v2", withExtension: "bin"),
                      let data = try? Data(contentsOf: url),
                      let model = try? DuckModel.load(bytes: data) else {
                    await MainActor.run { self.onState(.failed) }
                    return
                }
                let count = model.meshCount()
                var raw: [([Float], [UInt32])] = []
                for i in 0..<count { raw.append((model.meshVertices(mesh: i), model.meshIndices(mesh: i))) }
                let parts = model.parts()
                await MainActor.run { self.install(model: model, raw: raw, parts: parts, device: device) }
            }
        }

        private func install(model: DuckModel, raw: [([Float], [UInt32])], parts: [ModelPart], device: MTLDevice) {
            meshes = raw.map { v, i in
                (device.makeBuffer(bytes: v, length: v.count * 4)!, device.makeBuffer(bytes: i, length: i.count * 4)!, i.count)
            }
            self.parts = parts
            self.model = model
            onState(.ready)
            redraw()
        }

        private var joints: [Double] = []
        private var quat: [Double]?

        func update(joints: [Double], quat: [Double]?) {
            self.joints = joints
            self.quat = quat
            redraw()
        }

        /// 限 30 fps，空闲时不重绘。
        private func redraw() {
            guard let model, !pending else { return }
            let wait = max(0, 1.0 / 30 - Date().timeIntervalSince(lastFrame))
            pending = true
            Task { @MainActor in
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                self.pending = false
                self.matrices = model.partMatrices(joints: self.joints.isEmpty ? Array(repeating: 0, count: 15) : self.joints, quat: self.quat)
                self.lastFrame = Date()
                self.view?.setNeedsDisplay()
            }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let d = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            azimuth += Float(d.x) * 0.012
            elevation = max(0.05, min(0.82, elevation - Float(d.y) * 0.008))
            view?.setNeedsDisplay()
        }

        @objc func reset() {
            azimuth = defaultAzimuth
            elevation = defaultElevation
            view?.setNeedsDisplay()
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { render(view) }
        }

        private struct Uniforms {
            var model: simd_float4x4
            var right: SIMD4<Float>
            var up: SIMD4<Float>
            var forward: SIMD4<Float>
            var light: SIMD4<Float>
            var colour: SIMD4<Float>
            var scale: SIMD2<Float>
            var lookAt: Float
            var lineMode: Float
        }

        private func render(_ view: MTKView) {
            guard let pipeline, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let queue = view.device?.makeCommandQueue(), let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            let size = view.drawableSize
            let vp = viewParams(azimuth: azimuth, elevation: elevation, width: Float(size.width), height: Float(size.height))
            let v4 = { (a: [Float]) in SIMD4<Float>(a[0], a[1], a[2], 0) }
            var u = Uniforms(model: matrix_identity_float4x4, right: v4(vp.right), up: v4(vp.up), forward: v4(vp.forward),
                             light: v4(vp.light), colour: SIMD4(0.89, 0.91, 0.93, 0.18), scale: SIMD2(vp.scaleX, vp.scaleY),
                             lookAt: vp.lookAt, lineMode: 1)
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depth)
            enc.setFrontFacing(.counterClockwise)
            if let grid {
                enc.setVertexBuffer(grid.0, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: grid.1)
            }
            u.lineMode = 0
            for (i, part) in parts.enumerated() where (i + 1) * 16 <= matrices.count {
                let m = Array(matrices[i * 16..<(i + 1) * 16])
                u.model = simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                        SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
                u.colour = SIMD4(part.r, part.g, part.b, 1)
                let mesh = meshes[Int(part.mesh)]
                enc.setVertexBuffer(mesh.0, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.2, indexType: .uint32, indexBuffer: mesh.1, indexBufferOffset: 0)
            }
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }

        static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct U { float4x4 model; float4 right; float4 up; float4 forward; float4 light; float4 colour; float2 scale; float lookAt; float lineMode; };
        struct VIn { float3 pos [[attribute(0)]]; };
        struct VOut { float4 pos [[position]]; float3 world; };
        vertex VOut vtx(VIn in [[stage_in]], constant U& u [[buffer(1)]]) {
            float3 w = (u.model * float4(in.pos, 1.0)).xyz;
            VOut o;
            o.world = w;
            o.pos = float4(dot(w, u.right.xyz) * u.scale.x, (dot(w, u.up.xyz) - u.lookAt) * u.scale.y,
                           dot(w, u.forward.xyz) + 0.5, 1.0);
            return o;
        }
        fragment float4 frag(VOut in [[stage_in]], constant U& u [[buffer(1)]], bool front [[front_facing]]) {
            if (u.lineMode > 0.5) return float4(u.colour.rgb * u.colour.a, u.colour.a);
            float3 n = -normalize(cross(dfdx(in.world), dfdy(in.world)));
            if (!front) n = -n;
            float diffuse = max(dot(n, normalize(u.light.xyz)), 0.0);
            float hemi = 0.5 + 0.5 * n.z;
            float shade = 0.56 + 0.34 * diffuse + 0.10 * hemi;
            return float4(u.colour.rgb * shade, 1.0);
        }
        """
    }
}
