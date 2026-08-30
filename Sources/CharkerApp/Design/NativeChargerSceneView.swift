import AppKit
import CharkerDraco
import CharkerCore
import GLTFKit2
import ImageIO
import SceneKit
import SwiftUI
import simd

/// A thin SwiftUI adapter around a native SceneKit view. Camera gestures mutate
/// the `SCNNode` directly, so dragging and zooming never invalidate SwiftUI and
/// never cross a WebKit/JavaScript boundary.
struct NativeChargerSceneView: NSViewRepresentable {
    var portWatts: [Double]
    var portsLit: [Bool]
    var portCables: [DigitalTwinCableState]
    var totalWatts: Double
    var active: Bool
    var highlightedPort: Int?
    var selectedPort: Int?
    var reduceMotion: Bool
    var homeCamera: ModelCameraPose?
    var screenStyle: ModelScreenStyle
    var customScreenImage: NSImage?
    var screenArtworkRevision: Int
    var resetGeneration: Int
    var captureGeneration: Int
    @Binding var loadState: DigitalTwinLoadState
    var onPortTap: (Int) -> Void
    var onPortHover: (Int?) -> Void
    var onCameraCapture: (ModelCameraPose) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NativeChargerContainerView {
        let view = NativeChargerContainerView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.connectCallbacks()
        view.applyHomeCamera(homeCamera)
        view.apply(renderState)
        view.applyScreenArtwork(
            style: screenStyle,
            customImage: customScreenImage,
            revision: screenArtworkRevision
        )
        view.applyReset(generation: resetGeneration)
        view.applyCapture(generation: captureGeneration)
        view.loadModel()
        return view
    }

    func updateNSView(_ view: NativeChargerContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.connectCallbacks()
        view.applyHomeCamera(homeCamera)
        view.apply(renderState)
        view.applyScreenArtwork(
            style: screenStyle,
            customImage: customScreenImage,
            revision: screenArtworkRevision
        )
        view.applyReset(generation: resetGeneration)
        view.applyCapture(generation: captureGeneration)
    }

    static func dismantleNSView(_ view: NativeChargerContainerView, coordinator: Coordinator) {
        view.invalidate()
        coordinator.view = nil
    }

    private var renderState: NativeChargerRenderState {
        NativeChargerRenderState(
            active: active,
            totalWatts: totalWatts.finiteOrZero,
            highlightedPort: highlightedPort,
            selectedPort: selectedPort,
            reduceMotion: reduceMotion,
            ports: (0..<3).map { index in
                let cable = portCables[safe: index] ?? .unknown
                return .init(
                    watts: (portWatts[safe: index] ?? 0).finiteOrZero,
                    lit: active && (portsLit[safe: index] ?? false),
                    attached: active ? cable.attached : nil,
                    capability: cable.capability
                )
            }
        )
    }

    @MainActor
    final class Coordinator {
        var parent: NativeChargerSceneView
        weak var view: NativeChargerContainerView?

        init(parent: NativeChargerSceneView) {
            self.parent = parent
        }

        func connectCallbacks() {
            view?.onLoadStateChange = { [weak self] state in
                guard let self else { return }
                if self.parent.loadState != state {
                    self.parent.loadState = state
                }
            }
            view?.onPortTap = { [weak self] index in
                self?.parent.onPortTap(index)
            }
            view?.onPortHover = { [weak self] index in
                self?.parent.onPortHover(index)
            }
            view?.onCameraCapture = { [weak self] pose in
                // `applyCapture` runs from `updateNSView`. Defer the binding
                // write until that representable update has finished so the
                // saved home camera never mutates SwiftUI state mid-render.
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onCameraCapture(pose)
                }
            }
        }
    }
}

struct NativeChargerRenderState: Equatable {
    struct Port: Equatable {
        let watts: Double
        let lit: Bool
        let attached: Bool?
        let capability: String?
    }

    let active: Bool
    let totalWatts: Double
    let highlightedPort: Int?
    let selectedPort: Int?
    let reduceMotion: Bool
    let ports: [Port]
}

private struct ChargerOrbit: Equatable {
    var theta: Float
    var phi: Float
    var distance: Float
}

private struct ChargerPortSpec {
    let position: SIMD3<Float>
    let normal: SIMD3<Float>
    let cableEnd: SIMD3<Float>
}

private struct ScreenArtworkTarget {
    let sourceNode: SCNNode
    let replacementNode: SCNNode
    let materialTemplates: [SCNMaterial]
    let baseScale: SIMD3<Float>
    let basePosition: SIMD3<Float>
    let baseOrientation: simd_quatf
}

private struct TopGlassTarget {
    let sourceNode: SCNNode
    let replacementNode: SCNNode
}

private enum ChargerSceneMetrics {
    static let cameraTarget = SIMD3<Float>(0.0035, -0.006, 0.001)
    static let cameraResetDuration: TimeInterval = 0.58
    static let screenArtworkNodeName = "资源 9@4x"
    static let topGlassNodeName = "51923734"
    static let topGlassMaterialName = "A2687_LCD_DECO_COVER"
    /// The imported artwork mesh was authored for the wide stock wattage
    /// graphic. Custom square artwork needs a modest physical enlargement to
    /// match the display proportion of the real charger.
    static let customScreenArtworkScale: Float = 1.18
    /// After enlargement, move the custom square slightly toward the button
    /// and back toward the horizontal centre of the cover. This makes the
    /// visible top, left and right glass margins read as one consistent bezel.
    static let customScreenArtworkOffset = SIMD3<Float>(-0.00028, 0, 0.0018)
    // Preserve the composition from the previous Three.js preview. SceneKit's
    // horizontal world orientation is mirrored relative to that renderer.
    static let defaultOrbit = ChargerOrbit(theta: 29.77, phi: 64.91, distance: 0.174)
    static let minimumDistance: Float = 0.09
    static let maximumDistance: Float = 0.42
    static let minimumPolar: Float = 8
    static let maximumPolar: Float = 172
    static let cableApproachOffset: Float = 0.015
    static let cableSeatedOffset: Float = -0.0058
    static let portHitCategory = 1 << 8

    static func orbit(from pose: ModelCameraPose?) -> ChargerOrbit {
        guard let pose,
              pose.theta.isFinite,
              pose.phi.isFinite,
              pose.distance.isFinite else { return defaultOrbit }
        return ChargerOrbit(
            theta: Float(pose.theta.truncatingRemainder(dividingBy: 360)),
            phi: clamp(Float(pose.phi), minimumPolar, maximumPolar),
            distance: clamp(Float(pose.distance), minimumDistance, maximumDistance)
        )
    }

