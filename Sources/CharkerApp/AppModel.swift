import A2687Protocol
import AppKit
import CharkerCore
import Combine
import Foundation
import ServiceManagement

/// Main-actor façade over ``ChargerSession`` for the UI layer.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = SessionSnapshot()
    @Published var preferences: Preferences {
        didSet { preferencesChanged(from: oldValue) }
    }
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    @Published private(set) var lastActionMessage: String?
    /// Accepted charger-side auto-off commands that have not reached their local
    /// projected deadline. Persistent because the charger keeps counting while
    /// Charker is hidden, disconnected or relaunched.
    @Published private(set) var portShutdownSchedules: [PortShutdownSchedule]
    @Published private(set) var isSigningIn = false
    @Published private(set) var signInError: String?
    @Published private(set) var accountNickname: String?
    @Published private(set) var energyHistory: EnergyHistory
    @Published private(set) var demoEnergyHistory = EnergyHistory()
    @Published private(set) var energyHistoryWarning: String?
    @Published private(set) var modelScreenArtworks = ModelScreenArtworkStore.loadArtworks()
    @Published private(set) var modelScreenArtworkRevision = 0
    @Published private(set) var modelScreenArtworkError: String?
    /// The 同步屏保 push, as the UI has to see it. See ``CoverPushState``.
    @Published private(set) var coverPush = CoverPushState()
    /// The charging-mode switch, as the settings card has to see it — including
    /// the outcome that is neither success nor failure. See
    /// ``ChargingModeChange``.
    @Published private(set) var chargingModeChange: ChargingModeChange?
    /// One of the five display-setting writes confirmed on firmware v0.0.5.2.
    /// Kept separate from charging mode because its verification deliberately
    /// crosses a reconnect.
    @Published private(set) var chargerSettingChange: ChargerSettingChange?
    /// Custom screens whose pixels have been written into the charger.
    ///
    /// The crop/vignette editor has to know which tier an edit belongs to.
    /// Re-cropping or re-tinting a screen that only dresses the 3D model costs
    /// nothing; doing it to a screen that is already inside the charger leaves
    /// the charger showing the *old* pixels until another push — and every push
    /// spends one of the four device slots, which no command frees. That is a
    /// warning worth showing, and a warning worth *not* showing to someone who
    /// has never pushed anything.
    ///
    /// ``coverPush`` cannot answer the question: it is cleared the moment the
    /// result card is dismissed, while the pixels stay in the charger for good.
    ///
    /// Persisted — the earlier argument for keeping it in memory ("after a
    /// relaunch Charker does not know what is resident") answered a question the
    /// warning never asks. What no BLE command can tell us is whether that copy
    /// is still one of the four covers; only the displayed one can be read back.
    /// The warning claims something else entirely: 「这张我推过，想让充电器跟着改
    /// 就得再推一次，再推就再占一格」— three facts about what *this Mac* did, no
    /// less certain tomorrow than today. Kept in memory the set was empty on the
    /// most ordinary path there is — push today, quit, come back tomorrow to
    /// change the vignette — so the one edit that really does cost a slot was
    /// exactly the edit that got no warning.
    @Published private(set) var coverSyncedSlots: Set<Int> = AppModel.loadCoverSyncedSlots()
    @Published var selectedSection: Section = .dashboard {
        didSet {
            guard selectedSection != oldValue else { return }
            preferences.lastSection = selectedSection.rawValue
        }
    }

    /// The overview chart's series, thinned once per publish.
    ///
    /// The plot is roughly 700 pt wide and the history holds 600 readings, so
    /// most marks land within a pixel of their neighbour while Swift Charts
    /// still resolves every one of them — measured at ~20% of the main thread
    /// on a session that had filled the buffer.
    private(set) var plottedHistory: [PowerSample] = []

    /// True once the dashboard has played its entrance once this app run.
    /// Lives here, not in view @State, so revisiting the tab does not replay it.
    private(set) var dashboardHasEntered = false
    func markDashboardEntered() { dashboardHasEntered = true }

    var selectedModelScreenArtwork: ModelScreenArtworkItem? {
        guard preferences.modelScreenStyle == .custom else { return nil }
        return modelScreenArtworks.first { $0.id == preferences.modelScreenCustomSlot }
    }

    var modelScreenCustomImage: NSImage? {
        selectedModelScreenArtwork?.textureImage
    }

    /// Set by RootView from `@Environment(\.openWindow)`: the supported way to
    /// materialise the Window scene again after the user closed it.
    var openMainWindowAction: (() -> Void)?

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case dashboard, energy, devices, menuBar, advanced, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dashboard: return L10n.text("总览")
            case .energy: return L10n.text("能耗记录")
            case .devices: return L10n.text("设备与连接")
            case .menuBar: return L10n.text("菜单栏")
            case .advanced: return L10n.text("高级")
            case .about: return L10n.text("关于")
            }
        }

        var symbol: String {
            switch self {
            case .dashboard: return "bolt.fill"
            case .energy: return "chart.bar.xaxis"
            case .devices: return "antenna.radiowaves.left.and.right"
            case .menuBar: return "menubar.rectangle"
            case .advanced: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }
    }

    private let store = PreferencesStore()
    private let energyHistoryStore: EnergyHistoryStore
    private let portShutdownScheduleStore: PortShutdownScheduleStore
    private let fileLog = FileLog()
    private lazy var diagnostics = DiagnosticsLog(mirror: fileLog)
    private var session: ChargerSession?
    private var updatesTask: Task<Void, Never>?
    private var messageClearTask: Task<Void, Never>?
    private var portShutdownExpiryTasks: [String: Task<Void, Never>] = [:]
    private var energySaveTask: Task<Void, Never>?
    private var lastRecordedEnergyAt: Date?
    /// The running cover push. Held so the card's 取消 can cancel it: the state
    /// machine watches `Task.isCancelled` at every slice boundary, and its own
    /// `cancel()` is not reachable from here — ``ChargerSession/pushCover`` owns
    /// the ``CoverTransferSession`` it builds.
    private var coverPushTask: Task<Void, Never>?
    /// The reference the last push used, so a failed *selection* can be retried
    /// with one cheap frame instead of re-uploading 24 KB of pixels.
    private var lastCoverReference: CoverImageReference?
    /// When the last progress frame was published; see ``noteCoverProgress``.
    private var lastCoverProgressPublish: ContinuousClock.Instant?
    /// Retires the charging-mode note once it has had time to be read. Held so a
    /// second switch is not un-noted by the first one's countdown.
    private var chargingModeClearTask: Task<Void, Never>?
    private var chargerSettingClearTask: Task<Void, Never>?
    private var chargerSettingVerificationTask: Task<Void, Never>?
    private var isRunning = false
    private var isApplyingLoginItem = false
    /// When demo mode hands back to a first-time real-device session, open that
    /// new session as a picker instead of letting it auto-attach to whichever
    /// matching advertisement happens to arrive first.
    private var browseAfterNextSessionBuild = false
    /// When the current connection reached `.monitoring`. Survives short
    /// reconnects; cleared when the session starts over from scratch.
    private(set) var connectedAt: Date?

    init() {
        let energyHistoryStore = EnergyHistoryStore()
        let portShutdownScheduleStore = PortShutdownScheduleStore()
        let historyLoad = energyHistoryStore.load()
        self.energyHistoryStore = energyHistoryStore
        self.portShutdownScheduleStore = portShutdownScheduleStore
        energyHistory = historyLoad.history
        energyHistoryWarning = historyLoad.warning
        portShutdownSchedules = portShutdownScheduleStore.load()
        preferences = store.load()
        if preferences.modelScreenStyle == .custom,
           !modelScreenArtworks.contains(where: {
               $0.id == preferences.modelScreenCustomSlot
           }) {
            if let first = modelScreenArtworks.first {
                preferences.modelScreenCustomSlot = first.id
            } else {
                preferences.modelScreenStyle = .ankerPrime
            }
        }
        selectedSection = Section(rawValue: preferences.lastSection) ?? .dashboard
        diagnostics.captureRawPayloads = preferences.captureRawPayloads
        loginItemStatus = SMAppService.mainApp.status
        applyAppearance()
    }

    /// Forces the whole app (windows and popover alike) into the chosen
    /// appearance; "system" hands control back to macOS.
    private func applyAppearance() {
        switch preferences.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshPortShutdownSchedules()
        buildSession()
    }

    func stop() {
        isRunning = false
        finishEnergyObservation()
        // A push outlives the session it was writing through otherwise: the task
        // holds the actor strongly and would keep pumping slices into a stopped
        // link for another minute.
        coverPushTask?.cancel()
        noteChargingModeChange(nil, clearAfter: nil)
        noteChargerSettingChange(nil, clearAfter: nil)
        updatesTask?.cancel()
        updatesTask = nil
        let session = self.session
        self.session = nil
        Task { await session?.stop() }
    }

    /// Awaited teardown for app termination: gives the BLE goodbye a real chance
    /// to run (the charger stops advertising while a link lingers), capped so
    /// quitting can never hang.
    func shutdown() async {
        isRunning = false
        finishEnergyObservation()
        coverPushTask?.cancel()
        updatesTask?.cancel()
        updatesTask = nil
        let session = self.session
        self.session = nil
        guard let session else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await session.stop() }
            group.addTask { try? await Task.sleep(for: .seconds(1.5)) }
            await group.next()
            group.cancelAll()
        }
    }

    func reconnect() {
        setActionMessage(nil)
        guard let session else { return }
        Task { await session.reconnectNow() }
    }

    /// Whether this install has a real charger it can reconnect to quickly.
    /// The simulated peripheral is deliberately never stored here.
    var hasRememberedCharger: Bool { store.peripheralID != nil }

    /// Makes discovery an explicit destination. Entering the picker also turns
    /// off transport auto-connect, so a first-time user chooses the charger
    /// rather than silently taking the first matching device in a busy room.
    func openDevicePicker() {
        guard !preferences.demoMode else {
            exitDemoMode()
            return
        }
        selectedSection = .devices
        browse()
    }

    /// Starts the existing protocol simulator as a first-class product mode.
    /// Its energy history and peripheral identity are already isolated from the
    /// real charger; the navigation here only makes that boundary discoverable.
    func enterDemoMode() {
        guard !preferences.demoMode else {
            selectedSection = .dashboard
            return
        }
        var updated = preferences
        updated.demoMode = true
        preferences = updated
        selectedSection = .dashboard
    }

    /// Leaves the simulator and returns to the real-device connection flow.
    /// A remembered charger keeps its normal fast reconnect; a new user lands
    /// in manual browsing so the page and radio remain in sync.
    func exitDemoMode() {
        guard preferences.demoMode else {
            openDevicePicker()
            return
        }
        browseAfterNextSessionBuild = !hasRememberedCharger
        var updated = preferences
        updated.demoMode = false
        preferences = updated
        selectedSection = .devices
    }

    /// Scans without auto-connecting so the picker can show everything nearby.
    func browse() {
        Task { await session?.browse() }
    }

    func connect(to identifier: UUID) {
        setActionMessage(nil)
        Task { await session?.connect(to: identifier) }
    }

    private func buildSession() {
        if session != nil { finishEnergyObservation() }
        // Toggling demo mode or the owner id rebuilds the session under a
        // running push. Stop it here rather than letting it discover the swap
        // as an acknowledgement timeout twenty slices later.
        coverPushTask?.cancel()
        // A note left over from the previous link describes a charger this
        // session may not even be talking to — and 「重新连接后再看这一行」 is
        // about to be answered by the reconnect happening right here.
        noteChargingModeChange(nil, clearAfter: nil)
        noteChargerSettingChange(nil, clearAfter: nil)
        updatesTask?.cancel()
        let previous = session
        Task { await previous?.stop() }
        connectedAt = nil
        lastRecordedEnergyAt = nil
        if preferences.demoMode { demoEnergyHistory = Self.makeDemoEnergyHistory() }

        let browseAfterStart = browseAfterNextSessionBuild
        browseAfterNextSessionBuild = false

        var configuration = SessionConfiguration(clientID: store.clientID())
        // Simulator writes cannot affect hardware, so its port controls are
        // available immediately. Real-device writes still require the user's
        // explicit opt-in and retain every existing safety confirmation.
        configuration.writesEnabled = preferences.demoMode || preferences.writesEnabled
        configuration.ownerUserID = Self.effectiveOwnerID(preferences.ownerUserID)
        configuration.pollInterval = .seconds(max(3, preferences.pollSeconds))

        let transport: ChargerTransport
        if preferences.demoMode {
            // The review fixture starts in the same readable display state as
            // the verified hardware so every reversible screen control can be
            // explored, not just the animated wattage dashboard.
            let device = MockA2687Device()
            device.firmwareVersion = "v0.0.5.2"
            device.screenTimeout = .oneMinute
            device.screenBrightness = 70
            device.screenOrientation = .up
            device.gyroscopeEnabled = true
            transport = MockChargerTransport(device: device, lively: true)
        } else {
            transport = CoreBluetoothTransport(fileLog: fileLog)
        }

        let session = ChargerSession(
            transport: transport, configuration: configuration, diagnostics: diagnostics
        )
        self.session = session

        let preferred = preferences.demoMode ? nil : store.peripheralID
        // A remembered charger is safe to reconnect automatically. With no
        // remembered identity, discovery stays a picker: auto-attaching the
        // first plausible advertisement makes the onboarding vanish and can
        // select the wrong charger in a room containing several of them.
        let shouldBrowseAfterStart = browseAfterStart
            || (!preferences.demoMode && preferred == nil)
        updatesTask = Task { [weak self] in
            for await snapshot in await session.updates() {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
        Task {
            await session.start(
                preferred: preferred,
                autoConnect: !shouldBrowseAfterStart
            )
        }
    }

    private func apply(_ snapshot: SessionSnapshot) {
        recordEnergy(from: snapshot)
        // Derived before the publish so the render that the publish triggers
        // already sees the matching series. Deliberately not @Published: it
        // changes exactly when `snapshot` does, and a second published property
        // would only double the invalidation.
        plottedHistory = PowerSample.decimated(snapshot.history)
        self.snapshot = snapshot
        switch snapshot.phase {
        case .monitoring:
            if connectedAt == nil { connectedAt = Date() }
        case .reconnecting, .connecting, .negotiating:
            // A blip, not a new session: the retry ladder runs
            // .reconnecting → .connecting → .negotiating, and the clock must
            // survive the whole chain. buildSession() clears it for real restarts.
            //
            break
        case .idle, .scanning, .failed, .bluetoothUnavailable:
            connectedAt = nil
        }
        if !preferences.demoMode, let id = snapshot.peripheralID, store.peripheralID != id {
            store.peripheralID = id
        }
        retireChargingModeNoteIfAnswered(snapshot)
        resolveChargerSettingChange(with: snapshot)
    }

    /// Resolves an ACKed display write only against a fresh live session.
    /// Readable fields need an actual settings snapshot; language has no
    /// discovered field, so reaching the new live session promotes its ACK to
    /// "accepted" without pretending it was read back.
    private func resolveChargerSettingChange(with snapshot: SessionSnapshot) {
        guard var change = chargerSettingChange,
              change.outcome == .reconnecting || change.outcome == .unconfirmed else { return }
        if !snapshot.phase.isLive {
            change.sawReconnectBoundary = true
            // Move the evidence cutoff to the boundary itself. A realtime frame
            // can arrive after the ACK but just before disconnect; its timestamp
            // must not make that old-session settings snapshot look fresh.
            change.verificationStartedAt = Date()
            chargerSettingChange = change
            return
        }
        guard snapshot.phase.isLive, change.sawReconnectBoundary,
              let startedAt = change.verificationStartedAt,
              let receivedAt = snapshot.telemetry?.receivedAt,
              receivedAt >= startedAt else { return }

        let result = change.setting.readbackMatches(snapshot.telemetry?.settings)
        if result == nil {
            change.outcome = .accepted
            noteChargerSettingChange(change, clearAfter: 8)
        } else if result == true {
            change.outcome = .confirmed
            noteChargerSettingChange(change, clearAfter: 8)
        } else if snapshot.telemetry?.settings != nil {
            change.outcome = .unconfirmed
            noteChargerSettingChange(change, clearAfter: nil)
        }
    }

    /// Takes the 「这次连接里还看不到变化」 note down the moment the settings field
    /// does show the mode that was sent.
    ///
    /// That note ends by asking the user to reconnect and look at this row
    /// again; leaving it up after the row has answered would make the app go on
    /// doubting a write its own screen has just confirmed. Only the unconfirmed
    /// note is retired this way — a refusal is not undone by the byte happening
    /// to match, and the confirmed note has its own countdown.
    private func retireChargingModeNoteIfAnswered(_ snapshot: SessionSnapshot) {
        guard let change = chargingModeChange, change.outcome == .unconfirmed,
              snapshot.telemetry?.settings?.chargingMode == change.mode.code else { return }
        noteChargingModeChange(nil, clearAfter: nil)
    }

    // MARK: - Preferences

    func selectAnkerPrimeModelScreen() {
        guard preferences.modelScreenStyle != .ankerPrime else { return }
        var updated = preferences
        updated.modelScreenStyle = .ankerPrime
        preferences = updated
        modelScreenArtworkRevision &+= 1
    }

    func selectModelScreenArtwork(id: Int) {
        guard modelScreenArtworks.contains(where: { $0.id == id }) else { return }
        guard preferences.modelScreenStyle != .custom
                || preferences.modelScreenCustomSlot != id else { return }
        var updated = preferences
        updated.modelScreenStyle = .custom
        updated.modelScreenCustomSlot = id
        preferences = updated
        modelScreenArtworkRevision &+= 1
    }

    /// `vignette` travels with the crop because both are baked into the pixels
    /// by ``ModelScreenArtwork``; neither is a display setting that could be
    /// re-applied later. Passing them together keeps the model texture and the
    /// 240×240 the charger receives derived from one and the same description.
    func saveModelScreenArtwork(
        replacing slot: Int?,
        sourceImage: NSImage,
        crop: ModelScreenCrop,
        vignette: ModelScreenVignette
    ) {
        do {
            let targetSlot: Int
            if let slot {
                guard (0..<ModelScreenArtworkStore.maximumCustomImages).contains(slot) else {
                    modelScreenArtworkError = L10n.text("自定义屏保位置无效")
                    return
                }
                targetSlot = slot
            } else {
                let occupied = Set(modelScreenArtworks.map(\.id))
                guard let available = (0..<ModelScreenArtworkStore.maximumCustomImages)
                    .first(where: { !occupied.contains($0) }) else {
                    modelScreenArtworkError = L10n.text("最多只能添加 3 个自定义屏保")
                    setActionMessage(modelScreenArtworkError)
                    return
                }
                targetSlot = available
            }

            let safeCrop = crop.clamped(for: sourceImage.size)
            let item = try ModelScreenArtworkStore.saveImportedImage(
                slot: targetSlot,
                sourceImage: sourceImage,
                crop: safeCrop,
                vignette: vignette
            )

            var updatedArtworks = modelScreenArtworks
            if let index = updatedArtworks.firstIndex(where: { $0.id == targetSlot }) {
                updatedArtworks[index] = item
            } else {
                updatedArtworks.append(item)
            }
            modelScreenArtworks = updatedArtworks.sorted { $0.id < $1.id }

            var updatedPreferences = preferences
            updatedPreferences.modelScreenStyle = .custom
            updatedPreferences.modelScreenCustomSlot = targetSlot
            preferences = updatedPreferences
            modelScreenArtworkRevision &+= 1
            modelScreenArtworkError = nil
            // `coverSyncedSlots` is intentionally left alone. Re-cropping,
            // re-tinting or outright replacing the picture in a slot does not
            // reach into the charger: the copy pushed earlier is still resident
            // and still undeletable, so the editor must keep saying that another
            // push is what it would take — and what it would cost.
            setActionMessage(L10n.text("已应用自定义模型屏保"))
        } catch {
            modelScreenArtworkError = error.localizedDescription
            setActionMessage(L10n.format("屏保图片保存失败：%@", error.localizedDescription))
        }
    }

    func removeModelScreenArtwork(id: Int) {
        do {
            let removedIndex = modelScreenArtworks.firstIndex { $0.id == id }
            try ModelScreenArtworkStore.removeCustomImage(slot: id)
            let remaining = modelScreenArtworks.filter { $0.id != id }
            modelScreenArtworks = remaining
            // The slot is free for a different picture now, and that picture has
            // never been pushed. What is inside the charger cannot be removed
            // from here — this only forgets the claim, it does not make one.
            forgetCoverResident(slot: id)

            var updatedPreferences = preferences
            if preferences.modelScreenStyle == .custom,
               preferences.modelScreenCustomSlot == id {
                if let removedIndex, !remaining.isEmpty {
                    let replacementIndex = min(removedIndex, remaining.count - 1)
                    updatedPreferences.modelScreenCustomSlot = remaining[replacementIndex].id
                } else {
                    updatedPreferences.modelScreenStyle = .ankerPrime
                }
            }
            preferences = updatedPreferences
            modelScreenArtworkRevision &+= 1
            modelScreenArtworkError = nil
            setActionMessage(L10n.text(
                remaining.isEmpty
                    ? "已恢复 Anker Prime 默认屏保"
                    : "已移除自定义模型屏保"
            ))
        } catch {
            modelScreenArtworkError = error.localizedDescription
            setActionMessage(L10n.format("无法移除自定义屏保：%@", error.localizedDescription))
        }
    }

    // MARK: - 同步屏保（把同一张图推到充电器的实体屏）

    /// Why a push cannot start right now, in one sentence, or nil when it can.
    ///
    /// Reported as a sentence rather than left as a greyed-out button: a disabled
    /// control with no reason attached leaves the user guessing which of three
    /// things is wrong. Demo mode is a hard no rather than a silent failure —
    /// ``MockA2687Device`` answers nothing in the `0x021F`–`0x0221` range, so a
    /// push there is six seconds of waiting and then 「充电器没有回应选图命令」.
    ///
    /// Deliberately does **not** consult `writesEnabled`. That switch is the port
    /// opt-in — its own label and footnote talk about cutting power to a port —
    /// and making a screen push wait behind it sent the user to enable something
    /// that describes a different feature. Consent for this write is asked where
    /// the write happens: the confirm panel that gates `acknowledgedIrreversible`.
    var coverPushBlocker: String? {
        if preferences.demoMode {
            return L10n.text("演示模式里没有真实充电器可以写入")
        }
        guard session != nil, snapshot.phase.isLive else {
            return L10n.text("需要先连上充电器")
        }
        return nil
    }

    /// Pushes one custom screen to the charger's own 240×240 panel.
    ///
    /// `acknowledgedIrreversible` is not a formality and has no default anywhere
    /// down the stack. Passing it `true` is a claim that the sentence 「写进充电器
    /// 的封面没有任何删除命令」 was on screen and the person ticked it — that is
    /// `CoverSyncSection`'s confirm panel, shown before the first `0x021F` and
    /// not as a footnote under a progress bar. This method is the first caller in
    /// the app that can honestly make that claim; it re-checks rather than
    /// assuming, and the transfer state machine refuses a `false` regardless.
    ///
    /// The JPEG is rendered from the *same* source image and the *same* crop the
    /// 3D model's texture uses, so what the user framed on the model is what the
    /// panel gets. That correspondence is the whole point of the feature and the
    /// one thing the official app cannot do — it pushes blind.
    func pushCoverToDevice(slot: Int, acknowledgedIrreversible: Bool) {
        guard acknowledgedIrreversible, !coverPush.isRunning else { return }
        guard let session, coverPushBlocker == nil else { return }
        guard let artwork = modelScreenArtworks.first(where: { $0.id == slot }) else { return }
        guard let sourceImage = artwork.sourceImage else {
            // A slot saved by an old build kept only the flattened 960×400
            // texture. Re-cropping a square out of that would push the model's
            // bezel to a screen that already has one.
            failCoverPush(
                CoverPushFailure(
                    remedy: .nothingWritten,
                    detail: L10n.text("这个屏保只剩下模型贴图，没有原图，重新导入一次就能推。"),
                    suggestsCloudID: false,
                    pixelsMayHaveLanded: false,
                    diagnostic: "slot \(slot) has no source image"
                ),
                slot: slot
            )
            return
        }

        let jpeg: [UInt8]
        do {
            // The slot's own vignette, not the default: the ring the user chose
            // is part of the picture, and the panel would otherwise receive a
            // differently-tinted image from the one the model is wearing.
            jpeg = try ModelScreenArtwork.deviceCoverJPEG(
                from: sourceImage, crop: artwork.crop, vignette: artwork.vignette
            )
        } catch {
            // The thrown error names a Core Graphics step. What the person
            // holding the charger needs from it is that the picture is the
            // problem and nothing has been written; the step's name goes to the
            // log, where somebody can do something with it.
            failCoverPush(
                CoverPushFailure(
                    remedy: .nothingWritten,
                    detail: L10n.text("这张图没能转成充电器要的画面。"),
                    suggestsCloudID: false,
                    pixelsMayHaveLanded: false,
                    diagnostic: "cover JPEG render failed: \(error)"
                ),
                slot: slot
            )
            return
        }

        coverPush = CoverPushState(
            phase: .running(CoverTransferProgress(
                stage: .selecting,
                chunksSent: 0,
                chunkCount: CoverTransfer.chunkCount(forByteCount: jpeg.count)
            )),
            slot: slot
        )
        lastCoverProgressPublish = nil
        setActionMessage(L10n.text("正在把屏保推到充电器…"), autoClearAfter: nil)

        coverPushTask = Task { [weak self] in
            // The id the charger is showing right now, read before anything is
            // named. It is the only resident id that can be observed at all, and
            // minting over it would cost the read-back its power to tell a
            // change from a coincidence — see `mintCoverPictureID`.
            let displayed = try? await CoverTransferAdapter(session: session)
                .readCoverPictureID()
            // `init(pictureID:jpeg:)`, never the explicit one: it derives the
            // CRC-32 from the very bytes about to be sent, so `0x021F` and
            // `0x0220` cannot end up describing different images. The other
            // initialiser exists for the cloud path, where the hash arrives from
            // Anker and has to be compared rather than computed.
            let reference = CoverImageReference(
                pictureID: Self.mintCoverPictureID(jpeg: jpeg, avoiding: displayed),
                jpeg: jpeg
            )
            self?.lastCoverReference = reference
            do {
                let outcome = try await session.pushCover(
                    jpeg: jpeg,
                    as: reference,
                    acknowledgedIrreversible: true,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.noteCoverProgress(progress, slot: slot)
                        }
                    }
                )
                self?.finishCoverPush(outcome, slot: slot)
            } catch {
                self?.failCoverPush(Self.classifyCoverFailure(error), slot: slot)
            }
        }
    }

    /// Stops at the next slice boundary. It cannot unsend anything.
    func cancelCoverPush() {
        guard coverPush.isRunning, !coverPush.isStopping else { return }
        // The button has to stop claiming the stop is instant: the deadline is
        // only read between slices, so the last one in flight still goes out.
        coverPush.isStopping = true
        coverPushTask?.cancel()
    }

    func dismissCoverPushResult() {
        guard !coverPush.isRunning else { return }
        coverPush = CoverPushState()
    }

    /// Re-sends `0x021F` after a push whose pixels all landed and whose screen
    /// did not change.
    ///
    /// Cheap and reversible in a way the push is not: no pixels move, nothing new
    /// is written to the four slots, and selecting a different cover undoes it.
    /// So it needs no irreversibility gate — the gate guards a write that cannot
    /// be taken back, and this is not one.
    func retryCoverSelection() {
        guard case .failed(let failure) = coverPush.phase,
              failure.remedy == .selectionDidNotTake,
              let reference = lastCoverReference,
              let session,
              coverPushBlocker == nil else { return }
        let slot = coverPush.slot
        coverPush = CoverPushState(
            phase: .running(CoverTransferProgress(stage: .selecting)),
            slot: slot
        )
        Task { [weak self] in
            do {
                let reported = try await session.selectCover(reference)
                self?.noteCoverSelection(
                    reported, expected: reference.reportedID, slot: slot
                )
            } catch {
                self?.failCoverSelection(error, slot: slot)
            }
        }
    }

    /// A re-selection that threw is never 「一个字节都没写进去」.
    ///
    /// ``classifyCoverFailure(_:)`` reads the remedy off the error, and the
    /// errors this path raises — a `0x021F` unanswered, a `0x021F` refused —
    /// do mean "nothing was written" when they happen during a push. Here they
    /// do not: this button only exists after a push whose slices all landed, and
    /// they are still inside the charger. Saying otherwise would send the user
    /// to push the whole picture again and spend a second slot on it.
    private func failCoverSelection(_ error: Error, slot: Int?) {
        let transfer = error as? CoverTransferError
        var suggestsCloudID = false
        if let transfer, case .selectRejected = transfer { suggestsCloudID = true }
        failCoverPush(
            CoverPushFailure(
                remedy: .selectionDidNotTake,
                detail: transfer.flatMap(Self.coverFailureDetail) ?? Self.describe(error),
                suggestsCloudID: suggestsCloudID,
                pixelsMayHaveLanded: true,
                diagnostic: "reselect failed: " + (transfer?.diagnostic ?? "\(error)")
            ),
            slot: slot
        )
    }

    /// Mints the picture id a locally pushed cover is filed under.
    ///
    /// On Anker's own path the cloud allocates this. On the placeholder path
    /// nobody does, so we do, and two properties are wanted:
    ///
    /// - **Stable for the same pixels.** A retry after a failed push then reuses
    ///   the id instead of spending another of the four device slots.
    /// - **Different from what the panel is showing.** `0xE1` reports only the
    ///   low 16 bits, and that read-back is the only witness the screen changed;
    ///   mint the id already on screen and a push that did nothing at all is
    ///   indistinguishable from one that worked.
    ///
    /// There is no id range that is safe by construction. Real ids are five
    /// digits, and five digits truncated to `UInt16` land anywhere in 0…65535, so
    /// no band is free of the other three resident covers. The displayed id is
    /// the only one that can be read, so it is the only collision that can be
    /// avoided; the rest is why ``CoverVerification/inconclusive(reason:)`` has
    /// to be rendered rather than folded into success.
    private static func mintCoverPictureID(jpeg: [UInt8], avoiding displayed: UInt16?) -> UInt32 {
        // Derived from the pixels rather than drawn at random, so pushing the
        // same picture twice does not fill two slots with the same image. The
        // high half is kept non-zero purely to keep the value away from the
        // small integers the firmware uses for its built-in screensaver types.
        let low = UInt16(truncatingIfNeeded: CoverTransfer.crc32(jpeg))
        let safeLow = low == displayed ? low &+ 1 : low
        return 0x0001_0000 | UInt32(safeLow)
    }

    /// Progress arrives from the transfer actor roughly every 40 ms for half a
    /// minute. Every frame is a `@Published` write, and the settings page that
    /// hosts this sheet rebuilds its body on each one, so the stream is thinned
    /// to stage changes, the final slice, and about eight frames a second in
    /// between — more than a progress bar can show.
    private static let coverProgressInterval = Duration.milliseconds(120)

    private func noteCoverProgress(_ progress: CoverTransferProgress, slot: Int) {
        guard coverPush.slot == slot, case .running(let current) = coverPush.phase else { return }
        // Each frame is delivered by its own hop to the main actor, so two can
        // arrive out of order. A bar that walks backwards reads as a fault; a
        // bar that skips a slice does not. Drop the stale one.
        guard progress.chunksSent >= current.chunksSent else { return }
        let isFinalSlice = progress.chunkCount > 0 && progress.chunksSent == progress.chunkCount
        let now = ContinuousClock.now
        if progress.stage == current.stage, !isFinalSlice,
           let last = lastCoverProgressPublish,
           last.duration(to: now) < Self.coverProgressInterval {
            return
        }
        lastCoverProgressPublish = now
        coverPush.phase = .running(progress)
    }

    private func finishCoverPush(_ outcome: CoverTransferOutcome, slot: Int) {
        coverPushTask = nil
        coverPush = CoverPushState(phase: .done(outcome), slot: slot)
        noteCoverResident(slot: slot)
        // The result card says what happened; this says how we know. The `0xE1`
        // pair is the only thing that separates 「屏幕真的换了」 from 「固件应答了而
        // 已」, so it cannot simply be dropped when it comes off the card — it
        // goes where the person debugging looks and the person charging a phone
        // does not.
        diagnostics.record("COVER", Self.coverEvidence(outcome))
        // Switched, not `if witnessed`: 「像素都发完了」 and 「屏幕确实换了」 are
        // different claims, and the second one is only available when the
        // pre-push read gave us something to compare against.
        switch outcome.verification {
        case .witnessed:
            setActionMessage(L10n.text("充电器的屏幕已经换成这张图"))
        case .inconclusive:
            setActionMessage(L10n.text("图已经发完，但没能证明充电器的屏幕真换了"))
        }
    }

    private func noteCoverSelection(_ reported: UInt16?, expected: UInt16, slot: Int?) {
        coverPushTask = nil
        let evidence = "reselect: 0xE1 reported "
            + (reported.map(String.init) ?? "nothing")
            + ", expected \(expected)"
        diagnostics.record("COVER", evidence)
        guard reported == expected else {
            // 「读不到」 and 「读到了，是别的图」 are two different things, and only
            // the second one is evidence that the screen did not change. Folding
            // the first into it made Charker assert, on the firmware's behalf,
            // something no read had shown — and then offered the cloud-id
            // explanation for a mismatch nobody had seen. When the id cannot be
            // read the charger's own display is the better witness than a second
            // read-back, so the card sends the user to look at it.
            let unreadable = reported == nil
            coverPush = CoverPushState(
                phase: .failed(CoverPushFailure(
                    remedy: .selectionDidNotTake,
                    detail: L10n.text(unreadable
                        ? "没能确认屏幕换了没有。去看一眼充电器：如果已经换了，就不用再管。"
                        : "又试了一次，充电器的屏幕还是没换过来。"),
                    suggestsCloudID: !unreadable,
                    pixelsMayHaveLanded: true,
                    diagnostic: evidence
                )),
                slot: slot
            )
            return
        }
        coverPush = CoverPushState(phase: .reselected(reportedID: expected), slot: slot)
        setActionMessage(L10n.text("充电器已经切到这张封面"))
    }

    private func failCoverPush(_ failure: CoverPushFailure, slot: Int?) {
        coverPushTask = nil
        coverPush = CoverPushState(phase: .failed(failure), slot: slot)
        diagnostics.record(
            "COVER", "failed (\(failure.remedy)): \(failure.diagnostic)"
        )
        // A failure that got as far as writing pixels counts as resident too:
        // the bytes are in the charger, they cannot be deleted, and the next
        // push starts the whole picture over. ``CoverPushFailure`` already draws
        // exactly that line, so reuse it rather than inventing a second one.
        if failure.pixelsMayHaveLanded, let slot { noteCoverResident(slot: slot) }
        // The status line, unlike the card, has no title above it — so it says
        // the outcome whole rather than gluing 「屏保没能推上去：」 onto a fragment
        // that, for two of the four remedies, would contradict it.
        setActionMessage(failure.remedy.notice)
    }

    /// Files a slot as resident, in memory and on disk at once.
    ///
    /// One entry point for both callers so the two cannot drift apart: a push
    /// that finished and a push that died half-written make the same claim as
    /// far as the charger is concerned — bytes went in, and nothing takes them
    /// back out.
    private func noteCoverResident(slot: Int) {
        guard !coverSyncedSlots.contains(slot) else { return }
        coverSyncedSlots.insert(slot)
        persistCoverSyncedSlots()
    }

    /// Drops the claim for a slot whose picture the user deleted. This frees
    /// nothing inside the charger; it only stops Charker attributing a push
    /// history to whatever picture lands in the slot next.
    private func forgetCoverResident(slot: Int) {
        guard coverSyncedSlots.remove(slot) != nil else { return }
        persistCoverSyncedSlots()
    }

    private func persistCoverSyncedSlots() {
        UserDefaults.standard.set(
            coverSyncedSlots.sorted(), forKey: Self.coverSyncedSlotsKey
        )
    }

    /// Straight into `UserDefaults` rather than through ``Preferences``: this is
    /// not a setting anybody chose, it is a record of what this Mac has already
    /// done, and it has no row in the settings UI to earn a place in the
    /// settings model.
    private static let coverSyncedSlotsKey = "coverSyncedSlots"

    private static func loadCoverSyncedSlots() -> Set<Int> {
        let stored = UserDefaults.standard.array(forKey: coverSyncedSlotsKey) as? [Int] ?? []
        // A slot index from an older build — or from a hand-edited plist — must
        // not become a warning attached to a slot that cannot exist.
        return Set(stored.filter {
            (0..<ModelScreenArtworkStore.maximumCustomImages).contains($0)
        })
    }

    /// Everything the result card used to print under itself.
    ///
    /// Deliberately untranslated: the audience is a bug report, and a log line
    /// that changes shape with the reader's language is one nobody can grep.
    /// ``CoverVerification`` is switched over here for the same reason the card
    /// switches over it — 「没能确认」 has to stay distinguishable from 「确认了」
    /// in the record too, and the reason it could not be confirmed is exactly
    /// the part the card stopped showing.
    private static func coverEvidence(_ outcome: CoverTransferOutcome) -> String {
        let verdict: String
        switch outcome.verification {
        case .witnessed(let before):
            verdict = "witnessed: 0xE1 \(before) -> \(outcome.reportedPictureID)"
        case .inconclusive(.alreadyShowingThisPicture(let id)):
            verdict = "inconclusive: 0xE1 already reported \(id) before the push"
        case .inconclusive(.beforeStateUnreadable):
            verdict = "inconclusive: 0xE1 unreadable before the push, "
                + "now \(outcome.reportedPictureID)"
        }
        return "pushed id \(outcome.pictureID), \(outcome.byteCount) B, "
            + "\(outcome.chunkCount) chunks, "
            + "\(outcome.indexedCheckpoints)/\(outcome.checkpointCount) "
            + "checkpoints carried an index; " + verdict
    }

    /// Groups a failure by what the user can do about it, not by which line threw.
    ///
    /// ``CoverTransferError/pixelsMayHaveLanded`` is the seam that matters:
    /// 「一个字节都没写进去」 and 「有一部分已经留在充电器里，删不掉」 are different
    /// things to tell someone, and only the error knows which happened.
    private static func classifyCoverFailure(_ error: Error) -> CoverPushFailure {
        guard let transfer = error as? CoverTransferError else {
            // `SessionError.notReady` is thrown by the readiness gate before the
            // first frame; anything else here never got started either.
            return CoverPushFailure(
                remedy: .nothingWritten,
                detail: describe(error),
                suggestsCloudID: false,
                pixelsMayHaveLanded: false,
                diagnostic: "failed before the first frame: \(error)"
            )
        }

        let remedy: CoverPushFailure.Remedy
        var suggestsCloudID = false
        switch transfer {
        case .emptyImage, .tooManyChunks, .alreadyRunning,
             .irreversibilityNotAcknowledged, .hashMismatch,
             .selectUnanswered, .startUnanswered:
            remedy = .nothingWritten
        // Cancelling during 「正在选图」, before the first slice has gone out, is
        // the ordinary way this button gets pressed: the user changes their mind
        // while the charger is still being asked. `pixelsMayHaveLanded` is true
        // for every `.cancelled`, which is right for the case it was written for
        // and wrong for this one — it told somebody who had written nothing that
        // one of the four undeletable slots was now spent, and the four are the
        // reason the confirm panel exists at all.
        case .cancelled(let sent, _) where sent == 0,
             .budgetExhausted(let sent, _) where sent == 0:
            remedy = .nothingWritten
        case .selectRejected, .startRejected:
            // An explicit refusal at the naming or declaring step is the shape a
            // rejected `SmallChargingUrl` placeholder would take: the firmware
            // saying it wants an id its cloud minted. Silence is not — that is a
            // link diagnosis, so the cloud line stays off for the unanswered
            // cases even though they are equally 「nothing was written」.
            remedy = .nothingWritten
            suggestsCloudID = true
        case .chunkSendFailed, .acknowledgementTimedOut, .chunkRejected,
             .cancelled, .budgetExhausted:
            remedy = .interrupted
        case .progressMismatch:
            remedy = .lostSlices
        case .notShownAfterTransfer:
            remedy = .selectionDidNotTake
        }
        return CoverPushFailure(
            remedy: remedy,
            detail: coverFailureDetail(transfer),
            suggestsCloudID: suggestsCloudID,
            pixelsMayHaveLanded: transfer.pixelsMayHaveLanded,
            diagnostic: transfer.diagnostic
        )
    }

    /// The one sentence a failure card adds to the two its remedy already puts
    /// on screen — or nil, which is the commonest and the most deliberate answer.
    ///
    /// 「已经写进去一部分」 over 「停下之前已经写进去的部分留在充电器里，没有命令能删…」
    /// is the whole of a cancelled push. A third line naming the slice it
    /// stopped at adds nothing anyone can act on and asks the reader to audit us
    /// instead of to decide. So what earns a line here is a *cause the user can
    /// do something about* — the charger went quiet, the picture will not
    /// convert, the firmware said no — and never a number that proves it. The
    /// numbers all survive, in ``CoverTransferError/diagnostic``, in the log.
    ///
    /// The one distinction this must never blur is the one the remedy carries:
    /// whether pixels are now inside the charger. Cases collapse together here
    /// only when they share a remedy.
    private static func coverFailureDetail(_ error: CoverTransferError) -> String? {
        switch error {
        case .emptyImage, .tooManyChunks:
            return L10n.text("这张图推不过去，换一张试试。")
        case .alreadyRunning:
            return L10n.text("上一次推送还没结束。")
        // Both are ours to have got wrong, not the user's to fix, and both stop
        // before the first byte — 「一个字节都没写进去，可以直接再来一次」 is the
        // whole of what to do, and it is already on the card.
        case .irreversibilityNotAcknowledged, .hashMismatch:
            return nil
        case .selectUnanswered, .startUnanswered:
            return L10n.text("充电器没有回应。")
        // Which of the two commands was refused, and with what status, decides
        // nothing for the reader: either way the charger said no and nothing was
        // written. `suggestsCloudID` adds the one line that *is* actionable.
        case .selectRejected, .startRejected:
            return L10n.text("充电器拒绝了这张图。")
        case .chunkSendFailed, .acknowledgementTimedOut, .budgetExhausted:
            return L10n.text("传到一半中断了。")
        case .chunkRejected:
            return L10n.text("充电器中途报错，停下了。")
        // The user pressed 取消, so the cause is not news; and a slice count is
        // not what 「已经写进去一部分」 is missing.
        case .cancelled:
            return nil
        // 「图没有传完整」 plus its advice says what landed, that it will not be
        // shown, and that it cannot be deleted. Nothing is left to add.
        case .progressMismatch:
            return nil
        // `0xE1` can lag the screen. Looking at the charger settles in a second
        // what a second read-back might not settle at all.
        case .notShownAfterTransfer:
            return L10n.text("先去看一眼充电器的屏幕：如果它已经换了，就不用再管。")
        }
    }

    /// The owner id the session actually uses: normalised when valid, else nil.
    /// Session rebuilds compare THIS, not the raw text — binding a TextField to
    /// the raw string must not tear the BLE link down on every keystroke.
    private static func effectiveOwnerID(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PreferencesStore.isValidOwnerUserID(normalized) ? normalized : nil
    }

    private func preferencesChanged(from old: Preferences) {
        store.save(preferences)
        diagnostics.captureRawPayloads = preferences.captureRawPayloads

        if old.showDockIcon != preferences.showDockIcon {
            NSApp.setActivationPolicy(preferences.showDockIcon ? .regular : .accessory)
        }
        if old.appearance != preferences.appearance {
            applyAppearance()
        }
        if old.demoMode != preferences.demoMode
            || Self.effectiveOwnerID(old.ownerUserID) != Self.effectiveOwnerID(preferences.ownerUserID) {
            if old.demoMode != preferences.demoMode { refreshPortShutdownSchedules() }
            if isRunning { buildSession() }
            return
        }
        if old.writesEnabled != preferences.writesEnabled {
            let enabled = preferences.demoMode || preferences.writesEnabled
            Task { await session?.setWritesEnabled(enabled) }
        }
        if old.pollSeconds != preferences.pollSeconds {
            let interval = Duration.seconds(max(3, preferences.pollSeconds))
            Task { await session?.setPollInterval(interval) }
        }
        if old.launchAtLogin != preferences.launchAtLogin {
            applyLoginItem(preferences.launchAtLogin)
        }
    }

    /// The system is the source of truth for the login item, not our own flag.
    /// `.requiresApproval` counts as success-pending: flipping the flag back off
    /// there would unregister the very request the user is being asked to
    /// approve in System Settings. The guard stops the corrective flag write
    /// from re-entering this method.
    private func applyLoginItem(_ enabled: Bool) {
        guard !isApplyingLoginItem else { return }
        isApplyingLoginItem = true
        defer { isApplyingLoginItem = false }

        var registerError: String?
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            registerError = error.localizedDescription
        }
        loginItemStatus = SMAppService.mainApp.status

        if enabled {
            switch loginItemStatus {
            case .enabled:
                break
            case .requiresApproval:
                setActionMessage(L10n.text("登录项等待批准——请在「系统设置 › 通用 › 登录项」中允许 Charker"))
            default:
                preferences.launchAtLogin = false
                if let registerError {
                    setActionMessage(L10n.format("登录项设置失败：%@", registerError))
                }
            }
        } else if let registerError {
            setActionMessage(L10n.format("登录项设置失败：%@", registerError))
        }
    }

    func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }

    // MARK: - Presentation

    var statusTitle: String {
        if preferences.showIconOnly { return "" }
        guard snapshot.phase.isLive, snapshot.telemetry != nil else {
            return StatusTemplate.offlineTitle(snapshot)
        }
        // Staleness is carried by the bolt.badge.clock symbol; a bare "·" suffix
        // here explained nothing. Same renderer as the settings preview — the
        // preview must never look different from the real menu bar.
        return MenuBarConfig.render(
            preferences.menuBarItems, snapshot: snapshot,
            defaultDecimals: preferences.decimals, hideIdlePorts: preferences.hideIdlePorts,
            portNicknames: preferences.portNicknames
        )
    }

    /// The bolt image is forced on while the title is off — a menu-bar item
    /// with neither image nor title would be an invisible click target.
    var statusShowsIcon: Bool {
        preferences.showsMenuBarIcon || preferences.showIconOnly || statusTitle.isEmpty
    }

    /// Symbols offered by the icon inspector. All present since macOS 14;
    /// availability is still verified at pick time and render time.
    static let menuBarIconChoices = [
        "bolt.fill", "bolt", "bolt.circle.fill", "bolt.horizontal.fill",
        "powerplug.fill", "powercord.fill", "battery.100percent.bolt",
        "minus.plus.batteryblock.fill",
    ]

    var statusSymbolName: String {
        switch snapshot.phase {
        case .monitoring where snapshot.isStale: return "bolt.badge.clock"
        case .monitoring:
            // The user's pick applies to the healthy state; a symbol the OS
            // doesn't know falls back rather than blanking the menu bar.
            let symbol = preferences.menuBarIconSymbol
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
                ? symbol : "bolt.fill"
        case .bluetoothUnavailable, .failed: return "bolt.slash"
        default: return "bolt"
        }
    }

    var diagnosticsPath: String { fileLog.path }

    /// Selects the log in Finder rather than printing its path into the UI.
    func revealDiagnosticsLog() {
        let url = URL(fileURLWithPath: fileLog.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    var energyHistoryPath: String { energyHistoryStore.path }

    /// Demo telemetry is useful for checking the screen, but must never become
    /// indistinguishable from observations of the user's real charger.
    var displayedEnergyHistory: EnergyHistory {
        snapshot.isDemo ? demoEnergyHistory : energyHistory
    }

    var energyHistoryIsEphemeral: Bool { snapshot.isDemo }

    var hasActiveEnergySession: Bool {
        displayedEnergyHistory.activeSession != nil
    }

    /// A recovery warning also counts: a corrupt archive can decode to an empty
    /// in-memory history while still leaving both the original and its recovery
    /// copy on disk. The clear action is the user's way to remove those too.
    var canClearEnergyHistory: Bool {
        guard !energyHistoryIsEphemeral else { return false }
        return !energyHistory.sessions.isEmpty
            || !energyHistory.hourly.isEmpty
            || energyHistory.activeSession != nil
            || energyHistory.archivedSessionCount > 0
            || energyHistory.skippedCompaction != nil
            || energyHistoryWarning != nil
    }

    /// Ends only Charker's local energy segment. It neither changes the BLE
    /// session nor sends a command to the charger; the next distinct telemetry
    /// sample becomes the first point of a fresh segment.
    func endCurrentEnergySession() {
        guard hasActiveEnergySession else {
            setActionMessage(L10n.text("当前没有正在记录的能耗段"))
            return
        }

        energySaveTask?.cancel()
        energySaveTask = nil
        if snapshot.isDemo {
            demoEnergyHistory.finishCurrentSession()
        } else {
            energyHistory.finishCurrentSession()
            saveEnergyHistory()
        }
        // Do not reuse the sample that ended the previous segment. Waiting for
        // a new timestamp makes “下一次开始” literal and avoids a zero-time run.
        lastRecordedEnergyAt = snapshot.history.last?.at
        setActionMessage(L10n.text("本次能耗记录已结束；下一次采样会开始新记录"))
    }

    /// Permanently clears Charker's local energy log without touching the BLE
    /// link or the charger's power delivery. If telemetry is still arriving,
    /// the next distinct sample starts a new segment from zero.
    @discardableResult
    func clearEnergyHistory() -> Bool {
        guard !snapshot.isDemo, canClearEnergyHistory else { return false }

        energySaveTask?.cancel()
        energySaveTask = nil
        var cleared = energyHistory
        do {
            try energyHistoryStore.clear(&cleared)
            energyHistory = cleared
            energyHistoryWarning = nil
            // Do not let the sample already visible in `snapshot` immediately
            // reappear as a new zero-length run. Wait for fresh telemetry.
            lastRecordedEnergyAt = snapshot.history.last?.at
            setActionMessage(L10n.text("能耗记录已清空；充电连接不受影响"))
            return true
        } catch {
            // `removeArchive()` may have deleted the primary file before a
            // recovery-copy deletion failed. Re-save the untouched in-memory
            // value so the failure cannot silently discard the user's history.
            try? energyHistoryStore.save(energyHistory)
            let warning = L10n.format("能耗历史清空失败：%@", error.localizedDescription)
            energyHistoryWarning = warning
            setActionMessage(warning)
            return false
        }
    }

    /// Permanently removes one calendar-aligned slice while preserving every
    /// bucket outside it. The active run is reset when it intersects the slice;
    /// fresh telemetry then starts a new run without crossing the deletion.
    @discardableResult
    func clearEnergyHistory(from start: Date, to end: Date) -> Bool {
        guard !snapshot.isDemo, start < end else { return false }

        energySaveTask?.cancel()
        energySaveTask = nil
        var cleared = energyHistory
        guard cleared.removeRecords(from: start, to: end) else { return false }
        do {
            try energyHistoryStore.replaceAfterRemoval(cleared)
            energyHistory = cleared
            energyHistoryWarning = nil
            lastRecordedEnergyAt = snapshot.history.last?.at
            setActionMessage(L10n.text("所选范围的能耗记录已清空；充电连接不受影响"))
            return true
        } catch {
            // `replaceAfterRemoval` may already have replaced the primary file
            // before deleting a stale recovery copy failed. Restore the
            // untouched value so a reported failure never becomes silent loss.
            try? energyHistoryStore.save(energyHistory)
            let warning = L10n.format("能耗历史清空失败：%@", error.localizedDescription)
            energyHistoryWarning = warning
            setActionMessage(warning)
            return false
        }
    }

    /// "1.0.0" from a bundled build; nil under `swift run`, where the About page
    /// and sidebar say "开发构建" instead of a fake version.
    var versionText: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: - Session stats

    struct SessionStats: Equatable {
        var peak: Double
        var average: Double
        var energyWh: Double
        var connectedAt: Date?
    }

    /// Derived from the rolling history: honest about its window (the buffer
    /// holds the last ~600 samples), which at default polling covers the whole
    /// session for hours.
    var sessionStats: SessionStats? {
        let history = snapshot.history
        guard history.count > 1 else { return nil }
        var peak = 0.0
        var sum = 0.0
        var energyWattSeconds = 0.0
        for (index, sample) in history.enumerated() {
            peak = max(peak, sample.total)
            sum += sample.total
            if index > 0 {
                let previous = history[index - 1]
                let dt = sample.at.timeIntervalSince(previous.at)
                // Gaps (disconnects, sleep) are not energy; skip implausible steps.
                if dt > 0, dt < 120 {
                    energyWattSeconds += dt * (sample.total + previous.total) / 2
                }
            }
        }
        return SessionStats(
            peak: peak,
            average: sum / Double(history.count),
            energyWh: energyWattSeconds / 3600,
            connectedAt: connectedAt
        )
    }

    // MARK: - Energy history

    private func recordEnergy(from snapshot: SessionSnapshot) {
        guard let sample = snapshot.history.last,
              sample.at != lastRecordedEnergyAt else { return }
        lastRecordedEnergyAt = sample.at
        let measurement = EnergyMeasurement(
            at: sample.at,
            totalWatts: sample.total,
            perPortWatts: sample.perPort
        )
        if snapshot.isDemo {
            demoEnergyHistory.record(measurement)
        } else {
            energyHistory.record(measurement)
            scheduleEnergySave()
        }
    }

    private func scheduleEnergySave() {
        energySaveTask?.cancel()
        energySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.saveEnergyHistory()
        }
    }

    private func finishEnergyObservation() {
        energySaveTask?.cancel()
        energySaveTask = nil
        if snapshot.isDemo {
            demoEnergyHistory.finishCurrentSession()
        } else {
            energyHistory.finishCurrentSession()
            saveEnergyHistory()
        }
        lastRecordedEnergyAt = nil
    }

    private func saveEnergyHistory() {
        do {
            try energyHistoryStore.save(energyHistory)
            energyHistoryWarning = nil
        } catch {
            energyHistoryWarning = L10n.format("能耗历史保存失败：%@", error.localizedDescription)
        }
    }

    /// A deterministic, explicitly labelled fixture for exercising every range
    /// in demo mode. It is never assigned to or saved through `energyHistory`.
    private static func makeDemoEnergyHistory(now: Date = Date()) -> EnergyHistory {
        var history = EnergyHistory()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        for dayOffset in -89 ..< 0 {
            // Real logs have quiet days. Leaving a regular gap makes the chart's
            // absence semantics visible instead of painting an implausible wall.
            if abs(dayOffset).isMultiple(of: 11) { continue }
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            let runCount = abs(dayOffset).isMultiple(of: 4) ? 2 : 1

            for run in 0..<runCount {
                let minuteOfDay = (8 + (abs(dayOffset) % 6) + run * 7) * 60 + run * 13
                let start = calendar.date(byAdding: .minute, value: minuteOfDay, to: day) ?? day
                let observedMinutes = 5 + (abs(dayOffset + run) % 6)
                let base = 38.0 + Double((abs(dayOffset) * 13 + run * 19) % 64)

                for minute in 0...observedMinutes {
                    let at = start.addingTimeInterval(Double(minute) * 60)
                    let wave = Double((minute * 7 + abs(dayOffset)) % 9) - 4
                    let total = max(8, base + wave)
                    let c1Share = 0.46 + Double(abs(dayOffset) % 4) * 0.05
                    let c2Share = run == 0 ? 0.30 : 0.18
                    let c1 = total * c1Share
                    let c2 = total * c2Share
                    history.record(EnergyMeasurement(
                        at: at,
                        totalWatts: total,
                        perPortWatts: [c1, c2, max(0, total - c1 - c2)]
                    ), calendar: calendar)
                }
                history.finishCurrentSession()
            }
        }
        return history
    }

    // MARK: - Actions

    private func setActionMessage(_ text: String?, autoClearAfter seconds: Double? = 7) {
        messageClearTask?.cancel()
        messageClearTask = nil
        lastActionMessage = text
        guard text != nil, let seconds else { return }
        messageClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.lastActionMessage = nil
        }
    }

    func setPort(_ port: A2687.Port, on: Bool) {
        guard preferences.demoMode || preferences.writesEnabled, let session else { return }
        setActionMessage(L10n.format("%@：正在发送…", port.label), autoClearAfter: nil)
        Task { [weak self] in
            do {
                let confirmed = try await session.setPortOutput(port, on: on)
                await MainActor.run {
                    self?.setActionMessage(confirmed
                        ? (on
                            ? L10n.format("%@ 已打开", port.label)
                            : L10n.format("%@ 已关闭", port.label))
                        : L10n.format("%@：充电器没有确认，当前状态未知", port.label))
                }
            } catch {
                await MainActor.run {
                    self?.noteWriteFailure("port \(port.label) \(on ? "on" : "off")", error)
                    self?.setActionMessage(L10n.format("%@：%@", port.label, Self.describe(error)))
                }
            }
        }
    }

    /// Arms the charger's own shutdown countdown for one port.
    ///
    /// ``ChargerSession/setPortTimer(_:seconds:)`` returns Void rather than
    /// Bool, and that shapes what this may claim. The acknowledgement is real —
    /// its status byte is checked — but nothing on this firmware reads an armed
    /// timer back, so 「已设定」 is the strongest honest word. 「已确认」 would be
    /// claiming a read-back that does not exist.
    ///
    /// The duration is formatted by ``PortCard/durationText(_:)``, the same
    /// function that wrote the confirmation the user just agreed to.
    func setPortTimer(_ port: A2687.Port, seconds: UInt32) {
        guard preferences.demoMode || preferences.writesEnabled, let session else { return }
        setActionMessage(L10n.format("%@：正在发送…", port.label), autoClearAfter: nil)
        Task { [weak self] in
            do {
                try await session.setPortTimer(port, seconds: seconds)
                await MainActor.run {
                    self?.notePortShutdownSchedule(
                        port: port,
                        seconds: seconds,
                        acceptedAt: Date()
                    )
                    // The persistent result now lives inside this port's own
                    // row. A second, short-lived success notice below the whole
                    // dashboard only repeats it and pulls attention away.
                    self?.setActionMessage(nil)
                }
            } catch {
                await MainActor.run {
                    self?.noteWriteFailure("port timer \(port.label) \(seconds)s", error)
                    self?.setActionMessage(
                        L10n.format("%@：%@", port.label, Self.describe(error))
                    )
                }
            }
        }
    }

    /// Active projections for the charger this app is currently talking to (or
    /// the remembered charger during a reconnect). A timer armed on another
    /// charger must never be presented as belonging to the one now on screen.
    func activePortShutdownSchedules(at date: Date = Date()) -> [PortShutdownSchedule] {
        guard let peripheralID = snapshot.peripheralID ?? store.peripheralID else { return [] }
        return portShutdownSchedules.filter {
            $0.peripheralID == peripheralID && $0.isActive(at: date)
        }
    }

    func activePortShutdownSchedule(
        for port: A2687.Port,
        at date: Date = Date()
    ) -> PortShutdownSchedule? {
        activePortShutdownSchedules(at: date).first { $0.port == port }
    }

    /// Replaces only the same device/port. The charger accepts another non-zero
    /// duration as a new countdown, so retaining both would show two mutually
    /// exclusive deadlines for one outlet.
    private func notePortShutdownSchedule(
        port: A2687.Port,
        seconds: UInt32,
        acceptedAt: Date
    ) {
        guard let peripheralID = snapshot.peripheralID ?? store.peripheralID else {
            diagnostics.record(
                "UI", "timer ACK for \(port.label) could not be projected: no peripheral id"
            )
            return
        }
        let schedule = PortShutdownSchedule(
            peripheralID: peripheralID,
            port: port,
            durationSeconds: seconds,
            armedAt: acceptedAt
        )
        portShutdownSchedules.removeAll { $0.id == schedule.id || !$0.isActive(at: acceptedAt) }
        portShutdownSchedules.append(schedule)
        portShutdownSchedules.sort {
            if $0.deadline != $1.deadline { return $0.deadline < $1.deadline }
            return $0.id < $1.id
        }
        // Demo actions belong to the simulated charger only. They stay visible
        // for review this run but must never enter the real charger's history.
        if !preferences.demoMode {
            portShutdownScheduleStore.save(portShutdownSchedules, activeAt: acceptedAt)
        }
        armPortShutdownExpiry(for: schedule)
    }

    /// Reloading on every session start prunes deadlines that elapsed while the
    /// process was not running and re-arms the local retirement tasks. The timer
    /// itself remains charger-owned; these tasks only retire the dashboard row.
    private func refreshPortShutdownSchedules(at date: Date = Date()) {
        portShutdownExpiryTasks.values.forEach { $0.cancel() }
        portShutdownExpiryTasks.removeAll()
        if preferences.demoMode {
            portShutdownSchedules = []
            return
        }
        portShutdownSchedules = portShutdownScheduleStore.load(activeAt: date)
        portShutdownScheduleStore.save(portShutdownSchedules, activeAt: date)
        for schedule in portShutdownSchedules { armPortShutdownExpiry(for: schedule) }
    }

    private func armPortShutdownExpiry(for schedule: PortShutdownSchedule) {
        portShutdownExpiryTasks[schedule.id]?.cancel()
        let id = schedule.id
        let deadline = schedule.deadline
        portShutdownExpiryTasks[id] = Task { [weak self] in
            let delay = max(0, deadline.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.expirePortShutdownSchedule(id: id, expectedDeadline: deadline)
        }
    }

    private func expirePortShutdownSchedule(id: String, expectedDeadline: Date) {
        guard let current = portShutdownSchedules.first(where: { $0.id == id }),
              current.deadline == expectedDeadline else { return }
        let now = Date()
        guard current.deadline <= now else {
            // A wall-clock correction moved the deadline back into the future.
            armPortShutdownExpiry(for: current)
            return
        }
        portShutdownSchedules.removeAll { $0.id == id }
        if !preferences.demoMode {
            portShutdownScheduleStore.save(portShutdownSchedules, activeAt: now)
        }
        portShutdownExpiryTasks[id] = nil
    }

    /// What a failed write means for the person holding the charger — never how
    /// we know it failed.
    ///
    /// The status byte used to be rendered right here, into the dashboard's
    /// notice card: 「充电器拒绝了命令（状态码 0x11）」. `0x11` decides nothing for
    /// the reader and reads as the app showing its working; it belongs in the
    /// log, and ``noteWriteFailure(_:_:)`` puts it there. So did the fallback,
    /// which printed `localizedDescription` — an English `NSError` sentence
    /// nobody translated, dropped into the middle of a Chinese one.
    ///
    /// Subject-neutral on purpose. Three call sites share this, and *what did
    /// not change* differs for each: a refused port write moved no port, a
    /// refused re-selection still leaves the pixels inside the charger, and a
    /// refused mode write leaves the allocation alone. Naming one of them here
    /// would make the sentence wrong for the other two, so each caller frames
    /// the consequence and this says only what the charger did. The one case
    /// that must not be framed at all is ``SessionError/timedOut``: silence is
    /// not a refusal, and claiming nothing happened would be an assertion the
    /// link cannot support.
    private static func describe(_ error: Error) -> String {
        if let settingError = error as? ChargerSettingError {
            return settingError.errorDescription ?? L10n.text("操作没有完成。")
        }
        if let sessionError = error as? SessionError {
            switch sessionError {
            case .notReady: return L10n.text("连接还没就绪，命令没有发出去。")
            case .writesDisabled: return L10n.text("写入开关还没打开，命令没有发出去。")
            case .timedOut: return L10n.text("充电器没有回应，这次操作有没有生效不清楚。")
            case .deviceRejected: return L10n.text("充电器拒绝了这次操作。")
            }
        }
        return L10n.text("操作没有完成。")
    }

    /// Files the evidence half of a failed write where somebody can act on it.
    private func noteWriteFailure(_ what: String, _ error: Error) {
        diagnostics.record("WRITE", "\(what) failed: \(Self.diagnostic(for: error))")
    }

    /// The opcode, the status byte, the raw error. Deliberately untranslated,
    /// for the reason ``coverEvidence(_:)`` gives: a log line that changes shape
    /// with the reader's language is one nobody can grep.
    private static func diagnostic(for error: Error) -> String {
        guard let sessionError = error as? SessionError else { return "\(error)" }
        switch sessionError {
        case .notReady:
            return "session not ready"
        case .writesDisabled:
            return "writes disabled"
        case .timedOut(let opcode):
            return String(format: "0x%04X timed out", Int(opcode))
        case .deviceRejected(let opcode, let status):
            return String(format: "0x%04X rejected, status 0x%02X", Int(opcode), Int(status))
        }
    }

    // MARK: - Display settings

    /// Why the confirmed display controls cannot write right now.
    ///
    /// The frame shapes were physically verified on v0.0.5.2. Keeping an exact
    /// firmware allow-list is intentional: a future firmware can still be read,
    /// but Charker will not silently assume its write contract stayed identical.
    /// The demo fixture reports that same version and implements the same ACK +
    /// reconnect/read-back path, so these reversible controls remain useful in
    /// simulation without weakening the real-hardware gate.
    var chargerSettingBlocker: String? {
        guard session != nil, snapshot.phase.isLive else {
            return L10n.text("需要先连上充电器")
        }
        let reportedVersion = snapshot.deviceInfo.firmwareVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let version = reportedVersion.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
        guard version == "0.0.5.2" else {
            return L10n.text("这些写入目前只在固件 v0.0.5.2 上验证过")
        }
        return nil
    }

    var isChangingChargerSetting: Bool {
        guard let outcome = chargerSettingChange?.outcome else { return false }
        return outcome == .sending || outcome == .reconnecting
    }

    /// Sends a confirmed display-setting command, reconnects, and then lets
    /// `resolveChargerSettingChange` compare the new handshake snapshot.
    func setChargerSetting(_ setting: ChargerSetting) {
        guard chargerSettingBlocker == nil, let session else { return }
        guard !isChangingChargerSetting, chargingModeChange?.outcome != .sending else { return }

        let change = ChargerSettingChange(setting: setting, outcome: .sending)
        noteChargerSettingChange(change, clearAfter: nil)
        Task { [weak self] in
            do {
                try await session.setChargerSetting(setting)
                guard let self, self.chargerSettingChange?.id == change.id else { return }
                var reconnecting = change
                reconnecting.outcome = .reconnecting
                reconnecting.verificationStartedAt = Date()
                self.noteChargerSettingChange(reconnecting, clearAfter: nil)
                self.beginChargerSettingVerificationTimeout(for: reconnecting)
                await session.reconnectNow()
            } catch {
                guard let self, self.chargerSettingChange?.id == change.id else { return }
                self.noteWriteFailure(
                    String(format: "display setting 0x%04X", Int(setting.opcode)), error
                )
                var failed = change
                failed.outcome = .failed(Self.describe(error))
                self.noteChargerSettingChange(failed, clearAfter: 10)
            }
        }
    }

    private func beginChargerSettingVerificationTimeout(for change: ChargerSettingChange) {
        chargerSettingVerificationTask?.cancel()
        chargerSettingVerificationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self,
                  var current = self.chargerSettingChange,
                  current.id == change.id, current.outcome == .reconnecting else { return }
            if current.setting.readbackMatches(nil) == nil {
                // Language has no read-back field. Its successful ACK remains a
                // firm fact even if the monitoring link did not return in time.
                current.outcome = .accepted
                self.noteChargerSettingChange(current, clearAfter: 8)
            } else {
                current.outcome = .unconfirmed
                self.noteChargerSettingChange(current, clearAfter: nil)
            }
        }
    }

    private func noteChargerSettingChange(
        _ change: ChargerSettingChange?, clearAfter seconds: Double?
    ) {
        chargerSettingClearTask?.cancel()
        chargerSettingClearTask = nil
        if change == nil || change?.outcome != .reconnecting {
            chargerSettingVerificationTask?.cancel()
            chargerSettingVerificationTask = nil
        }
        chargerSettingChange = change
        guard change != nil, let seconds else { return }
        chargerSettingClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.chargerSettingChange = nil
        }
    }

    // MARK: - 充电模式

    /// Why the charging mode cannot be switched right now, in one sentence, or
    /// nil when it can.
    ///
    /// A greyed-out control with no reason attached leaves the user guessing why
    /// it cannot be used. Demo telemetry currently has no charging-mode field,
    /// so the UI renders a reading dash and never offers the picker; it needs no
    /// separate mode-wide prohibition here.
    ///
    /// Deliberately does **not** consult `writesEnabled`, for the reason
    /// ``ChargerSession/setChargingMode(_:)`` sets out: that switch is the port
    /// opt-in, its label talks about cutting power to a port, and this write
    /// cuts nothing off.
    var chargingModeBlocker: String? {
        guard session != nil, snapshot.phase.isLive else {
            return L10n.text("需要先连上充电器")
        }
        return nil
    }

    /// Switches the charger's power-allocation mode.
    ///
    /// **A `false` here is not a failure, and must never be reported as one.**
    /// ``ChargerSession/setChargingMode(_:)`` returns `true` only when the
    /// settings field came back holding the code that was sent. It returns
    /// `false` for two situations that look identical from this side: the write
    /// did nothing, and the write worked while the settings snapshot — which is
    /// taken at handshake time — simply does not move until the next link.
    /// Which of the two this firmware does has never been established. Calling
    /// that 「失败」 would send the user to retry a write that may well have
    /// landed, and every retry re-negotiates the charger's allocation for real.
    /// So the honest report is that the command went out and this connection
    /// cannot show the result yet.
    ///
    /// A thrown error is the failure case, and only that.
    func setChargingMode(_ mode: ChargingMode) {
        guard chargingModeBlocker == nil, let session else { return }
        guard chargingModeChange?.outcome != .sending, !isChangingChargerSetting else { return }
        noteChargingModeChange(
            ChargingModeChange(mode: mode, outcome: .sending), clearAfter: nil
        )
        Task { [weak self] in
            do {
                let confirmed = try await session.setChargingMode(mode)
                await MainActor.run { self?.finishChargingModeChange(mode, confirmed: confirmed) }
            } catch {
                await MainActor.run { self?.failChargingModeChange(mode, error) }
            }
        }
    }

    private func finishChargingModeChange(_ mode: ChargingMode, confirmed: Bool) {
        diagnostics.record(
            "WRITE",
            String(format: "charging mode 0x%02X: settings read-back ", Int(mode.code))
                + (confirmed ? "matches" : "unchanged")
        )
        guard confirmed else {
            // Left standing rather than timed out. The note ends by asking the
            // user to reconnect and look at the row again, which is not an
            // errand anyone should have to hold in their head while a countdown
            // runs; `retireChargingModeNoteIfAnswered` takes it down the moment
            // the row can answer for itself.
            noteChargingModeChange(
                ChargingModeChange(mode: mode, outcome: .unconfirmed), clearAfter: nil
            )
            return
        }
        noteChargingModeChange(
            ChargingModeChange(mode: mode, outcome: .confirmed), clearAfter: 6
        )
    }

    private func failChargingModeChange(_ mode: ChargingMode, _ error: Error) {
        noteWriteFailure(String(format: "charging mode 0x%02X", Int(mode.code)), error)
        noteChargingModeChange(
            ChargingModeChange(mode: mode, outcome: .failed(Self.describe(error))),
            clearAfter: 10
        )
    }

    private func noteChargingModeChange(
        _ change: ChargingModeChange?, clearAfter seconds: Double?
    ) {
        chargingModeClearTask?.cancel()
        chargingModeClearTask = nil
        chargingModeChange = change
        guard change != nil, let seconds else { return }
        chargingModeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.chargingModeChange = nil
        }
    }

    // MARK: - Anker account

    /// Signs in to Anker once, purely to read the account id the charger checks.
    /// The password is used for this one request and never stored, logged, or
    /// reused; the auth token that comes back is discarded.
    func signIn(email: String, password: String, country: String) async -> Bool {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            let account = try await AnkerAccountClient().login(
                email: email, password: password, country: country
            )
            accountNickname = account.nickname
            preferences.ownerUserID = account.userID
            setActionMessage(L10n.text("已获取账号 ID，正在用它重新连接充电器"))
            return true
        } catch is CancellationError {
            return false
        } catch {
            signInError = (error as? AnkerLoginError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func clearSignInError() {
        signInError = nil
    }

    /// Best guess at the account's region, only used to prefill the picker.
    /// Falls back to a code Anker actually accepts if the Mac's region is not one.
    var defaultCountryCode: String {
        let system = Locale.current.region?.identifier ?? ""
        return AnkerRegion.named(system)?.code ?? "CN"
    }

    func exportDiagnostics() {
        let header: [String: String] = [
            "app": "Charker \(versionText ?? "dev")",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "mode": preferences.demoMode ? "demo" : "bluetooth",
            "device": snapshot.deviceInfo.productName ?? "unknown",
            "firmware": snapshot.deviceInfo.firmwareVersion ?? "unknown",
            "serial": Redact.identifier(snapshot.deviceInfo.serialNumber),
            "mac": Redact.mac(snapshot.deviceInfo.macAddress),
            "phase": snapshot.statusLabel,
        ]
        let text = diagnostics.export(header: header)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = L10n.text("charker-诊断.txt")
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            setActionMessage(L10n.text("诊断已保存"))
        } catch {
            setActionMessage(L10n.format("导出失败：%@", error.localizedDescription))
        }
    }
}

