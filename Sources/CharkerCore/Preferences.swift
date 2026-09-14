import Foundation

/// A user-defined home camera for the native charger preview. Angles are in
/// degrees and distance is expressed in the SceneKit model's world units.
public struct ModelCameraPose: Sendable, Equatable {
    public var theta: Double
    public var phi: Double
    public var distance: Double

    public init(theta: Double, phi: Double, distance: Double) {
        self.theta = theta
        self.phi = phi
        self.distance = distance
    }

    fileprivate var isUsable: Bool {
        theta.isFinite
            && phi.isFinite && (0...180).contains(phi)
            && distance.isFinite && (0.01...2).contains(distance)
    }

    /// The A2345 viewer uses elevation rather than a polar angle and its
    /// normalized GLB needs a longer camera distance than the A2687 model.
    fileprivate var isUsableA2345: Bool {
        theta.isFinite
            && phi.isFinite && (-90...90).contains(phi)
            && distance.isFinite && (0.1...10).contains(distance)
    }
}

/// Artwork shown on the charger's modelled top display. The live wattage stays
/// in the dashboard instrumentation, so the screen remains a calm identity or
/// personalisation surface instead of looking like a second measurement.
public enum ModelScreenStyle: String, Sendable, Equatable, CaseIterable {
    case ankerPrime
    case custom
}

/// User-visible settings, persisted in `UserDefaults`.
///
/// Nothing here is secret: the client id is a random per-install UUID, not an
/// Anker account, and no session material is ever written to disk.
public struct Preferences: Sendable, Equatable {
    public var template = StatusTemplate.default
    public var decimals = 1
    public var hideIdlePorts = false
    public var showIconOnly = false
    /// Dock icon and full app window. Turning this off returns to a menu-bar-only app.
    public var showDockIcon = true
    public var launchAtLogin = false
    public var demoMode = false
    /// Whether the user has chosen both a charger family and a real/demo route.
    /// Older installs migrate from concrete connection state; a fresh install
    /// stays false so the app does not silently assume the 160 W model.
    public var initialSetupCompleted = false
    /// Which product the simulator presents. Existing installs default to the
    /// original A2687 fixture; choosing A2345 is explicit and reversible.
    public var demoProduct = ChargerProduct.a2687
    /// Preferred real-device route. "bluetooth" preserves every existing
    /// install; "cloud" activates the A2345 account/MQTT session.
    public var connectionMode = "bluetooth"
    /// The A2345 selected from the current Anker account. A serial number is
    /// public device metadata rather than a credential; keeping it here lets a
    /// multi-charger account reconnect to the same unit after relaunch.
    public var a2345SelectedSerial = ""
    public var pollSeconds = 6
    /// Experimental port switching. Default off; the byte layout is cross-checked
    /// between two independent implementations but is unverified on this device.
    public var writesEnabled = false
    public var captureRawPayloads = false
    /// The Anker account id (40 位小写 hex) this charger is bound to. Empty until
    /// the user supplies it. Stored in plain preferences on purpose: it is an
    /// account identifier, not a credential, and the app never sends it anywhere
    /// except to the charger over the local BLE link.
    public var ownerUserID = ""
    /// Last sidebar page, so reopening the window lands where you left it.
    public var lastSection = "dashboard"
    /// Dashboard energy tile scope: "session", "day", "week" or "month".
    public var dashboardEnergyScope = "session"
    /// Requested chart ranges in watts. Zero is automatic. These remain
    /// product-specific so choosing a compact range for the 250 W charger does
    /// not unexpectedly change the familiar 160 W charger's charts.
    public var a2687PowerChartMaximum = PowerChartScale.automatic
    public var a2345PowerChartMaximum = PowerChartScale.automatic
    /// ISO-style currency code and local retail rate used only for an estimated
    /// electricity cost. Zero means the optional estimate is not configured.
    public var energyCurrencyCode = Preferences.defaultEnergyCurrencyCode
    public var energyPricePerKWh = 0.0
    /// User-defined reset angle and zoom for the native three-dimensional model.
    /// `nil` means the built-in product view remains authoritative.
    public var modelHomeCamera: ModelCameraPose?
    /// A2345 has different model units and camera-angle semantics, so its saved
    /// home must never overwrite or reinterpret the A2687 home camera.
    public var a2345ModelHomeCamera: ModelCameraPose?
    /// Idle artwork used by the model's top display. Custom image bytes live in
    /// Application Support; preferences only retain this non-sensitive choice.
    public var modelScreenStyle = ModelScreenStyle.ankerPrime
    /// Stable local slot for the selected custom model screen. Up to three
    /// image payloads live in Application Support; this value stores no image
    /// bytes and safely falls back to the first slot when older data is read.
    public var modelScreenCustomSlot = 0
    /// Window appearance: "system", "light" or "dark".
    public var appearance = "system"
    /// The structured menu-bar layout, JSON-encoded. Authoritative when
    /// non-empty; `template` is derived from it for compatibility. Empty means
    /// "migrate from template on first read".
    public var menuBarItemsJSON = ""
    /// Whether the status item shows its bolt image. Forced on while the
    /// readout is icon-only, so the menu bar can never end up empty.
    public var showsMenuBarIcon = true
    /// SF Symbol name for the status-item icon while the session is live.
    /// Transient states (connecting, stale, failed) keep their own indicator
    /// symbols regardless of this choice.
    public var menuBarIconSymbol = "bolt.fill"
    /// User nicknames for C1/C2/C3/C4/A1/A2 ("MacBook", "iPhone", …).
    /// Always six entries; A2687 simply uses the first three.
    public var portNicknames = Array(repeating: "", count: ChargerPortID.allCases.count)