    static let ports = [
        ChargerPortSpec(
            position: SIMD3(0.00556, 0.01091, 0.03208),
            normal: simd_normalize(SIMD3(0.053, 0.003, 0.999)),
            cableEnd: SIMD3(-0.014, -0.095, 0.058)
        ),
        ChargerPortSpec(
            position: SIMD3(0.00564, -0.00128, 0.03211),
            normal: simd_normalize(SIMD3(0.053, 0.003, 0.999)),
            cableEnd: SIMD3(0.006, -0.095, 0.055)
        ),
        ChargerPortSpec(
            position: SIMD3(0.00597, -0.01396, 0.03214),
            normal: simd_normalize(SIMD3(0.054, 0.004, 0.999)),
            cableEnd: SIMD3(0.026, -0.095, 0.052)
        ),
    ]
}

/// Owns the renderer and its overlay controls. It deliberately uses one cursor
/// (`openHand`) for the entire interactive surface—including port buttons—so
/// AppKit never alternates between WebKit's CSS cursor and the host arrow.
final class NativeChargerContainerView: NSView {
    var onLoadStateChange: ((DigitalTwinLoadState) -> Void)?
    var onPortTap: ((Int) -> Void)?
    var onPortHover: ((Int?) -> Void)?
    var onCameraCapture: ((ModelCameraPose) -> Void)?