/// A charging-mode switch, as the settings card has to see it.
///
/// Four outcomes rather than a `Bool` plus a message, because the third one is
/// the whole point: the charger's settings field is a handshake-time snapshot,
/// and an unchanged read-back after a write covers both 「写没生效」 and 「写生效
/// 了，快照要到下一次连接才动」. Nothing distinguishes them from this side, so
/// ``unconfirmed`` is its own outcome sitting between success and failure, and
/// the card is obliged to say so instead of picking one.
struct ChargingModeChange: Equatable {
    enum Outcome: Equatable {
        /// The command is out and the read-back has not come back yet.
        case sending
        /// The settings field came back holding the code that was sent. The one
        /// self-proving result any write in this protocol can produce.
        case confirmed
        /// The command went out and this connection cannot show whether it took.
        /// Not a failure — see ``AppModel/setChargingMode(_:)``.
        case unconfirmed
        /// The charger refused, or the link never got the command out. Carries
        /// the sentence to show, which never names a status byte.
        case failed(String)
    }

    var mode: ChargingMode
    var outcome: Outcome
}

/// One confirmed display-setting write as it crosses the reconnect required for
/// a trustworthy settings read-back.
struct ChargerSettingChange: Equatable {
    enum Outcome: Equatable {
        case sending
        case reconnecting
        /// A fresh handshake carried the exact value that was sent.
        case confirmed
        /// The charger ACKed a command whose value has no discovered read-back
        /// field (currently language). This is deliberately weaker than
        /// `confirmed` and the UI says so.
        case accepted
        /// ACKed, but a fresh readable value did not prove the change.
        case unconfirmed
        case failed(String)
    }