    public init() {}

    public static var defaultEnergyCurrencyCode: String {
        normalizedCurrencyCode(Locale.current.currency?.identifier ?? "CNY") ?? "CNY"
    }

    public static func normalizedCurrencyCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.utf8.count == 3,
              code.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return code
    }

    /// Converts observed watt-hours into the user's configured retail cost.
    /// Returns nil while no rate is configured or when an input cannot produce
    /// a finite estimate, so the UI never hands NaN/∞ to formatting or Charts.
    public func estimatedEnergyCost(wattHours: Double) -> Double? {
        guard energyPricePerKWh > 0, energyPricePerKWh.isFinite,
              wattHours >= 0, wattHours.isFinite else { return nil }
        let amount = wattHours / 1_000 * energyPricePerKWh
        return amount.isFinite ? amount : nil
    }

    /// The ordered menu-bar layout. Reading migrates legacy template-only
    /// configurations; writing keeps the template string in sync so older
    /// builds (and the raw editor) stay truthful.
    public var menuBarItems: [MenuBarItem] {
        get { MenuBarConfig.decode(menuBarItemsJSON) ?? MenuBarConfig.parse(template) }
        set {
            menuBarItemsJSON = MenuBarConfig.encode(newValue)
            template = MenuBarConfig.serialize(newValue)
        }
    }

    public func powerChartMaximum(for product: ChargerProduct) -> Int {
        switch product {
        case .a2687: a2687PowerChartMaximum
        case .a2345: a2345PowerChartMaximum
        }
    }

    public mutating func setPowerChartMaximum(_ maximum: Int, for product: ChargerProduct) {
        let normalized = PowerChartScale.normalizedPreference(maximum, for: product)
        switch product {
        case .a2687: a2687PowerChartMaximum = normalized
        case .a2345: a2345PowerChartMaximum = normalized
        }
    }
}