    private let sceneView = NativeOrbitSceneView(
        frame: NSRect(x: 0, y: 0, width: 1, height: 1),
        options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue,
        ]
    )
    private let portButtons = (0..<3).map(NativePortButton.init)
    private let cameraNode = SCNNode()
    private var modelRoot: SCNNode?
    private var screenArtworkTargets: [ScreenArtworkTarget] = []
    private var topGlassTargets: [TopGlassTarget] = []
    private var cables: [NativeCableVisual] = []
    private var orbit = ChargerSceneMetrics.defaultOrbit
    private var homeOrbit = ChargerSceneMetrics.defaultOrbit
    private var hasConfiguredHomeOrbit = false
    private var renderState: NativeChargerRenderState?
    private var pointerPort: Int?
    private var appliedResetGeneration = 0
    private var appliedCaptureGeneration = 0
    private var loadToken = UUID()
    private var modelLoadRequested = false
    private var modelLoadInFlight = false
    private var modelLoaded = false
    private var firstTelemetry = true
    private var playbackGeneration = 0
    private var cameraAnimationTimer: Timer?
    private var screenStyle = ModelScreenStyle.ankerPrime
    private var customScreenImage: NSImage?
    private var screenArtworkRevision = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        sceneView.autoresizingMask = [.width, .height]
        sceneView.backgroundColor = NSColor.clear
        sceneView.antialiasingMode = SCNAntialiasingMode.multisampling2X
        sceneView.preferredFramesPerSecond = 60
        sceneView.rendersContinuously = false
        sceneView.isPlaying = false
        sceneView.showsStatistics = false
        sceneView.allowsCameraControl = false
        sceneView.setAccessibilityLabel(L10n.text("Anker Prime 160W 原生三维视图"))
        addSubview(sceneView)

        for button in portButtons {
            button.target = self
            button.action = #selector(portButtonPressed(_:))
            button.onHover = { [weak self] index, inside in
                self?.setPointerPort(inside ? index : nil)
            }
            button.isHidden = true
            addSubview(button)
        }

        sceneView.onOrbit = { [weak self] (deltaX: CGFloat, deltaY: CGFloat) in
            self?.orbitCamera(deltaX: deltaX, deltaY: deltaY)
        }
        sceneView.onZoom = { [weak self] (amount: CGFloat) in
            self?.zoomCamera(amount: amount)
        }
        sceneView.onHoverPoint = { [weak self] (point: NSPoint?) in
            guard let self else { return }
            self.setPointerPort(point.flatMap(self.portIndex(at:)))
        }
        sceneView.onClickPoint = { [weak self] (point: NSPoint) in
            guard let self, let index = self.portIndex(at: point) else { return }
            self.onPortTap?(index)
        }
        sceneView.onKeyCommand = { [weak self] command in
            self?.handle(command) ?? false
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        sceneView.frame = bounds
        startModelLoadIfReady()
        sceneView.setNeedsDisplay(sceneView.bounds)
        updateOverlayPositions()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startModelLoadIfReady()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshOverlays()
    }

    func loadModel() {
        modelLoadRequested = true
        startModelLoadIfReady()
    }

    private func startModelLoadIfReady() {
        guard modelLoadRequested,
              !modelLoaded,
              !modelLoadInFlight,
              window != nil,
              bounds.width > 1,
              bounds.height > 1 else { return }
        guard let resources = NativeModel3DResources.current else {
            onLoadStateChange?(.failed)
            return
        }

        let token = UUID()
        loadToken = token
        modelLoadInFlight = true
        onLoadStateChange?(.loading)
        CharkerRegisterDracoDecompressor()

        NativeChargerModelCache.load(url: resources.modelURL) { [weak self] result in
            guard let self, self.loadToken == token else { return }
            self.modelLoadInFlight = false
            switch result {
            case .success(let root):
                self.install(modelRoot: root, resources: resources)
            case .failure:
                self.onLoadStateChange?(.failed)
            }
        }
    }

    func invalidate() {
        cancelCameraAnimation()
        loadToken = UUID()
        playbackGeneration += 1
        modelLoadRequested = false
        modelLoadInFlight = false
        sceneView.onOrbit = nil
        sceneView.onZoom = nil
        sceneView.onHoverPoint = nil
        sceneView.onClickPoint = nil
        sceneView.onKeyCommand = nil
        portButtons.forEach { $0.onHover = nil }
        onLoadStateChange = nil
        onPortTap = nil
        onPortHover = nil
        onCameraCapture = nil
        sceneView.isPlaying = false
        sceneView.scene = nil
    }

    func apply(_ state: NativeChargerRenderState) {
        guard renderState != state else { return }
        let previous = renderState
        renderState = state
        guard modelLoaded else { return }

        let sceneChanged = sceneVisualsDiffer(from: previous, to: state)
        if previous?.active != state.active {
            modelRoot?.opacity = state.active ? 1 : 0.48
        }
        if sceneChanged {
            updateCables(from: previous, to: state)
        }
        refreshOverlays()
        if sceneChanged { requestSceneDisplay() }
        firstTelemetry = false
    }

    private func sceneVisualsDiffer(
        from previous: NativeChargerRenderState?,
        to state: NativeChargerRenderState
    ) -> Bool {
        guard let previous else { return true }
        guard previous.active == state.active,
              previous.highlightedPort == state.highlightedPort,
              previous.selectedPort == state.selectedPort,
              previous.ports.count == state.ports.count else { return true }
        return zip(previous.ports, state.ports).contains { old, new in
            old.lit != new.lit || old.attached != new.attached
        }
    }

    func applyHomeCamera(_ pose: ModelCameraPose?) {
        let next = ChargerSceneMetrics.orbit(from: pose)
        homeOrbit = next
        guard !hasConfiguredHomeOrbit else { return }
        hasConfiguredHomeOrbit = true
        orbit = next
    }

    func applyScreenArtwork(
        style: ModelScreenStyle,
        customImage: NSImage?,
        revision: Int
    ) {
        guard screenStyle != style || screenArtworkRevision != revision else { return }
        screenStyle = style
        self.customScreenImage = customImage
        screenArtworkRevision = revision
        updateScreenArtwork()
    }

    func applyReset(generation: Int) {
        guard generation != appliedResetGeneration else { return }
        appliedResetGeneration = generation
        animateCamera(to: homeOrbit)
    }

    func applyCapture(generation: Int) {
        guard generation != appliedCaptureGeneration else { return }
        appliedCaptureGeneration = generation
        let normalizedTheta = orbit.theta.truncatingRemainder(dividingBy: 360)
        onCameraCapture?(ModelCameraPose(
            theta: Double(normalizedTheta),
            phi: Double(orbit.phi),
            distance: Double(orbit.distance)
        ))
    }

    private func install(modelRoot: SCNNode, resources: NativeModel3DResources) {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        // Assigning the HDR's URL here made SceneKit re-decode the 1.63 MB
        // file through ImageIO on every install, i.e. on every re-entry into
        // the dashboard tab. Hand every scene the same decoded object instead.
        scene.lightingEnvironment.contents =
            NativeChargerModelCache.environmentContents(for: resources.environmentURL)
        scene.lightingEnvironment.intensity = 0.78

        modelRoot.name = "A2687_CHARGER_ROOT"
        screenArtworkTargets.removeAll(keepingCapacity: true)
        topGlassTargets.removeAll(keepingCapacity: true)
        configureModel(modelRoot)
        updateScreenArtwork()
        scene.rootNode.addChildNode(modelRoot)
        self.modelRoot = modelRoot

        configureLighting(in: scene)
        configureCamera(in: scene)
        cables = ChargerSceneMetrics.ports.enumerated().map { index, spec in
            createCable(index: index, spec: spec, in: scene)
        }
        addPortHitTargets(to: scene)

        // Keep the renderer hidden until preparation finishes. Hiding at the
        // NSView level rather than hiding `modelRoot` matters twice over:
        // SceneKit can skip warming a hidden node subtree during `prepare`,
        // which would bring the first-drag hitch back, and the cables/halos
        // hang directly off `scene.rootNode`, so a node-level hide would let
        // the on-demand renderer present floating leads without the charger
        // body (the loading badge is a small capsule, not an opaque cover).
        // While the view is hidden no frame is presented at all, so GLTFKit's
        // stock "160 W" screen artwork can never reach the screen either.
        sceneView.isHidden = true
        sceneView.scene = scene
        sceneView.pointOfView = cameraNode
        sceneView.isPlaying = false
        modelLoaded = true
        applyCamera()

        if let state = renderState {
            modelRoot.opacity = state.active ? 1 : 0.48
            updateCables(from: nil, to: state)
            refreshOverlays()
            firstTelemetry = false
        }
        // After refreshOverlays, never before it: the port pills are subviews of
        // this container rather than of the scene view, and refreshOverlays
        // reveals every on-screen pill unconditionally. Hiding them first left
        // three labels floating over an empty stage for the whole prepare
        // window — an artifact the synchronous prepare could not produce.
        portButtons.forEach { $0.isHidden = true }

        // Compile shaders and upload geometry before exposing the stage. This
        // trades a short loading badge for a hitch-free first drag. The
        // completion-handler form keeps the ~120 ms GPU upload off the main
        // thread; the synchronous variant parked the main thread in
        // `waitUntilCompleted` on every re-entry into the dashboard tab.
        let token = loadToken
        sceneView.prepare([scene]) { [weak self] _ in
            // SceneKit does not document the completion queue, and publishing
            // load state synchronously from a representable pass is the hazard
            // documented on `onCameraCapture` above — always hop through main.
            DispatchQueue.main.async {
                guard let self, self.loadToken == token, self.modelLoaded else { return }
                // Re-assert the Charker-owned replacement nodes after SceneKit
                // has compiled the source scene. The loader-owned originals
                // remain hidden.
                self.updateTopGlassMaterials()
                // GLTFKit resolves texture-backed material properties during
                // prepare. Commit the chosen screen before revealing so the
                // source GLB's static 160 W artwork cannot be restored over
                // the selected idle image.
                self.updateScreenArtwork()
                self.sceneView.isHidden = false
                self.refreshOverlays()
                // In on-demand mode AppKit may coalesce the first invalidation
                // until a later pointer event. Briefly drive the renderer so
                // Metal presents a real frame, then return to on-demand
                // drawing.
                self.playScene(for: 0.10)
                self.requestSceneDisplay()
                // The delayed re-assert below guards a timing-based GLTFKit
                // texture race (the loader's late texture callback), not a
                // prepare-variant artifact; it stays even with async prepare.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self, self.loadToken == token, self.modelLoaded else { return }
                    self.updateTopGlassMaterials()
                    self.updateScreenArtwork()
                    self.onLoadStateChange?(.ready)
                }
            }
        }
    }

    private func configureModel(_ root: SCNNode) {
        var sourceScreenNodes: [SCNNode] = []
        var sourceTopGlassNodes: [SCNNode] = []
        root.enumerateChildNodes { node, _ in
            node.categoryBitMask = 1
            node.castsShadow = false
            guard let geometry = node.geometry else { return }
            let isScreenArtwork = node.name?.contains(ChargerSceneMetrics.screenArtworkNodeName) == true
                || geometry.materials.contains {
                    $0.name?.contains(ChargerSceneMetrics.screenArtworkNodeName) == true
                }
            let isTopGlass = node.name == ChargerSceneMetrics.topGlassNodeName
                || geometry.materials.contains {
                    $0.name?.contains(ChargerSceneMetrics.topGlassMaterialName) == true
                }
            let materials = geometry.materials.compactMap { $0.copy() as? SCNMaterial }
            if !materials.isEmpty {
                geometry.materials = materials
            }
            for material in geometry.materials {
                material.isDoubleSided = true
                if isScreenArtwork {
                    configureScreenArtworkMaterial(material)
                } else if isTopGlass {
                    configureTopGlassMaterial(material)
                } else {
                    material.lightingModel = .physicallyBased
                }
            }
            if isScreenArtwork {
                sourceScreenNodes.append(node)
            }
            if isTopGlass {
                sourceTopGlassNodes.append(node)
            }
        }

        // The GLB loader can finish material work after the first visible
        // frame. Own a geometry/material copy instead of repeatedly painting
        // the loader's node; otherwise the grey source cover can return later.
        for sourceNode in sourceTopGlassNodes {
            guard let parent = sourceNode.parent,
                  let sourceGeometry = sourceNode.geometry,
                  let replacementGeometry = sourceGeometry.copy() as? SCNGeometry else { continue }
            let materials = sourceGeometry.materials.compactMap { material -> SCNMaterial? in
                guard let copy = material.copy() as? SCNMaterial else { return nil }
                configureTopGlassMaterial(copy)
                return copy
            }
            guard !materials.isEmpty else { continue }

            replacementGeometry.materials = materials
            let replacementNode = SCNNode(geometry: replacementGeometry)
            replacementNode.name = "CHARKER_MODEL_TOP_GLASS"
            replacementNode.simdTransform = sourceNode.simdTransform
            replacementNode.pivot = sourceNode.pivot
            replacementNode.categoryBitMask = sourceNode.categoryBitMask
            replacementNode.castsShadow = false
            replacementNode.renderingOrder = sourceNode.renderingOrder

            sourceNode.isHidden = true
            parent.addChildNode(replacementNode)
            topGlassTargets.append(TopGlassTarget(
                sourceNode: sourceNode,
                replacementNode: replacementNode
            ))
        }

        // GLTFKit finishes decoding embedded textures asynchronously and may
        // write the source GLB's 160 W image back after SceneKit preparation.
        // Hide that loader-owned node and render a geometry copy whose material
        // graph belongs exclusively to Charker. Runtime screen changes then
        // cannot race the loader's delayed texture callback.
        for sourceNode in sourceScreenNodes {
            guard let parent = sourceNode.parent,
                  let sourceGeometry = sourceNode.geometry,
                  let replacementGeometry = sourceGeometry.copy() as? SCNGeometry else { continue }
            let templates = sourceGeometry.materials.compactMap { material -> SCNMaterial? in
                guard let copy = material.copy() as? SCNMaterial else { return nil }
                configureScreenArtworkMaterial(copy)
                return copy
            }
            guard !templates.isEmpty else { continue }

            replacementGeometry.materials = templates
            let replacementNode = SCNNode(geometry: replacementGeometry)
            replacementNode.name = "CHARKER_MODEL_SCREEN_ARTWORK"
            replacementNode.simdTransform = sourceNode.simdTransform
            replacementNode.pivot = sourceNode.pivot
            replacementNode.categoryBitMask = sourceNode.categoryBitMask
            replacementNode.castsShadow = false
            replacementNode.renderingOrder = 20

            sourceNode.isHidden = true
            parent.addChildNode(replacementNode)
            screenArtworkTargets.append(ScreenArtworkTarget(
                sourceNode: sourceNode,
                replacementNode: replacementNode,
                materialTemplates: templates,
                baseScale: replacementNode.simdScale,
                basePosition: replacementNode.simdPosition,
                baseOrientation: replacementNode.simdOrientation
            ))
        }
    }

    private func updateScreenArtwork() {
        guard !screenArtworkTargets.isEmpty else { return }
        let image = screenStyle == .custom
            ? (customScreenImage ?? ModelScreenArtwork.ankerPrimeTexture)
            : ModelScreenArtwork.ankerPrimeTexture
        for target in screenArtworkTargets {
            target.sourceNode.isHidden = true
            target.replacementNode.isHidden = false
            let scale = screenStyle == .custom
                ? ChargerSceneMetrics.customScreenArtworkScale
                : 1
            target.replacementNode.simdScale = target.baseScale * scale
            target.replacementNode.simdPosition = target.basePosition
            if screenStyle == .custom {
                target.replacementNode.simdPosition += simd_act(
                    target.baseOrientation,
                    ChargerSceneMetrics.customScreenArtworkOffset
                )
            }
            let materials = target.materialTemplates.compactMap { template -> SCNMaterial? in
                guard let material = template.copy() as? SCNMaterial else { return nil }
                configureScreenArtworkMaterial(material)
                material.diffuse.contents = image
                material.emission.contents = NSColor.black
                material.multiply.contents = NSColor.white
                if screenStyle == .ankerPrime {
                    // Add only the cyan logo pixels. The cleared canvas adds
                    // nothing, leaving the uninterrupted cover glass visible.
                    material.blendMode = .add
                    material.transparent.contents = NSColor.white
                } else {
                    // A custom photo is a real illuminated square and therefore
                    // keeps its alpha mask and the requested black surround.
                    material.blendMode = .alpha
                    material.transparent.contents = image
                }
                material.transparencyMode = .aOne
                material.transparency = 1
                return material
            }
            if !materials.isEmpty {
                target.replacementNode.geometry?.materials = materials
            }
        }
        requestSceneDisplay()
    }

    private func configureScreenArtworkMaterial(_ material: SCNMaterial) {
        material.isDoubleSided = true
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.mipFilter = .linear
        material.emission.wrapS = .clamp
        material.emission.wrapT = .clamp
        material.emission.magnificationFilter = .linear
        material.emission.minificationFilter = .linear
        material.emission.mipFilter = .linear
        material.transparent.wrapS = .clamp
        material.transparent.wrapT = .clamp
        material.transparent.magnificationFilter = .linear
        material.transparent.minificationFilter = .linear
        material.transparent.mipFilter = .linear
    }

    /// The real A2687 has one continuous black glass cover: the LCD and button
    /// sit below it instead of reading as separate inserts. A tightly focused
    /// Blinn highlight is intentional here: the broad HDR reflection from the
    /// source PBR material lifted the whole panel to grey, while the physical
    /// part stays optically black and only catches narrow glossy highlights.
    private func configureTopGlassMaterial(_ material: SCNMaterial) {
        material.isDoubleSided = true
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor(
            srgbRed: 0.006,
            green: 0.007,
            blue: 0.010,
            alpha: 1
        )
        material.ambient.contents = NSColor(deviceWhite: 0.002, alpha: 1)
        material.locksAmbientWithDiffuse = true
        material.specular.contents = NSColor(deviceWhite: 0.72, alpha: 1)
        material.shininess = 0.92
        material.reflective.contents = NSColor.black
        material.fresnelExponent = 1.7
        material.normal.contents = nil
        material.emission.contents = NSColor.black
        material.transparent.contents = NSColor.white
        material.transparencyMode = .aOne
        material.blendMode = .replace
        material.transparency = 1
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
    }

    private func updateTopGlassMaterials() {
        for target in topGlassTargets {
            target.sourceNode.isHidden = true
            target.replacementNode.isHidden = false
            guard let geometry = target.replacementNode.geometry else { continue }
            for material in geometry.materials {
                configureTopGlassMaterial(material)
            }
        }
    }

    private func configureLighting(in scene: SCNScene) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(srgbRed: 0.73, green: 0.78, blue: 0.84, alpha: 1)
        ambient.intensity = 42
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.color = NSColor(srgbRed: 0.92, green: 0.95, blue: 1, alpha: 1)
        key.intensity = 220
        key.temperature = 6_100
        key.castsShadow = false
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.72, -0.58, -0.18)
        scene.rootNode.addChildNode(keyNode)
    }

    private func configureCamera(in scene: SCNScene) {
        let camera = SCNCamera()
        camera.fieldOfView = 29
        camera.zNear = 0.005
        camera.zFar = 2
        camera.wantsHDR = true
        // SceneKit enables eye-style exposure adaptation by default. It made
        // the silver shell turn white after zooming close and then resetting.
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.48
        camera.bloomIntensity = 0
        cameraNode.camera = camera
        cameraNode.name = "A2687_CAMERA"
        scene.rootNode.addChildNode(cameraNode)
    }

    private func addPortHitTargets(to scene: SCNScene) {
        for (index, spec) in ChargerSceneMetrics.ports.enumerated() {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.clear
            material.transparency = 0.001
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false

            let geometry = SCNBox(
                width: 0.016,
                height: 0.010,
                length: 0.004,
                chamferRadius: 0.0012
            )
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.name = "A2687_PORT_HIT_\(index)"
            node.categoryBitMask = ChargerSceneMetrics.portHitCategory
            node.simdPosition = spec.position + spec.normal * 0.0015
            node.simdOrientation = simd_quatf(from: SIMD3(0, 0, 1), to: spec.normal)
            scene.rootNode.addChildNode(node)
        }
    }

    private func createCable(
        index: Int,
        spec: ChargerPortSpec,
        in scene: SCNScene
    ) -> NativeCableVisual {
        let group = SCNNode()
        group.name = "CABLE_C\(index + 1)_ROOT"
        group.simdPosition = spec.position + spec.normal * ChargerSceneMetrics.cableApproachOffset
        group.simdOrientation = simd_quatf(from: SIMD3(0, 0, 1), to: spec.normal)
        group.opacity = 0
        group.isHidden = true

        let shellMaterial = pbrMaterial(
            color: NSColor(srgbRed: 0.68, green: 0.71, blue: 0.74, alpha: 1),
            metalness: 0.82,
            roughness: 0.24
        )
        let insetMaterial = pbrMaterial(
            color: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1),
            metalness: 0.05,
            roughness: 0.60
        )
        let housingValues: [(CGFloat, CGFloat, CGFloat)] = [
            (0.85, 0.87, 0.88), (0.81, 0.84, 0.85), (0.77, 0.80, 0.82),
        ]
        let housingValue = housingValues[index]
        let housingMaterial = pbrMaterial(
            color: NSColor(
                srgbRed: housingValue.0,
                green: housingValue.1,
                blue: housingValue.2,
                alpha: 1
            ),
            metalness: 0.02,
            roughness: 0.58,
            clearCoat: 0.22,
            clearCoatRoughness: 0.46
        )
        let cableValues: [(CGFloat, CGFloat, CGFloat)] = [
            (0.80, 0.82, 0.84), (0.76, 0.80, 0.82), (0.73, 0.77, 0.79),
        ]
        let cableValue = cableValues[index]
        let cableMaterial = pbrMaterial(
            color: NSColor(
                srgbRed: cableValue.0,
                green: cableValue.1,
                blue: cableValue.2,
                alpha: 1
            ),
            metalness: 0,
            roughness: 0.78
        )

        let metalShell = SCNNode(geometry: SCNBox(
            width: 0.00825,
            height: 0.00285,
            length: 0.0065,
            chamferRadius: 0.00122
        ))
        metalShell.geometry?.materials = [shellMaterial]
        metalShell.position.z = 0.00325
        group.addChildNode(metalShell)

        let inset = SCNNode(geometry: SCNBox(
            width: 0.0064,
            height: 0.00135,
            length: 0.00038,
            chamferRadius: 0.00055
        ))
        inset.geometry?.materials = [insetMaterial]
        inset.position.z = 0.00666
        group.addChildNode(inset)

        let housing = SCNNode(geometry: SCNBox(
            width: 0.0112,
            height: 0.0064,
            length: 0.0114,
            chamferRadius: 0.00175
        ))
        housing.geometry?.materials = [housingMaterial]
        housing.position.z = 0.0116
        group.addChildNode(housing)

        let relief = SCNNode(geometry: SCNCylinder(
            radius: 0.0029,
            height: 0.0082
        ))
        relief.geometry?.materials = [housingMaterial]
        relief.eulerAngles.x = .pi / 2
        relief.position.z = 0.0208
        group.addChildNode(relief)

        // Cable control points are specified in world space for product-design
        // tuning, then converted into the plug's local space. Treating a world
        // endpoint as local made the lead swing away from its port at oblique
        // camera angles even though the plug itself was seated correctly.
        let inverseOrientation = group.simdOrientation.inverse
        let seatedPosition = spec.position
            + spec.normal * ChargerSceneMetrics.cableSeatedOffset
        let localEnd = inverseOrientation.act(spec.cableEnd - seatedPosition)
        let localDown = inverseOrientation.act(SIMD3<Float>(0, -1, 0))
        let localOut = SIMD3<Float>(0, 0, 1)
        let start = SIMD3<Float>(0, 0, 0.024)
        let curve = cubicBezierPoints(
            start: start,
            // Leave the strain relief along the port normal before gravity
            // takes over. The three endpoints fan left/centre/right and stay
            // in front of the charger, so oblique views no longer make the
            // leads merge or appear to pass through the shell.
            control1: start + localOut * 0.010 + localDown * 0.010,
            control2: localEnd + localOut * 0.002 - localDown * 0.026,
            end: localEnd,
            segments: 36
        )
        let tube = SCNNode(geometry: tubeGeometry(points: curve, radius: 0.00105, sides: 10))
        tube.geometry?.materials = [cableMaterial]
        group.addChildNode(tube)

        let haloMaterial = SCNMaterial()
        haloMaterial.lightingModel = .constant
        haloMaterial.diffuse.contents = NativeStagePalette.brandBlue
        haloMaterial.emission.contents = NativeStagePalette.brandBlue
        haloMaterial.blendMode = .add
        haloMaterial.writesToDepthBuffer = false
        haloMaterial.readsFromDepthBuffer = true

        let halo = SCNNode(geometry: SCNBox(
            width: 0.0102,
            height: 0.0046,
            length: 0.00055,
            chamferRadius: 0.00165
        ))
        halo.name = "CABLE_C\(index + 1)_PORT_HALO"
        halo.geometry?.materials = [haloMaterial]
        halo.simdPosition = spec.position + spec.normal * 0.0002
        halo.simdOrientation = group.simdOrientation
        halo.opacity = 0
        scene.rootNode.addChildNode(halo)

        scene.rootNode.addChildNode(group)
        return NativeCableVisual(
            group: group,
            halo: halo,
            spec: spec,
            targetAttached: false
        )
    }

    private func pbrMaterial(
        color: NSColor,
        metalness: CGFloat,
        roughness: CGFloat,
        clearCoat: CGFloat = 0,
        clearCoatRoughness: CGFloat = 0
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = metalness
        material.roughness.contents = roughness
        material.clearCoat.contents = clearCoat
        material.clearCoatRoughness.contents = clearCoatRoughness
        material.isDoubleSided = true
        return material
    }

    private func updateCables(
        from previous: NativeChargerRenderState?,
        to state: NativeChargerRenderState
    ) {
        for index in cables.indices {
            let port = state.ports[safe: index] ?? .init(
                watts: 0,
                lit: false,
                attached: nil,
                capability: nil
            )
            let oldPort = previous?.ports[safe: index]
            let attached = state.active && port.attached == true
            let focused = state.selectedPort == index
                || effectiveHighlightedPort(state: state) == index
            updateCable(
                cables[index],
                attached: attached,
                lit: state.active && port.lit,
                focused: focused,
                animate: !state.reduceMotion && !firstTelemetry && oldPort?.attached != port.attached
            )
        }
    }

    private func updateCable(
        _ cable: NativeCableVisual,
        attached: Bool,
        lit: Bool,
        focused: Bool,
        animate: Bool
    ) {
        let haloOpacity: CGFloat = attached ? (focused ? 0.14 : lit ? 0.10 : 0.025) : 0
        cable.halo.opacity = haloOpacity

        guard cable.targetAttached != attached else { return }
        cable.targetAttached = attached
        cable.group.removeAction(forKey: "attachment")

        let seated = cable.spec.position
            + cable.spec.normal * ChargerSceneMetrics.cableSeatedOffset
        let approach = cable.spec.position
            + cable.spec.normal * ChargerSceneMetrics.cableApproachOffset

        guard animate else {
            cable.group.removeAllActions()
            cable.group.simdPosition = attached ? seated : approach
            cable.group.opacity = attached ? 1 : 0
            cable.group.isHidden = !attached
            return
        }

        cable.group.isHidden = false
        let move = SCNAction.move(
            to: SCNVector3(attached ? seated : approach),
            duration: attached ? 0.28 : 0.20
        )
        move.timingMode = attached ? .easeOut : .easeIn
        let fade = SCNAction.fadeOpacity(
            to: attached ? 1 : 0,
            duration: attached ? 0.22 : 0.16
        )
        fade.timingMode = attached ? .easeOut : .easeIn
        let action = SCNAction.group([move, fade])
        cable.group.runAction(action, forKey: "attachment") { [weak self, weak cable] in
            DispatchQueue.main.async {
                if cable?.targetAttached == false { cable?.group.isHidden = true }
                self?.requestSceneDisplay()
            }
        }
        playScene(for: max(move.duration, fade.duration))
    }

    private func playScene(for duration: TimeInterval) {
        playbackGeneration += 1
        let generation = playbackGeneration
        sceneView.isPlaying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.08) { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            self.sceneView.isPlaying = false
            self.requestSceneDisplay()
        }
    }

    private func orbitCamera(deltaX: CGFloat, deltaY: CGFloat) {
        cancelCameraAnimation()
        orbit.theta -= Float(deltaX) * 0.34
        // AppKit reports positive drag deltas upward, so add the delta to keep
        // vertical orbiting aligned with the pointer's direction.
        orbit.phi = clamp(
            orbit.phi + Float(deltaY) * 0.34,
            ChargerSceneMetrics.minimumPolar,
            ChargerSceneMetrics.maximumPolar
        )
        applyCamera()
    }

    private func zoomCamera(amount: CGFloat) {
        cancelCameraAnimation()
        orbit.distance = clamp(
            orbit.distance * Float(exp(Double(amount))),
            ChargerSceneMetrics.minimumDistance,
            ChargerSceneMetrics.maximumDistance
        )
        applyCamera()
    }

    private func handle(_ command: NativeCameraCommand) -> Bool {
        cancelCameraAnimation()
        switch command {
        case .left: orbit.theta -= 4
        case .right: orbit.theta += 4
        case .up:
            orbit.phi = clamp(
                orbit.phi - 4,
                ChargerSceneMetrics.minimumPolar,
                ChargerSceneMetrics.maximumPolar
            )
        case .down:
            orbit.phi = clamp(
                orbit.phi + 4,
                ChargerSceneMetrics.minimumPolar,
                ChargerSceneMetrics.maximumPolar
            )
        case .zoomIn:
            orbit.distance = max(ChargerSceneMetrics.minimumDistance, orbit.distance / 1.12)
        case .zoomOut:
            orbit.distance = min(ChargerSceneMetrics.maximumDistance, orbit.distance * 1.12)
        }
        applyCamera()
        return true
    }

    private func animateCamera(
        to target: ChargerOrbit,
        duration: TimeInterval = ChargerSceneMetrics.cameraResetDuration
    ) {
        cancelCameraAnimation()

        guard modelLoaded,
              renderState?.reduceMotion != true,
              duration > 0 else {
            orbit = target
            applyCamera()
            return
        }

        let start = orbit
        var thetaDelta = (target.theta - start.theta).truncatingRemainder(dividingBy: 360)
        if thetaDelta > 180 { thetaDelta -= 360 }
        if thetaDelta < -180 { thetaDelta += 360 }
        let phiDelta = target.phi - start.phi
        let distanceDelta = target.distance - start.distance

        guard abs(thetaDelta) > 0.001
                || abs(phiDelta) > 0.001
                || abs(distanceDelta) > 0.000_01 else {
            orbit = target
            applyCamera()
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            if self.renderState?.reduceMotion == true {
                timer.invalidate()
                self.cameraAnimationTimer = nil
                self.orbit = target
                self.applyCamera()
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let progress = Float(min(1, max(0, elapsed / duration)))
            // Quintic smoothstep starts and ends at zero velocity, avoiding the
            // abrupt snap that a linear or one-sided easing produces.
            let eased = progress * progress * progress
                * (progress * (progress * 6 - 15) + 10)

            self.orbit = ChargerOrbit(
                theta: start.theta + thetaDelta * eased,
                phi: start.phi + phiDelta * eased,
                distance: start.distance + distanceDelta * eased
            )
            self.applyCamera()

            if progress >= 1 {
                timer.invalidate()
                self.cameraAnimationTimer = nil
                self.orbit = target
                self.applyCamera()
            }
        }
        cameraAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelCameraAnimation() {
        cameraAnimationTimer?.invalidate()
        cameraAnimationTimer = nil
    }

    private func applyCamera() {
        guard modelLoaded else { return }
        let polar = orbit.phi * .pi / 180
        let azimuth = orbit.theta * .pi / 180
        let offset = SIMD3<Float>(
            orbit.distance * sin(polar) * sin(azimuth),
            orbit.distance * cos(polar),
            orbit.distance * sin(polar) * cos(azimuth)
        )
        cameraNode.simdPosition = ChargerSceneMetrics.cameraTarget + offset
        cameraNode.look(
            at: SCNVector3(ChargerSceneMetrics.cameraTarget),
            up: SCNVector3(0, 1, 0),
            localFront: SCNVector3(0, 0, -1)
        )
        requestSceneDisplay()
        updateOverlayPositions()
    }

    private func requestSceneDisplay() {
        guard sceneView.bounds.width > 1, sceneView.bounds.height > 1 else { return }
        sceneView.setNeedsDisplay(sceneView.bounds)
    }

    private func portIndex(at point: NSPoint) -> Int? {
        guard modelLoaded else { return nil }
        let options: [SCNHitTestOption: Any] = [
            SCNHitTestOption.categoryBitMask: ChargerSceneMetrics.portHitCategory,
            SCNHitTestOption.firstFoundOnly: true,
            SCNHitTestOption.boundingBoxOnly: true,
        ]
        let hits = sceneView.hitTest(point, options: options)
        guard let name = hits.first?.node.name,
              let suffix = name.split(separator: "_").last,
              let index = Int(suffix),
              ChargerSceneMetrics.ports.indices.contains(index) else { return nil }
        return index
    }

    private func setPointerPort(_ index: Int?) {
        guard pointerPort != index else { return }
        pointerPort = index
        onPortHover?(index)
        if let state = renderState {
            updateCables(from: state, to: state)
            refreshOverlays()
            requestSceneDisplay()
        }
    }

    private func effectiveHighlightedPort(state: NativeChargerRenderState) -> Int? {
        pointerPort ?? state.highlightedPort
    }

    @objc private func portButtonPressed(_ sender: NativePortButton) {
        onPortTap?(sender.portIndex)
    }

    private func refreshOverlays() {
        guard modelLoaded, let state = renderState else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let highlighted = effectiveHighlightedPort(state: state)
        for index in portButtons.indices {
            let port = state.ports[safe: index] ?? .init(
                watts: 0,
                lit: false,
                attached: nil,
                capability: nil
            )
            portButtons[index].update(
                port: port,
                active: state.active,
                focused: state.selectedPort == index || highlighted == index,
                selected: state.selectedPort == index,
                dark: dark
            )
        }
        updateOverlayPositions()
    }

    private func updateOverlayPositions() {
        guard modelLoaded, sceneView.bounds.width > 1, sceneView.bounds.height > 1 else { return }
        for index in portButtons.indices {
            position(
                portButtons[index],
                at: ChargerSceneMetrics.ports[index].position,
                normal: ChargerSceneMetrics.ports[index].normal,
                leading: true,
                yOffset: 0
            )
        }
    }

    private func position(
        _ view: NSView,
        at point: SIMD3<Float>,
        normal: SIMD3<Float>,
        leading: Bool,
        yOffset: CGFloat
    ) {
        let toCamera = cameraNode.simdWorldPosition - point
        let frontFacing = simd_dot(toCamera, normal) > 0
        let projected = sceneView.projectPoint(SCNVector3(point))
        let visible = frontFacing
            && projected.z >= 0 && projected.z <= 1
            && CGFloat(projected.x) >= -40 && CGFloat(projected.x) <= bounds.width + 40
            && CGFloat(projected.y) >= -30 && CGFloat(projected.y) <= bounds.height + 30
        view.isHidden = !visible
        guard visible else { return }

        let size = view.frame.size
        let x = CGFloat(projected.x)
        let y = CGFloat(projected.y) + yOffset
        view.frame.origin = NSPoint(
            x: leading ? x - size.width - 8 : x - size.width / 2,
            y: y - size.height / 2
        )
    }
}

private final class NativeCableVisual {
    let group: SCNNode
    let halo: SCNNode
    let spec: ChargerPortSpec
    var targetAttached: Bool

    init(group: SCNNode, halo: SCNNode, spec: ChargerPortSpec, targetAttached: Bool) {
        self.group = group
        self.halo = halo
        self.spec = spec
        self.targetAttached = targetAttached
    }
}

private enum NativeCameraCommand {
    case left
    case right
    case up
    case down
    case zoomIn
    case zoomOut
}

/// The only class that receives high-frequency pointer events. It changes the
/// camera node directly and keeps one cursor rect for its full lifetime.
private final class NativeOrbitSceneView: SCNView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onHoverPoint: ((NSPoint?) -> Void)?
    var onClickPoint: ((NSPoint) -> Void)?
    var onKeyCommand: ((NativeCameraCommand) -> Bool)?

    private var trackingArea: NSTrackingArea?
    private var lastDragPoint: NSPoint?
    private var dragDistance: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        onHoverPoint?(nil)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.openHand.set()
        onHoverPoint?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        NSCursor.openHand.set()
        lastDragPoint = convert(event.locationInWindow, from: nil)
        dragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.openHand.set()
        let point = convert(event.locationInWindow, from: nil)
        guard let lastDragPoint else {
            self.lastDragPoint = point
            return
        }
        let deltaX = point.x - lastDragPoint.x
        let deltaY = point.y - lastDragPoint.y
        dragDistance += hypot(deltaX, deltaY)
        self.lastDragPoint = point
        onOrbit?(deltaX, deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        let point = convert(event.locationInWindow, from: nil)
        if dragDistance < 3 { onClickPoint?(point) }
        lastDragPoint = nil
        dragDistance = 0
        onHoverPoint?(point)
    }

    override func scrollWheel(with event: NSEvent) {
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.0065 : 0.030
        onZoom?(-event.scrollingDeltaY * scale)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(-event.magnification * 1.5)
    }

    override func keyDown(with event: NSEvent) {
        let command: NativeCameraCommand?
        switch event.keyCode {
        case 123: command = .left
        case 124: command = .right
        case 125: command = .down
        case 126: command = .up
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=": command = .zoomIn
            case "-": command = .zoomOut
            default: command = nil
            }
        }
        if let command, onKeyCommand?(command) == true { return }
        super.keyDown(with: event)
    }
}