    let id: UUID
    var setting: ChargerSetting
    var outcome: Outcome
    /// Timestamp and boundary latch prevent the pre-write settings snapshot from
    /// being mistaken for evidence from the requested reconnect.
    var verificationStartedAt: Date?
    var sawReconnectBoundary: Bool

    init(
        id: UUID = UUID(), setting: ChargerSetting, outcome: Outcome,
        verificationStartedAt: Date? = nil, sawReconnectBoundary: Bool = false
    ) {
        self.id = id
        self.setting = setting
        self.outcome = outcome
        self.verificationStartedAt = verificationStartedAt
        self.sawReconnectBoundary = sawReconnectBoundary
    }
}

/// The 同步屏保 push, as the UI has to see it.
///
/// `phase` is an enum rather than a `Bool` plus a message because the ways this
/// ends are not variations on one sentence: a push can fail four ways that need
/// four different next steps, and it can *succeed* two ways that make different
/// claims about whether anybody watched the screen change.
struct CoverPushState: Equatable {
    enum Phase: Equatable {
        case idle
        case running(CoverTransferProgress)
        case done(CoverTransferOutcome)
        case failed(CoverPushFailure)
        /// A `0x021F` re-sent on its own after ``CoverPushFailure/Remedy/selectionDidNotTake``
        /// took. No pixels moved; the charger simply agreed to show what was
        /// already inside it.
        case reselected(reportedID: UInt16)
    }

