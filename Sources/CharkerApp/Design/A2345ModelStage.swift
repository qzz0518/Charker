import AppKit
import CharkerCore
import CharkerDraco
import GLTFKit2
import SceneKit
import SwiftUI

private enum A2345ModelMaterialName {
    static let sourceScreen = "1280X1280 (2)"
}

/// A restrained native product stage for the A2345.
///
/// The A2687 scene contains hand-mapped port meshes and screen replacement
/// targets. Those coordinates are model-specific, so reusing that renderer
/// would make six fake hit targets look authoritative. This viewer keeps the
/// official A2345 geometry, native orbit controls and live connection state,
/// while port selection stays in the exact six-row instrument beside it.
struct A2345ModelStage: View {
    var active: Bool
    var stale = false
    var reading: ChargerReading?
    @Binding var homeCamera: ModelCameraPose?
    var height: CGFloat = 304

    @State private var loadState = DigitalTwinLoadState.loading
    @State private var orbitCommand: A2345OrbitCommand?
    @State private var levelGeneration = 0
    @State private var resetGeneration = 0
    @State private var captureGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        accessibleStage
    }

    private var visualStage: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.well, Palette.surfaceElevated],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if loadState == .failed {
                VStack(spacing: Space.s) {
                    A2345FallbackFigure(active: active, reading: reading)
                        .frame(width: height * 0.43, height: height * 0.52)
                    Text("A2345 三维模型暂不可用，实时数据不受影响")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            } else {
                A2345SceneView(
                    active: active,
                    reduceMotion: reduceMotion,
                    homeCamera: homeCamera,
                    levelGeneration: levelGeneration,
                    resetGeneration: resetGeneration,
                    captureGeneration: captureGeneration,
                    loadState: $loadState,
                    command: orbitCommand,
                    onCameraCapture: { homeCamera = $0 }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: Space.s) {
                if loadState == .loading { ProgressView().controlSize(.mini) }
                Image(systemName: "move.3d")
                    .font(.system(size: 10, weight: .medium))
                Text(L10n.text(loadState == .loading ? "载入 A2345" : "拖动旋转 · 滚轮缩放"))
                    .font(Typo.micro)
            }
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, Space.s)
            .frame(height: 24)
            .background(Capsule().fill(Palette.well.opacity(0.88)))
            .padding(Space.m)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: Space.s) {
                HStack(spacing: Space.xs) {
                    ForEach(ChargerProduct.a2345.ports) { port in
                        let live = active && reading?.port(port)?.isDelivering == true
                        HStack(spacing: 4) {
                            Circle()
                                .fill(live ? Palette.accent : Palette.textTertiary.opacity(0.45))
                                .frame(width: 5, height: 5)
                            Text(port.label)
                                .font(.numeral(9, .semibold))
                        }
                        .foregroundStyle(live ? Palette.accentText : Palette.textTertiary)
                    }
                }
                .padding(.horizontal, Space.s)
                .frame(height: 24)
                .background(Capsule().fill(Palette.well.opacity(0.9)))
                .allowsHitTesting(false)

                Spacer(minLength: Space.xs)
                resetControls
            }
            .padding(Space.m)
        }
        .overlay(alignment: .topTrailing) {
            if loadState == .ready { cameraSettingsMenu }
        }
        .animation(.easeOut(duration: 0.2), value: loadState)
    }

    @ViewBuilder
    private var resetControls: some View {
        if loadState == .ready {
            HStack(spacing: Space.xs) {
                Button {
                    levelGeneration += 1
                } label: {
                    Label("水平归位", systemImage: "arrow.left.and.right")
                        .font(Typo.micro)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(GhostButtonStyle())
                .help("将机身恢复到桌面水平姿态，保留当前缩放")
                .accessibilityLabel(Text(L10n.text("水平归位")))

                Button {
                    resetGeneration += 1
                } label: {
                    Label("归位", systemImage: "view.3d")
                        .font(Typo.micro)
                }
                .buttonStyle(GhostButtonStyle())
                .help("恢复保存的归位视角与缩放")
            }
            .transition(.opacity)
        }
    }

    private var cameraSettingsMenu: some View {
        Menu {
            Button {
                captureGeneration += 1
            } label: {
                Label("将当前视角设为归位", systemImage: "bookmark.fill")
            }

            Button {
                homeCamera = nil
                resetGeneration += 1
            } label: {
                Label("恢复初始归位视角", systemImage: "arrow.counterclockwise")
            }
            .disabled(homeCamera == nil)
        } label: {
            Label("设定", systemImage: homeCamera == nil ? "viewfinder" : "bookmark.fill")
                .font(Typo.micro)
        }
        .menuIndicator(.hidden)
        .buttonStyle(GhostButtonStyle())
        .help("设置归位视角与缩放")
        .accessibilityLabel(Text(L10n.text(
            homeCamera == nil ? "设定归位视角" : "自定义归位视角已启用"
        )))
        .padding(Space.m)
        .transition(.opacity)
    }

    private var interactiveStage: some View {
        visualStage
        // A mouse click still hands first responder to the native SceneKit
        // view, while this SwiftUI focus entry makes the same controls reachable
        // by Tab and gives keyboard users a visible system focus ring.
        .focusable(loadState == .ready)
        .onKeyPress(phases: .down, action: handleKeyPress)
    }

    private var accessibleStage: some View {
        interactiveStage
        // Keep the visible camera controls independently reachable, matching
        // the A2687 stage instead of collapsing them into one model element.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Anker Prime 250W 三维模型"))
        .accessibilityValue(Text(accessibilitySummary))
        .accessibilityHint(Text(L10n.text("方向键旋转，加减号缩放，0 归位")))
        .accessibilityActions {
            Button("向左旋转") { send(.rotateLeft) }
            Button("向右旋转") { send(.rotateRight) }
            Button("向上旋转") { send(.rotateUp) }
            Button("向下旋转") { send(.rotateDown) }
            Button("放大模型") { send(.zoomIn) }
            Button("缩小模型") { send(.zoomOut) }
            Button("水平归位") { levelGeneration += 1 }
            Button("归位") { send(.reset) }
            Button("将当前视角设为归位") { captureGeneration += 1 }
        }
    }

    private func send(_ action: A2345OrbitAction) {
        guard loadState == .ready else { return }
        orbitCommand = A2345OrbitCommand(action: action)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard loadState == .ready else { return .ignored }
        let action: A2345OrbitAction?
        switch press.key {
        case .leftArrow: action = .rotateLeft
        case .rightArrow: action = .rotateRight
        case .upArrow: action = .rotateUp
        case .downArrow: action = .rotateDown
        case .escape: action = .reset
        default:
            switch press.characters {
            case "+", "=": action = .zoomIn
            case "-", "_": action = .zoomOut
            case "0": action = .reset
            default: action = nil
            }
        }
        guard let action else { return .ignored }
        send(action)
        return .handled
    }

    private var accessibilitySummary: String {
        if loadState == .loading { return L10n.text("载入 A2345") }
        if loadState == .failed {
            return L10n.text("A2345 三维模型暂不可用，实时数据不受影响")
        }
        if stale { return L10n.text("数据已陈旧") }
        guard active else { return L10n.text("未连接") }
        let activePorts = ChargerProduct.a2345.ports.compactMap { port in
            reading?.port(port)?.isDelivering == true ? port.label : nil
        }
        return activePorts.isEmpty
            ? L10n.text("没有端口在输出")
            : L10n.format("%@ 正在输出", activePorts.joined(separator: L10n.text("、")))
    }
}