private final class NativePortButton: NSButton {
    let portIndex: Int
    var onHover: ((Int, Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    init(portIndex: Int) {
        self.portIndex = portIndex
        super.init(frame: NSRect(x: 0, y: 0, width: 76, height: 22))
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
        onHover?(portIndex, true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(portIndex, false)
    }

    func update(
        port: NativeChargerRenderState.Port,
        active: Bool,
        focused: Bool,
        selected: Bool,
        dark: Bool
    ) {
        let status: String
        if active && port.lit {
            status = L10n.format("%.1f W", port.watts)
        } else if active && port.attached == true {
            status = L10n.text("已接线")
        } else if active && port.attached == false {
            status = L10n.text("未接线")
        } else {
            status = "—"
        }

        let textColor = (active && port.lit) || focused
            ? NativeStagePalette.primaryText(dark: dark)
            : NativeStagePalette.secondaryText(dark: dark)
        let result = NSMutableAttributedString(
            string: "● ",
            attributes: [
                .foregroundColor: active && port.lit
                    ? NativeStagePalette.brandBlue
                    : NativeStagePalette.idleDot(dark: dark),
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            ]
        )
        result.append(NSAttributedString(
            string: "C\(portIndex + 1)  \(status)",
            attributes: [
                .foregroundColor: textColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            ]
        ))
        attributedTitle = result

        let textSize = result.size()
        frame.size = NSSize(width: ceil(textSize.width) + 14, height: 22)
        layer?.backgroundColor = NativeStagePalette.overlayBackground(dark: dark).cgColor
        layer?.borderColor = (
            focused ? NativeStagePalette.brandBlue.withAlphaComponent(0.68)
                : NativeStagePalette.overlayStroke(dark: dark)
        ).cgColor
        alphaValue = focused ? 1 : 0.78

        let cable = port.capability.map { L10n.format("，%@ 线", $0) } ?? ""
        let power = active && port.lit ? L10n.format("，%@", status) : ""
        let state = port.attached == true ? L10n.format("已连接%@%@", cable, power)
            : port.attached == false ? L10n.text("未接线") : L10n.text("线缆状态未知")
        setAccessibilityLabel(L10n.format("选择 C%d 端口，%@", portIndex + 1, state))
        setAccessibilityValue(L10n.text(selected ? "已选择" : "未选择"))
    }
}

private enum NativeStagePalette {
    static let brandBlue = NSColor(srgbRed: 0, green: 167 / 255, blue: 225 / 255, alpha: 1)

    static func primaryText(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 243 / 255, green: 245 / 255, blue: 248 / 255, alpha: 0.96)
            : NSColor(srgbRed: 14 / 255, green: 17 / 255, blue: 22 / 255, alpha: 0.96)
    }

    static func secondaryText(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 154 / 255, green: 163 / 255, blue: 178 / 255, alpha: 0.88)
            : NSColor(srgbRed: 90 / 255, green: 100 / 255, blue: 114 / 255, alpha: 0.90)
    }

    static func idleDot(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 123 / 255, green: 132 / 255, blue: 148 / 255, alpha: 0.72)
            : NSColor(srgbRed: 104 / 255, green: 114 / 255, blue: 128 / 255, alpha: 0.72)
    }