    var phase = Phase.idle
    /// Which custom screen this push is about. A result belonging to screen 2
    /// must not be shown under screen 1 after the user clicks another thumbnail.
    var slot: Int?
    /// Set the moment 取消 is pressed. The push only stops at the next slice
    /// boundary, so the button has to stop claiming the stop already happened.
    var isStopping = false

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }
}

/// A failed push, grouped by what the user can do about it.
struct CoverPushFailure: Equatable {
    enum Remedy: Equatable {
        /// Refused, or never answered, before a single pixel went out. Nothing
        /// is in the charger; retrying costs nothing but time.
        case nothingWritten
        /// Slices were already inside the charger when it stopped. They stay
        /// there — no BLE command erases them.
        case interrupted
        /// The charger's own counter disagreed with ours: slices went missing,
        /// so what is now in the slot is an incomplete image.
        case lostSlices
        /// Every slice was acknowledged and the screen still shows something
        /// else. The pixels are in; only the one-frame selection did not take,
        /// and that can be re-sent on its own.
        case selectionDidNotTake
    }

    var remedy: Remedy
    /// One extra sentence for the card, or nil when the remedy's own two lines
    /// have already said everything — see ``AppModel/coverFailureDetail(_:)``.
    var detail: String?
    /// Whether to add the line about this firmware possibly wanting a
    /// cloud-minted id. Only for an explicit refusal.
    var suggestsCloudID: Bool
    var pixelsMayHaveLanded: Bool
    /// The slice indices, status bytes and cover ids, in English, for the
    /// diagnostics log — see ``CoverTransferError/diagnostic``. Never rendered.
    var diagnostic: String
}