private enum A2345OrbitAction: Sendable {
    case rotateLeft
    case rotateRight
    case rotateUp
    case rotateDown
    case zoomIn
    case zoomOut
    case reset
}

private struct A2345OrbitCommand: Equatable {
    let id = UUID()
    let action: A2345OrbitAction
}

/// A model-specific fallback rather than the three-port A2687 illustration.
/// It is deliberately schematic: the labels and live dots stay truthful even
/// when the optional GLB cannot be loaded, without inventing clickable mesh
/// coordinates for the six physical sockets.
private struct A2345FallbackFigure: View {
    var active: Bool
    var reading: ChargerReading?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.black.opacity(0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                }

            VStack(spacing: 8) {
                Text("250")
                    .font(.numeral(18, .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                Text("W")
                    .font(Typo.micro)
                    .foregroundStyle(Color.white.opacity(0.52))

                VStack(spacing: 5) {
                    ForEach(Array(ChargerProduct.a2345.ports.enumerated()), id: \.element.id) {
                        _, port in
                        HStack(spacing: 6) {
                            Capsule()
                                .fill(Color.black.opacity(0.72))
                                .frame(
                                    width: port.connectorLabel == "USB-C" ? 24 : 17,
                                    height: port.connectorLabel == "USB-C" ? 7 : 10
                                )
                                .overlay {
                                    Capsule()
                                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                                }
                            Text(port.label)
                                .font(.numeral(8, .semibold))
                                .foregroundStyle(Color.white.opacity(0.66))
                            Circle()
                                .fill(active && reading?.port(port)?.isDelivering == true
                                    ? Palette.accent : Color.white.opacity(0.18))
                                .frame(width: 5, height: 5)
                        }
                    }
                }
            }
            .padding(.vertical, 13)
        }
        .shadow(color: Color.black.opacity(0.34), radius: 18, y: 10)
    }
}