    static func overlayBackground(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 16 / 255, green: 18 / 255, blue: 22 / 255, alpha: 0.90)
            : NSColor(srgbRed: 247 / 255, green: 248 / 255, blue: 250 / 255, alpha: 0.92)
    }

    static func overlayStroke(dark: Bool) -> NSColor {
        dark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor(srgbRed: 14 / 255, green: 17 / 255, blue: 22 / 255, alpha: 0.12)
    }
}

private struct NativeModel3DResources {
    let modelURL: URL
    let environmentURL: URL

    static var current: NativeModel3DResources? {
        for directory in candidateDirectories {
            let model = directory.appendingPathComponent("A2687.glb")
            let environment = directory.appendingPathComponent("A2687.hdr")
            if FileManager.default.fileExists(atPath: model.path),
               FileManager.default.fileExists(atPath: environment.path) {
                return NativeModel3DResources(modelURL: model, environmentURL: environment)
            }
        }
        return nil
    }

    private static var candidateDirectories: [URL] {
        var directories: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL.appendingPathComponent("Model3D"))
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        directories.append(repository.appendingPathComponent("Resources/Model3D"))
        return directories
    }
}

private enum NativeChargerModelCache {
    private static let queue = DispatchQueue(
        label: "dev.charker.native-model-loader",
        qos: .userInitiated
    )
    private static var retainedAsset: GLTFAsset?
    private static var prototypeRoot: SCNNode?
    private static var environmentImage: CGImage?
    private static var environmentImageURL: URL?