/// The three sentences a remedy is worth, kept in one place because they are one
/// fact told to three surfaces.
///
/// Every one of them answers only「充电器里现在有什么、接下来做什么」. None of them
/// names a slice, a status code or a cover id: those decide nothing for the
/// person reading, and a result that arrives with its working attached reads as
/// a result that is not sure of itself.
extension CoverPushFailure.Remedy {
    /// The card's heading: what is now inside the charger.
    var headline: String {
        switch self {
        case .nothingWritten: return L10n.text("一个字节都没写进去")
        case .interrupted: return L10n.text("已经写进去一部分")
        case .lostSlices: return L10n.text("图没有传完整")
        // 「没看到换过来」 rather than 「没换」. This heading covers a read-back
        // that named another picture *and* one that could not be read at all,
        // and only the first is evidence the screen stayed put. The advice under
        // it is the same either way, so the heading must not be the line that
        // claims more than the read did.
        case .selectionDidNotTake: return L10n.text("图传过去了，没看到屏幕换过来")
        }
    }

    /// The line under it: what to do next, and what doing it costs.
    var advice: String {
        switch self {
        case .nothingWritten:
            return L10n.text("这次没有任何数据写进充电器，可以直接再来一次。")
        case .interrupted:
            return L10n.text("停下之前已经写进去的部分留在充电器里，没有命令能删。再推一次是从头完整传一遍，会再占一个位置。")
        // Says the slot cost too. An incomplete image occupies one of the four
        // exactly as a whole one does, so the sentence that omitted it was the
        // one distinction this feature cannot afford to blur.
        case .lostSlices:
            return L10n.text("写进去的是一张不完整的图，充电器不会显示它，也删不掉。再推一次是从头完整传一遍，会再占一个位置。")
        case .selectionDidNotTake:
            return L10n.text("图已经在充电器里了，只差「显示这张」这一步，可以单独再试一次。")
        }
    }

    /// The same outcome for the status line, which has no heading above it to
    /// lean on. ``headline`` cannot be reused there: 「图传过去了，屏幕没换」 under a
    /// title is a result and on its own is a fragment, and the old prefix
    /// 「屏保没能推上去：」 flatly contradicts two of the four.
    var notice: String {
        switch self {
        case .nothingWritten: return L10n.text("屏保没能推上去，充电器里什么都没写进去")
        case .interrupted: return L10n.text("屏保没推完，已经写进去的部分留在充电器里")
        case .lostSlices: return L10n.text("屏保没有传完整，充电器不会显示它")
        case .selectionDidNotTake: return L10n.text("图已经传进充电器，没看到屏幕换过来")
        }
    }
}