private struct A2345SceneView: NSViewRepresentable {
    var active: Bool
    var reduceMotion: Bool
    var homeCamera: ModelCameraPose?
    var levelGeneration: Int
    var resetGeneration: Int
    var captureGeneration: Int
    @Binding var loadState: DigitalTwinLoadState
    var command: A2345OrbitCommand?
    var onCameraCapture: (ModelCameraPose) -> Void

    func makeCoordinator() -> Coordinator {
        // A representable recreated after a breakpoint change must start from
        // its home camera, not replay the last key command retained by the
        // parent view's state.
        Coordinator(
            loadState: $loadState,
            initialCommandID: command?.id,
            onCameraCapture: onCameraCapture
        )
    }

    func makeNSView(context: Context) -> A2345OrbitSceneView {
        let view = A2345OrbitSceneView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        // SceneKit's built-in camera controller interprets precise trackpad
        // scrolling as pan. The stage promises scroll-to-zoom, so own the two
        // gestures explicitly and keep panning disabled.
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = false
        view.reduceMotion = reduceMotion
        view.configureInitialCamera(
            homeCamera,
            levelGeneration: levelGeneration,
            resetGeneration: resetGeneration,
            captureGeneration: captureGeneration
        )
        let coordinator = context.coordinator
        coordinator.connectCameraCapture(to: view)
        view.startModelLoad = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.load(into: view)
        }
        view.startModelLoadIfReady()
        return view
    }

    func updateNSView(_ view: A2345OrbitSceneView, context: Context) {
        context.coordinator.onCameraCapture = onCameraCapture
        context.coordinator.connectCameraCapture(to: view)
        view.reduceMotion = reduceMotion
        view.applyHomeCamera(homeCamera)
        view.applyLevelOnTable(generation: levelGeneration)
        view.applyReset(generation: resetGeneration)
        view.applyCapture(generation: captureGeneration)
        view.startModelLoadIfReady()
        view.scene?.rootNode.childNode(withName: "A2345_PRODUCT", recursively: false)?.opacity =
            active ? 1 : 0.48
        context.coordinator.apply(command, to: view)
        view.setNeedsDisplay(view.bounds)
    }

    static func dismantleNSView(_ view: A2345OrbitSceneView, coordinator: Coordinator) {
        coordinator.invalidate()
        view.invalidate()
        view.cameraNode = nil
        view.scene = nil
    }

    @MainActor
    final class Coordinator {
        private var loadState: Binding<DigitalTwinLoadState>
        private var token = UUID()
        private var lastAppliedCommandID: UUID?
        var onCameraCapture: (ModelCameraPose) -> Void
        private static let queue = DispatchQueue(
            label: "dev.charker.a2345-model-loader",
            qos: .userInitiated
        )
        nonisolated(unsafe) private static var retainedAsset: GLTFAsset?
        nonisolated(unsafe) private static var prototype: SCNNode?

        init(
            loadState: Binding<DigitalTwinLoadState>,
            initialCommandID: UUID?,
            onCameraCapture: @escaping (ModelCameraPose) -> Void
        ) {
            self.loadState = loadState
            lastAppliedCommandID = initialCommandID
            self.onCameraCapture = onCameraCapture
        }

        func connectCameraCapture(to view: A2345OrbitSceneView) {
            view.onCameraCapture = { [weak self] pose in
                DispatchQueue.main.async { [weak self] in
                    self?.onCameraCapture(pose)
                }
            }
        }

        func apply(_ command: A2345OrbitCommand?, to view: A2345OrbitSceneView) {
            guard let command, command.id != lastAppliedCommandID else { return }
            guard view.perform(command.action) else { return }
            lastAppliedCommandID = command.id
        }

        func invalidate() { token = UUID() }

        func load(into view: A2345OrbitSceneView) {
            guard let url = A2345ModelResources.modelURL else {
                loadState.wrappedValue = .failed
                return
            }
            let current = UUID()
            token = current
            loadState.wrappedValue = .loading
            CharkerRegisterDracoDecompressor()

            Self.queue.async { [weak self, weak view] in
                let result: Result<SCNNode, Error>
                if let prototype = Self.prototype {
                    result = .success(prototype.clone())
                } else {
                    do {
                        let asset = try GLTFAsset(url: url, options: [:])
                        let source = SCNScene(gltfAsset: asset)
                        let root = SCNNode()
                        source.rootNode.childNodes.forEach { root.addChildNode($0) }
                        Self.retainedAsset = asset
                        Self.prototype = root
                        result = .success(root.clone())
                    } catch {
                        result = .failure(error)
                    }
                }
                DispatchQueue.main.async {
                    guard let self, let view, self.token == current else { return }
                    switch result {
                    case .success(let model): self.install(model, in: view)
                    case .failure: self.loadState.wrappedValue = .failed
                    }
                }
            }
        }

        private func install(_ model: SCNNode, in view: A2345OrbitSceneView) {
            let scene = SCNScene()
            scene.background.contents = NSColor.clear
            tuneImportedMaterials(in: model)

            let bounds = model.boundingBox
            let centre = SCNVector3(
                (bounds.min.x + bounds.max.x) / 2,
                (bounds.min.y + bounds.max.y) / 2,
                (bounds.min.z + bounds.max.z) / 2
            )
            let extent = max(
                bounds.max.x - bounds.min.x,
                bounds.max.y - bounds.min.y,
                bounds.max.z - bounds.min.z
            )
            let scale = extent > 0 ? 1.25 / extent : 1
            model.scale = SCNVector3(scale, scale, scale)
            model.position = SCNVector3(-centre.x * scale, -centre.y * scale - 0.03, -centre.z * scale)

            // Centre the source geometry inside a parent that owns rotation.
            // Rotating the translated source node itself moves its centre off
            // the camera target because SceneKit composes T · R · S.
            let product = SCNNode()
            product.name = "A2345_PRODUCT"
            // SceneKit must stay attached and rendering while GLTFKit settles,
            // but the product itself must not expose the vendor's fixed screen
            // texture. `prepare` still warms this hidden node explicitly.
            product.isHidden = true
            product.eulerAngles.y = -.pi / 8
            product.addChildNode(model)
            scene.rootNode.addChildNode(product)

            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 34
            camera.camera?.zNear = 0.01
            camera.camera?.zFar = 100
            camera.camera?.wantsHDR = true
            // Automatic eye adaptation made the pale metal side ramp toward
            // white after camera movement. Lock exposure so the silver body
            // keeps visible texture and edge separation at every zoom level.
            camera.camera?.wantsExposureAdaptation = false
            camera.camera?.exposureOffset = -0.72
            camera.camera?.bloomIntensity = 0
            camera.position = SCNVector3(0.18, 0.06, 2.25)
            camera.look(
                at: SCNVector3Zero,
                up: SCNVector3(0, 1, 0),
                localFront: SCNVector3(0, 0, -1)
            )
            scene.rootNode.addChildNode(camera)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 210
            key.light?.temperature = 6_100
            key.eulerAngles = SCNVector3(-0.72, -0.58, -0.18)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .omni
            fill.light?.intensity = 52
            fill.position = SCNVector3(1.3, 0.5, 1.1)
            scene.rootNode.addChildNode(fill)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 38
            ambient.light?.color = NSColor(srgbRed: 0.72, green: 0.78, blue: 0.86, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            view.scene = scene
            view.pointOfView = camera
            view.cameraNode = camera
            view.moveToHomeImmediately()
            view.refreshScreenClock(force: true)
            // The labelled overload prepares objects on SceneKit's background
            // worker. The single-object overload is synchronous and made model
            // reconstruction visibly block the main thread.
            view.prepare([product]) { [weak self, weak view] _ in
                DispatchQueue.main.async {
                    guard let self, let view else { return }
                    // GLTFKit resolves embedded texture properties while the
                    // scene is prepared and can still complete a late texture
                    // callback just after this completion handler. Recommit the
                    // clock through that short stabilization window so the
                    // source wattage graphic never remains until the next
                    // minute tick.
                    view.refreshScreenClock(force: true)
                    view.stabilizeScreenClock { [weak self, weak view] in
                        guard let self, let view,
                              let product = view.scene?.rootNode.childNode(
                                  withName: "A2345_PRODUCT",
                                  recursively: false
                              ) else { return }
                        product.isHidden = false
                        view.setNeedsDisplay(view.bounds)
                        self.loadState.wrappedValue = .ready
                        // The binding update removes the loading affordances in
                        // the same run-loop turn. Request one more frame after
                        // SwiftUI has committed that transaction.
                        DispatchQueue.main.async { [weak view] in
                            guard let view else { return }
                            view.setNeedsDisplay(view.bounds)
                            view.displayIfNeeded()
                        }
                    }
                }
            }
        }

        /// The official asset deliberately uses mirror-like metal
        /// (`roughnessFactor = 0`) and an over-range specular extension for a
        /// marketing render. In a compact, untonemapped SceneKit stage those
        /// values clip the pale shell to white. Copy only the affected
        /// materials and give them a restrained product-photography finish.
        /// The screen is also normalized here: the GLB uses a lossy JPEG as
        /// its emissive layer over a sharper transparent PNG. WebGL happens to
        /// hide most of that compression at the site's normal zoom, while
        /// SceneKit magnifies the JPEG edge noise. Replace those duplicate
        /// layers on the existing screen plane with one 1920×768 clock theme.
        /// It stays crisp under close inspection and cannot be mistaken for
        /// live power telemetry.
        private func tuneImportedMaterials(in root: SCNNode) {
            root.enumerateChildNodes { node, _ in
                guard let source = node.geometry,
                      let geometry = source.copy() as? SCNGeometry else { return }
                geometry.materials = source.materials.map { sourceMaterial in
                    guard let material = sourceMaterial.copy() as? SCNMaterial else {
                        return sourceMaterial
                    }
                    let name = material.name ?? ""
                    if name == A2345ModelMaterialName.sourceScreen {
                        material.lightingModel = .constant
                        // Keep the model hidden while the imported texture is
                        // prepared. The clock is committed repeatedly during
                        // the stabilization window before the stage becomes
                        // visible, so this safe black never reaches the user.
                        material.diffuse.contents = NSColor.black
                        material.emission.contents = nil
                        material.blendMode = .alpha
                        material.transparencyMode = .aOne
                        material.transparency = 1
                        material.diffuse.wrapS = .clamp
                        material.diffuse.wrapT = .clamp
                        material.diffuse.magnificationFilter = .linear
                        material.diffuse.minificationFilter = .linear
                        material.diffuse.mipFilter = .linear
                        material.diffuse.maxAnisotropy = 16
                    } else if name.hasPrefix("jinshu") {
                        material.lightingModel = .physicallyBased
                        material.roughness.contents = 0.30
                        material.specular.contents = NSColor(deviceWhite: 0.42, alpha: 1)
                    } else if name.hasPrefix("M_KV_01_v1_table_") {
                        material.lightingModel = .physicallyBased
                        material.roughness.contents = 0.44
                        material.specular.contents = NSColor(deviceWhite: 0.24, alpha: 1)
                    }
                    return material
                }
                node.geometry = geometry
            }
        }

    }
}