    /// Decode the IBL environment once per app run. Handing SceneKit the HDR's
    /// URL makes it run the full ImageIO decode on every assignment; handing it
    /// the same decoded object lets repeat installs reuse SceneKit's texture
    /// cache instead. Decoded with float samples preserved so the Radiance HDR
    /// keeps its dynamic range (an 8-bit decode would flatten the lighting).
    /// Main-thread only, like `install(modelRoot:resources:)` that calls it.
    static func environmentContents(for url: URL) -> Any {
        if let environmentImage, environmentImageURL == url {
            return environmentImage
        }
        let options = [kCGImageSourceShouldAllowFloat: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            // Fall back to SceneKit's own URL decoding rather than losing IBL.
            return url
        }
        environmentImage = image
        environmentImageURL = url
        return image
    }

    static func load(url: URL, completion: @escaping (Result<SCNNode, Error>) -> Void) {
        queue.async {
            let result: Result<SCNNode, Error>
            if let prototypeRoot {
                result = .success(prototypeRoot.clone())
            } else {
                do {
                    let asset = try GLTFAsset(url: url, options: [:])
                    let source = SCNScene(gltfAsset: asset)
                    let root = SCNNode()
                    source.rootNode.childNodes.forEach { root.addChildNode($0) }
                    retainedAsset = asset
                    prototypeRoot = root
                    result = .success(root.clone())
                } catch {
                    result = .failure(error)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private func cubicBezierPoints(
    start: SIMD3<Float>,
    control1: SIMD3<Float>,
    control2: SIMD3<Float>,
    end: SIMD3<Float>,
    segments: Int
) -> [SIMD3<Float>] {
    (0...segments).map { index in
        let t = Float(index) / Float(segments)
        let u = 1 - t
        return start * (u * u * u)
            + control1 * (3 * u * u * t)
            + control2 * (3 * u * t * t)
            + end * (t * t * t)
    }
}

private func tubeGeometry(
    points: [SIMD3<Float>],
    radius: Float,
    sides: Int
) -> SCNGeometry {
    guard points.count >= 2, sides >= 3 else { return SCNGeometry() }

    var vertices: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var indices: [Int32] = []
    var transportedNormal = SIMD3<Float>(1, 0, 0)

    for index in points.indices {
        let previous = points[max(points.startIndex, index - 1)]
        let next = points[min(points.index(before: points.endIndex), index + 1)]
        let tangent = simd_normalize(next - previous)
        var normal = transportedNormal - tangent * simd_dot(transportedNormal, tangent)
        if simd_length_squared(normal) < 0.0001 {
            let reference = abs(tangent.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3(1, 0, 0)
            normal = simd_cross(reference, tangent)
        }
        normal = simd_normalize(normal)
        let binormal = simd_normalize(simd_cross(tangent, normal))
        transportedNormal = normal

        for side in 0..<sides {
            let angle = Float(side) / Float(sides) * 2 * .pi
            let radial = normal * cos(angle) + binormal * sin(angle)
            vertices.append(SCNVector3(points[index] + radial * radius))
            normals.append(SCNVector3(radial))
        }
    }

    for ring in 0..<(points.count - 1) {
        for side in 0..<sides {
            let nextSide = (side + 1) % sides
            let a = Int32(ring * sides + side)
            let b = Int32((ring + 1) * sides + side)
            let c = Int32((ring + 1) * sides + nextSide)
            let d = Int32(ring * sides + nextSide)
            indices.append(contentsOf: [a, b, c, a, c, d])
        }
    }

    let vertexSource = SCNGeometrySource(vertices: vertices)
    let normalSource = SCNGeometrySource(normals: normals)
    let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
    return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
}

private func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(upper, max(lower, value))
}

private extension SCNVector3 {
    init(_ value: SIMD3<Float>) {
        self.init(value.x, value.y, value.z)
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