public final class PreferencesStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let template = "statusTemplate"
        static let decimals = "statusDecimals"
        static let hideIdlePorts = "hideIdlePorts"
        static let showIconOnly = "showIconOnly"
        static let showDockIcon = "showDockIcon"
        static let launchAtLogin = "launchAtLogin"
        static let demoMode = "demoMode"
        static let initialSetupCompleted = "initialSetupCompleted"
        static let demoProduct = "demoProduct"
        static let connectionMode = "connectionMode"
        static let a2345SelectedSerial = "a2345SelectedSerial"
        static let pollSeconds = "pollSeconds"
        static let writesEnabled = "writesEnabled"
        static let captureRawPayloads = "captureRawPayloads"
        static let ownerUserID = "ownerUserID"
        static let lastSection = "lastSection"
        static let dashboardEnergyScope = "dashboardEnergyScope"
        static let a2687PowerChartMaximum = "a2687PowerChartMaximum"
        static let a2345PowerChartMaximum = "a2345PowerChartMaximum"
        static let energyCurrencyCode = "energyCurrencyCode"
        static let energyPricePerKWh = "energyPricePerKWh"
        static let modelHomeTheta = "modelHomeCameraTheta"
        static let modelHomePhi = "modelHomeCameraPhi"
        static let modelHomeDistance = "modelHomeCameraDistance"
        static let a2345ModelHomeTheta = "a2345ModelHomeCameraTheta"
        static let a2345ModelHomePhi = "a2345ModelHomeCameraPhi"
        static let a2345ModelHomeDistance = "a2345ModelHomeCameraDistance"
        static let modelScreenStyle = "modelScreenStyle"
        static let modelScreenCustomSlot = "modelScreenCustomSlot"
        static let appearance = "appearance"
        static let menuBarItemsJSON = "menuBarItems"
        static let showsMenuBarIcon = "showsMenuBarIcon"
        static let menuBarIconSymbol = "menuBarIconSymbol"
        static let portNicknames = "portNicknames"
        static let clientID = "clientID"
        static let peripheralID = "peripheralID"
    }

    public func load() -> Preferences {
        var prefs = Preferences()
        if let template = defaults.string(forKey: Key.template), !template.isEmpty {
            // The pre-1.0 default carried a redundant ⚡ next to the status
            // item's own bolt image; carry those users to the new default.
            prefs.template = template == "⚡ {total}" ? StatusTemplate.default : template
        }
        if defaults.object(forKey: Key.decimals) != nil {
            prefs.decimals = defaults.integer(forKey: Key.decimals)
        }
        if defaults.object(forKey: Key.pollSeconds) != nil {
            prefs.pollSeconds = max(3, defaults.integer(forKey: Key.pollSeconds))
        }
        prefs.hideIdlePorts = defaults.bool(forKey: Key.hideIdlePorts)
        prefs.showIconOnly = defaults.bool(forKey: Key.showIconOnly)
        prefs.showDockIcon = defaults.object(forKey: Key.showDockIcon) as? Bool ?? true
        prefs.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        prefs.demoMode = defaults.bool(forKey: Key.demoMode)
        if defaults.object(forKey: Key.initialSetupCompleted) != nil {
            prefs.initialSetupCompleted = defaults.bool(forKey: Key.initialSetupCompleted)
        } else {
            // The key did not exist before the two-product onboarding. Avoid
            // interrupting users who already have a concrete device route,
            // while letting an unconfigured older install use the new chooser.
            let hasRememberedBluetoothDevice = defaults.string(forKey: Key.peripheralID) != nil
            let hadCloudRoute = defaults.string(forKey: Key.connectionMode) == "cloud"
            let hadSelectedCloudDevice = !(defaults.string(forKey: Key.a2345SelectedSerial) ?? "").isEmpty
            prefs.initialSetupCompleted = prefs.demoMode
                || hasRememberedBluetoothDevice
                || hadCloudRoute
                || hadSelectedCloudDevice
        }
        if let raw = defaults.string(forKey: Key.demoProduct),
           let product = ChargerProduct(rawValue: raw) {
            prefs.demoProduct = product
        }
        if let mode = defaults.string(forKey: Key.connectionMode),
           ["bluetooth", "cloud"].contains(mode) {
            prefs.connectionMode = mode
        }
        prefs.a2345SelectedSerial = defaults.string(forKey: Key.a2345SelectedSerial) ?? ""
        prefs.writesEnabled = defaults.bool(forKey: Key.writesEnabled)
        prefs.captureRawPayloads = defaults.bool(forKey: Key.captureRawPayloads)
        prefs.ownerUserID = defaults.string(forKey: Key.ownerUserID) ?? ""
        prefs.lastSection = defaults.string(forKey: Key.lastSection) ?? "dashboard"
        if let scope = defaults.string(forKey: Key.dashboardEnergyScope),
           ["session", "day", "week", "month"].contains(scope) {
            prefs.dashboardEnergyScope = scope
        }
        if defaults.object(forKey: Key.a2687PowerChartMaximum) != nil {
            prefs.a2687PowerChartMaximum = PowerChartScale.normalizedPreference(
                defaults.integer(forKey: Key.a2687PowerChartMaximum),
                for: .a2687
            )
        }
        if defaults.object(forKey: Key.a2345PowerChartMaximum) != nil {
            prefs.a2345PowerChartMaximum = PowerChartScale.normalizedPreference(
                defaults.integer(forKey: Key.a2345PowerChartMaximum),
                for: .a2345
            )
        }
        if let currency = defaults.string(forKey: Key.energyCurrencyCode),
           let normalized = Preferences.normalizedCurrencyCode(currency) {
            prefs.energyCurrencyCode = normalized
        }
        if let price = storedDouble(forKey: Key.energyPricePerKWh),
           price.isFinite, price >= 0 {
            prefs.energyPricePerKWh = price
        }
        if let theta = storedDouble(forKey: Key.modelHomeTheta),
           let phi = storedDouble(forKey: Key.modelHomePhi),
           let distance = storedDouble(forKey: Key.modelHomeDistance) {
            let pose = ModelCameraPose(theta: theta, phi: phi, distance: distance)
            if pose.isUsable { prefs.modelHomeCamera = pose }
        }
        if let theta = storedDouble(forKey: Key.a2345ModelHomeTheta),
           let phi = storedDouble(forKey: Key.a2345ModelHomePhi),
           let distance = storedDouble(forKey: Key.a2345ModelHomeDistance) {
            let pose = ModelCameraPose(theta: theta, phi: phi, distance: distance)
            if pose.isUsableA2345 { prefs.a2345ModelHomeCamera = pose }
        }
        if let rawStyle = defaults.string(forKey: Key.modelScreenStyle),
           let style = ModelScreenStyle(rawValue: rawStyle) {
            prefs.modelScreenStyle = style
        }
        if defaults.object(forKey: Key.modelScreenCustomSlot) != nil {
            let slot = defaults.integer(forKey: Key.modelScreenCustomSlot)
            if (0..<3).contains(slot) { prefs.modelScreenCustomSlot = slot }
        }
        if let appearance = defaults.string(forKey: Key.appearance),
           ["system", "light", "dark"].contains(appearance) {
            prefs.appearance = appearance
        }
        prefs.menuBarItemsJSON = defaults.string(forKey: Key.menuBarItemsJSON) ?? ""
        prefs.showsMenuBarIcon = defaults.object(forKey: Key.showsMenuBarIcon) as? Bool ?? true
        if let symbol = defaults.string(forKey: Key.menuBarIconSymbol), !symbol.isEmpty {
            prefs.menuBarIconSymbol = symbol
        }
        if let nicknames = defaults.stringArray(forKey: Key.portNicknames) {
            // Preserve the original three slots and append new A2345 slots.
            prefs.portNicknames = (0..<ChargerPortID.allCases.count).map {
                $0 < nicknames.count ? nicknames[$0] : ""
            }
        }
        // Template-only configurations (pre-items builds) migrate on load, so
        // the structured editor and the title agree from the first frame.
        if prefs.menuBarItemsJSON.isEmpty {
            prefs.menuBarItemsJSON = MenuBarConfig.encode(MenuBarConfig.parse(prefs.template))
        }
        return prefs
    }

    public func save(_ prefs: Preferences) {
        defaults.set(prefs.template, forKey: Key.template)
        defaults.set(prefs.decimals, forKey: Key.decimals)
        defaults.set(prefs.hideIdlePorts, forKey: Key.hideIdlePorts)
        defaults.set(prefs.showIconOnly, forKey: Key.showIconOnly)
        defaults.set(prefs.showDockIcon, forKey: Key.showDockIcon)
        defaults.set(prefs.launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(prefs.demoMode, forKey: Key.demoMode)
        defaults.set(prefs.initialSetupCompleted, forKey: Key.initialSetupCompleted)
        defaults.set(prefs.demoProduct.rawValue, forKey: Key.demoProduct)
        defaults.set(prefs.connectionMode, forKey: Key.connectionMode)
        defaults.set(prefs.a2345SelectedSerial, forKey: Key.a2345SelectedSerial)
        defaults.set(prefs.pollSeconds, forKey: Key.pollSeconds)
        defaults.set(prefs.writesEnabled, forKey: Key.writesEnabled)
        defaults.set(prefs.captureRawPayloads, forKey: Key.captureRawPayloads)
        defaults.set(prefs.ownerUserID, forKey: Key.ownerUserID)
        defaults.set(prefs.lastSection, forKey: Key.lastSection)
        defaults.set(prefs.dashboardEnergyScope, forKey: Key.dashboardEnergyScope)
        defaults.set(
            PowerChartScale.normalizedPreference(prefs.a2687PowerChartMaximum, for: .a2687),
            forKey: Key.a2687PowerChartMaximum
        )
        defaults.set(
            PowerChartScale.normalizedPreference(prefs.a2345PowerChartMaximum, for: .a2345),
            forKey: Key.a2345PowerChartMaximum
        )
        defaults.set(
            Preferences.normalizedCurrencyCode(prefs.energyCurrencyCode)
                ?? Preferences.defaultEnergyCurrencyCode,
            forKey: Key.energyCurrencyCode
        )
        defaults.set(
            prefs.energyPricePerKWh.isFinite ? max(0, prefs.energyPricePerKWh) : 0,
            forKey: Key.energyPricePerKWh
        )
        if let pose = prefs.modelHomeCamera, pose.isUsable {
            defaults.set(pose.theta, forKey: Key.modelHomeTheta)
            defaults.set(pose.phi, forKey: Key.modelHomePhi)
            defaults.set(pose.distance, forKey: Key.modelHomeDistance)
        } else {
            defaults.removeObject(forKey: Key.modelHomeTheta)
            defaults.removeObject(forKey: Key.modelHomePhi)
            defaults.removeObject(forKey: Key.modelHomeDistance)
        }
        if let pose = prefs.a2345ModelHomeCamera, pose.isUsableA2345 {
            defaults.set(pose.theta, forKey: Key.a2345ModelHomeTheta)
            defaults.set(pose.phi, forKey: Key.a2345ModelHomePhi)
            defaults.set(pose.distance, forKey: Key.a2345ModelHomeDistance)
        } else {
            defaults.removeObject(forKey: Key.a2345ModelHomeTheta)
            defaults.removeObject(forKey: Key.a2345ModelHomePhi)
            defaults.removeObject(forKey: Key.a2345ModelHomeDistance)
        }
        defaults.set(prefs.modelScreenStyle.rawValue, forKey: Key.modelScreenStyle)
        defaults.set(prefs.modelScreenCustomSlot, forKey: Key.modelScreenCustomSlot)
        defaults.set(prefs.appearance, forKey: Key.appearance)
        defaults.set(prefs.menuBarItemsJSON, forKey: Key.menuBarItemsJSON)
        defaults.set(prefs.showsMenuBarIcon, forKey: Key.showsMenuBarIcon)
        defaults.set(prefs.menuBarIconSymbol, forKey: Key.menuBarIconSymbol)
        defaults.set(prefs.portNicknames, forKey: Key.portNicknames)
    }

    private func storedDouble(forKey key: String) -> Double? {
        switch defaults.object(forKey: key) {
        case let value as Double: return value
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    /// Stable pseudonymous identifier for this install, generated on first launch.
    ///
    /// A2687 firmware expects the user id as a 40-character lowercase hex string —
    /// the official app sends a hashed account id in that shape. A UUID string,
    /// which the Solix reference implementation uses, is refused with status 0x09.
    /// This is a local random value: it is not an Anker account and never leaves
    /// the Mac except as the identity field of the BLE handshake.
    public func clientID() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = defaults.string(forKey: Key.clientID), Self.isValidClientID(existing) {
            return existing
        }
        let fresh = (0..<20)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }
            .joined()
        defaults.set(fresh, forKey: Key.clientID)
        return fresh
    }

    static func isValidClientID(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Same shape as a client id: 40 lowercase hex characters.
    public static func isValidOwnerUserID(_ value: String) -> Bool {
        isValidClientID(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// CoreBluetooth peripheral identifier for fast reconnects on this Mac.
    public var peripheralID: UUID? {
        get { defaults.string(forKey: Key.peripheralID).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Key.peripheralID) }
    }
}