/// Small, purpose-built orbit controller for the six-port model. SceneKit's
/// stock controller supports panning, which is useful in a general 3D editor
/// but wrong for a fixed product stage: two-finger vertical scrolling moved
/// the charger up and down instead of changing its scale.
private final class A2345OrbitSceneView: SCNView {
    weak var cameraNode: SCNNode?
    var startModelLoad: (() -> Void)?
    var onCameraCapture: ((ModelCameraPose) -> Void)?
    var reduceMotion = false

    private var lastDragPoint: NSPoint?
    private var screenClockTimer: Timer?
    private var screenClockStabilizationWorkItems: [DispatchWorkItem] = []
    private var cameraAnimationTimer: Timer?
    private var renderedMinute: Int?
    private var didStartModelLoad = false
    private var azimuth = defaultAzimuth
    private var elevation = defaultElevation
    private var distance = defaultDistance
    private var homeAzimuth = defaultAzimuth
    private var homeElevation = defaultElevation
    private var homeDistance = defaultDistance
    private var hasConfiguredHome = false
    private var appliedLevelGeneration = 0
    private var appliedResetGeneration = 0
    private var appliedCaptureGeneration = 0

    private static let defaultAzimuth: Float = 0.08
    private static let defaultElevation: Float = 0.027
    private static let defaultDistance: Float = 2.25
    private let minimumElevation: Float = -0.46
    private let maximumElevation: Float = 0.62
    private let minimumDistance: Float = 1.48
    private let maximumDistance: Float = 3.35
    private let resetDuration: TimeInterval = 0.58

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            screenClockTimer?.invalidate()
            screenClockTimer = nil
            return
        }
        startModelLoadIfReady()
        refreshScreenClock()
        guard screenClockTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshScreenClock()
        }
        RunLoop.main.add(timer, forMode: .common)
        screenClockTimer = timer
    }

    deinit {
        screenClockTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        startModelLoadIfReady()
        guard bounds.width > 1, bounds.height > 1 else { return }
        setNeedsDisplay(bounds)
    }

    func startModelLoadIfReady() {
        guard !didStartModelLoad,
              window != nil,
              bounds.width > 1,
              bounds.height > 1,
              let startModelLoad else { return }
        didStartModelLoad = true
        self.startModelLoad = nil
        startModelLoad()
    }

    func invalidate() {
        startModelLoad = nil
        screenClockTimer?.invalidate()
        screenClockTimer = nil
        screenClockStabilizationWorkItems.forEach { $0.cancel() }
        screenClockStabilizationWorkItems.removeAll()
        cameraAnimationTimer?.invalidate()
        cameraAnimationTimer = nil
        onCameraCapture = nil
    }

    func configureInitialCamera(
        _ pose: ModelCameraPose?,
        levelGeneration: Int,
        resetGeneration: Int,
        captureGeneration: Int
    ) {
        appliedLevelGeneration = levelGeneration
        appliedResetGeneration = resetGeneration
        appliedCaptureGeneration = captureGeneration
        applyHomeCamera(pose, useAsCurrent: true)
    }

    func applyHomeCamera(_ pose: ModelCameraPose?) {
        applyHomeCamera(pose, useAsCurrent: !hasConfiguredHome)
    }

    private func applyHomeCamera(_ pose: ModelCameraPose?, useAsCurrent: Bool) {
        let next = orbit(from: pose)
        homeAzimuth = next.azimuth
        homeElevation = next.elevation
        homeDistance = next.distance
        if useAsCurrent {
            azimuth = next.azimuth
            elevation = next.elevation
            distance = next.distance
        }
        hasConfiguredHome = true
    }

    func applyReset(generation: Int) {
        guard generation != appliedResetGeneration else { return }
        appliedResetGeneration = generation
        resetOrbit()
    }

    func applyLevelOnTable(generation: Int) {
        guard generation != appliedLevelGeneration else { return }
        appliedLevelGeneration = generation
        animateOrbit(
            toAzimuth: Self.defaultAzimuth,
            elevation: Self.defaultElevation,
            distance: distance
        )
    }

    func applyCapture(generation: Int) {
        guard generation != appliedCaptureGeneration else { return }
        appliedCaptureGeneration = generation
        let degrees = 180.0 / Double.pi
        onCameraCapture?(ModelCameraPose(
            theta: Double(OrbitInteractionMath.normalizedRadians(azimuth)) * degrees,
            phi: Double(elevation) * degrees,
            distance: Double(distance)
        ))
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        cancelCameraAnimation()
        window?.makeFirstResponder(self)
        lastDragPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let lastDragPoint else {
            self.lastDragPoint = point
            return
        }
        let deltaX = Float(point.x - lastDragPoint.x)
        let deltaY = Float(point.y - lastDragPoint.y)
        guard deltaX.isFinite, deltaY.isFinite else {
            self.lastDragPoint = point
            return
        }
        azimuth = OrbitInteractionMath.normalizedRadians(azimuth - deltaX * 0.008)
        elevation = OrbitInteractionMath.elevation(
            current: elevation,
            verticalDrag: deltaY,
            sensitivity: 0.007,
            minimum: minimumElevation,
            maximum: maximumElevation
        )
        self.lastDragPoint = point
        applyOrbit()
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        NSCursor.openHand.set()
    }

    override func scrollWheel(with event: NSEvent) {
        cancelCameraAnimation()
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.0065 : 0.030
        let amount = -event.scrollingDeltaY * scale
        guard amount.isFinite else { return }
        if !zoom(by: amount) {
            // Once the camera reaches either limit, return continued scrolling
            // to the enclosing page instead of trapping the pointer forever.
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        cancelCameraAnimation()
        let amount = -event.magnification * 1.5
        guard amount.isFinite else { return }
        _ = zoom(by: amount)
    }

    override func keyDown(with event: NSEvent) {
        let action: A2345OrbitAction?
        switch event.keyCode {
        case 123: action = .rotateLeft
        case 124: action = .rotateRight
        case 125: action = .rotateDown
        case 126: action = .rotateUp
        case 53: action = .reset
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=": action = .zoomIn
            case "-", "_": action = .zoomOut
            case "0": action = .reset
            default: action = nil
            }
        }
        guard let action, perform(action) else {
            super.keyDown(with: event)
            return
        }
    }

    @discardableResult
    func perform(_ action: A2345OrbitAction) -> Bool {
        guard cameraNode != nil else { return false }
        cancelCameraAnimation()
        switch action {
        case .rotateLeft:
            azimuth = OrbitInteractionMath.normalizedRadians(azimuth + 0.10)
        case .rotateRight:
            azimuth = OrbitInteractionMath.normalizedRadians(azimuth - 0.10)
        case .rotateUp:
            elevation = clamp(elevation - 0.08, minimumElevation, maximumElevation)
        case .rotateDown:
            elevation = clamp(elevation + 0.08, minimumElevation, maximumElevation)
        case .zoomIn:
            _ = zoom(by: -0.12)
            return true
        case .zoomOut:
            _ = zoom(by: 0.12)
            return true
        case .reset:
            resetOrbit()
            return true
        }
        applyOrbit()
        return true
    }

    func resetOrbit() {
        animateOrbit(
            toAzimuth: homeAzimuth,
            elevation: homeElevation,
            distance: homeDistance
        )
    }

    func moveToHomeImmediately() {
        cancelCameraAnimation()
        azimuth = homeAzimuth
        elevation = homeElevation
        distance = homeDistance
        applyOrbit()
    }

    func refreshScreenClock(at date: Date = Date(), force: Bool = false) {
        let minute = Int(date.timeIntervalSince1970 / 60)
        guard force || minute != renderedMinute else { return }
        renderedMinute = minute
        let artwork = A2345ScreenArtwork.bubbleClock(at: date)
        scene?.rootNode.enumerateChildNodes { node, _ in
            node.geometry?.materials
                .filter { $0.name == A2345ModelMaterialName.sourceScreen }
                .forEach { material in
                material.lightingModel = .constant
                material.diffuse.contents = artwork
                material.emission.contents = nil
                material.blendMode = .alpha
                material.transparencyMode = .aOne
                material.transparency = 1
            }
        }
        setNeedsDisplay(bounds)
    }

    func stabilizeScreenClock(completion: @escaping () -> Void) {
        screenClockStabilizationWorkItems.forEach { $0.cancel() }
        screenClockStabilizationWorkItems.removeAll(keepingCapacity: true)
        let delays = [0.08, 0.25, 0.65, 1.4]
        for (index, delay) in delays.enumerated() {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.refreshScreenClock(force: true)
                if index == delays.indices.last { completion() }
            }
            screenClockStabilizationWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    @discardableResult
    private func zoom(by amount: CGFloat) -> Bool {
        guard amount.isFinite, distance.isFinite else {
            resetOrbit()
            return false
        }
        let next = clamp(
            distance * Float(exp(Double(amount))),
            minimumDistance,
            maximumDistance
        )
        guard abs(next - distance) > 0.000_1 else { return false }
        distance = next
        applyOrbit()
        return true
    }

    private func applyOrbit() {
        guard let cameraNode else { return }
        guard azimuth.isFinite, elevation.isFinite, distance.isFinite else {
            azimuth = homeAzimuth
            elevation = homeElevation
            distance = homeDistance
            applyOrbit()
            return
        }
        azimuth = OrbitInteractionMath.normalizedRadians(azimuth)
        let horizontal = distance * cos(elevation)
        cameraNode.position = SCNVector3(
            horizontal * sin(azimuth),
            distance * sin(elevation),
            horizontal * cos(azimuth)
        )
        // Pin the camera roll to world-up. The one-argument `look(at:)`
        // preserves an ambiguous roll component, so repeated orbiting can
        // leave the charger diagonally tilted even after its position resets.
        cameraNode.look(
            at: SCNVector3Zero,
            up: SCNVector3(0, 1, 0),
            localFront: SCNVector3(0, 0, -1)
        )
        setNeedsDisplay(bounds)
    }

    private func orbit(from pose: ModelCameraPose?) -> (
        azimuth: Float,
        elevation: Float,
        distance: Float
    ) {
        guard let pose,
              pose.theta.isFinite,
              pose.phi.isFinite,
              pose.distance.isFinite else {
            return (Self.defaultAzimuth, Self.defaultElevation, Self.defaultDistance)
        }
        let radians = Float.pi / 180
        return (
            OrbitInteractionMath.normalizedRadians(Float(pose.theta) * radians),
            clamp(Float(pose.phi) * radians, minimumElevation, maximumElevation),
            clamp(Float(pose.distance), minimumDistance, maximumDistance)
        )
    }

    private func animateOrbit(
        toAzimuth targetAzimuth: Float,
        elevation targetElevation: Float,
        distance targetDistance: Float
    ) {
        cancelCameraAnimation()
        guard cameraNode != nil, !reduceMotion else {
            azimuth = targetAzimuth
            elevation = targetElevation
            distance = targetDistance
            applyOrbit()
            return
        }

        let startAzimuth = azimuth
        let startElevation = elevation
        let startDistance = distance
        var azimuthDelta = OrbitInteractionMath.normalizedRadians(targetAzimuth - startAzimuth)
        if !azimuthDelta.isFinite { azimuthDelta = 0 }
        let elevationDelta = targetElevation - startElevation
        let distanceDelta = targetDistance - startDistance
        let startedAt = ProcessInfo.processInfo.systemUptime
        let duration = resetDuration

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if self.reduceMotion {
                timer.invalidate()
                self.cameraAnimationTimer = nil
                self.azimuth = targetAzimuth
                self.elevation = targetElevation
                self.distance = targetDistance
                self.applyOrbit()
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let progress = Float(min(1, max(0, elapsed / duration)))
            let eased = progress * progress * progress
                * (progress * (progress * 6 - 15) + 10)
            self.azimuth = OrbitInteractionMath.normalizedRadians(
                startAzimuth + azimuthDelta * eased
            )
            self.elevation = startElevation + elevationDelta * eased
            self.distance = startDistance + distanceDelta * eased
            self.applyOrbit()
            if progress >= 1 {
                timer.invalidate()
                self.cameraAnimationTimer = nil
                self.azimuth = targetAzimuth
                self.elevation = targetElevation
                self.distance = targetDistance
                self.applyOrbit()
            }
        }
        cameraAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelCameraAnimation() {
        cameraAnimationTimer?.invalidate()
        cameraAnimationTimer = nil
    }

    private func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(max(value, lower), upper)
    }
}

private enum A2345ModelResources {
    static var modelURL: URL? {
        for directory in candidateDirectories {
            let candidate = directory.appendingPathComponent("A2345.glb")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static var candidateDirectories: [URL] {
        var directories: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL.appendingPathComponent("Model3D"))
        }
        #if DEBUG
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        directories.append(repository.appendingPathComponent("Resources/Model3D"))
        #endif
        return directories
    }
}
