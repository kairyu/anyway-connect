import Foundation

// ── Config model (v2, multi-profile) ────────────────────────────────────────
// A Profile bundles everything gateway-specific (protocol, authgroup, CSD, LAN,
// endpoints). App-level "general" settings live at the top. Migrates from the
// old v1 flat shape automatically.

struct Endpoint: Codable, Equatable {
    var key: String
    var label: String
    var host: String
    var favorite: Bool = false

    /// Per-endpoint auth group. Blank means "inherit the profile's".
    ///
    /// The auth group is a property of the gateway, not of the profile: the list a
    /// host advertises comes from tunnel groups configured on that appliance, so
    /// two endpoints can legitimately disagree. Overriding is opt-in because in
    /// practice a company's gateways are configured alike — and because a wrong
    /// group doesn't degrade, it fails the connect outright.
    var authgroup: String = ""

    init(key: String, label: String, host: String,
         favorite: Bool = false, authgroup: String = "") {
        self.key = key
        self.label = label
        self.host = host
        self.favorite = favorite
        self.authgroup = authgroup
    }

    /// Written by hand because a synthesised decoder treats every non-optional
    /// property as required and ignores its default, so simply adding a field
    /// breaks every config already on disk. Only `key` and `host` are load-bearing;
    /// everything else falls back to its default when absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        host = try c.decode(String.self, forKey: .host)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        authgroup = try c.decodeIfPresent(String.self, forKey: .authgroup) ?? ""
    }
}

struct LANAccess: Codable {
    var autoAddLocalSubnet: Bool = false
    var manualExceptionRoutes: [String] = []

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        autoAddLocalSubnet = try c.decodeIfPresent(Bool.self, forKey: .autoAddLocalSubnet) ?? false
        manualExceptionRoutes = try c.decodeIfPresent([String].self, forKey: .manualExceptionRoutes) ?? []
    }
}

struct Profile: Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String = "New Profile"
    var protocolName: String = "anyconnect"
    var authgroup: String = ""
    var csdEnabled: Bool = false
    var csdWrapper: String = ""          // blank = auto-discover from openconnect
    var lanAccess: LANAccess = LANAccess()
    var endpoints: [Endpoint] = []

    enum CodingKeys: String, CodingKey {
        case id, name, csdEnabled, csdWrapper, lanAccess, endpoints
        case protocolName = "protocol"
        case authgroup
    }

    init() {}

    /// Tolerant for the same reason as `Endpoint`: nothing here should be able to
    /// fail a whole config load, because the fallback path is destructive.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Profile"
        protocolName = try c.decodeIfPresent(String.self, forKey: .protocolName) ?? "anyconnect"
        authgroup = try c.decodeIfPresent(String.self, forKey: .authgroup) ?? ""
        csdEnabled = try c.decodeIfPresent(Bool.self, forKey: .csdEnabled) ?? false
        csdWrapper = try c.decodeIfPresent(String.self, forKey: .csdWrapper) ?? ""
        lanAccess = try c.decodeIfPresent(LANAccess.self, forKey: .lanAccess) ?? LANAccess()
        endpoints = try c.decodeIfPresent([Endpoint].self, forKey: .endpoints) ?? []
    }

    /// The group to send for a given endpoint: its own if set, else the profile's.
    func effectiveAuthgroup(for endpoint: Endpoint) -> String {
        endpoint.authgroup.isEmpty ? authgroup : endpoint.authgroup
    }

    static func == (l: Profile, r: Profile) -> Bool { l.id == r.id }
}

struct AutoReconnect: Codable {
    var enabled: Bool = false
    var maxRetries: Int = 5
    var retryDelaySeconds: Int = 5

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 5
        retryDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .retryDelaySeconds) ?? 5
    }
}

struct MenubarSettings: Codable {
    var showEndpointName: Bool = true

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        showEndpointName = try c.decodeIfPresent(Bool.self, forKey: .showEndpointName) ?? true
    }
}

struct GeneralSettings: Codable {
    var openconnectPath: String = ""     // blank = auto-detect
    var vpncScript: String = ""          // blank = derive/default
    var externalBrowser: String = ""
    var menubar: MenubarSettings = MenubarSettings()
    var autoReconnect: AutoReconnect = AutoReconnect()

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        openconnectPath = try c.decodeIfPresent(String.self, forKey: .openconnectPath) ?? ""
        vpncScript = try c.decodeIfPresent(String.self, forKey: .vpncScript) ?? ""
        externalBrowser = try c.decodeIfPresent(String.self, forKey: .externalBrowser) ?? ""
        menubar = try c.decodeIfPresent(MenubarSettings.self, forKey: .menubar) ?? MenubarSettings()
        autoReconnect = try c.decodeIfPresent(AutoReconnect.self, forKey: .autoReconnect) ?? AutoReconnect()
    }
}

struct AppConfig: Codable {
    var version: Int = 2
    var general: GeneralSettings = GeneralSettings()
    var profiles: [Profile] = []
    var activeProfileID: String = ""

    enum CodingKeys: String, CodingKey {
        case version, general, profiles, activeProfileID
    }

    init() {}

    /// `version` is deliberately **required**, unlike every other key here.
    ///
    /// load() distinguishes a v2 file from a v1 one by whether this decode
    /// succeeds. Defaulting it would make a v1 config — which has no `version` —
    /// decode as an empty v2 config: migration would be skipped, the endpoints
    /// silently dropped, and the next save() would write the emptiness back. Any
    /// unrelated JSON object would do the same. Letting it throw is what routes
    /// those files to migrateV1, and failing that, to quarantine.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? GeneralSettings()
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID) ?? ""
    }
}

// ── Store ────────────────────────────────────────────────────────────────────

final class ConfigStore {
    static let shared = ConfigStore()

    /// Posted after the config is written. Lets one settings pane react to a
    /// change made in another — e.g. the General pane's "Active profile" popup
    /// picking up a profile that was just added in the Profiles pane.
    static let didChangeNotification = Notification.Name("AnywayConnectConfigDidChange")

    let dir: URL
    let fileURL: URL
    private(set) var config: AppConfig

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        dir = home.appendingPathComponent(".config/anyway-connect", isDirectory: true)
        fileURL = dir.appendingPathComponent("config.json")
        config = AppConfig()
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            NSLog("AnywayConnect: no config; using defaults")
            return
        }
        // Try v2 first.
        if let v2 = try? JSONDecoder().decode(AppConfig.self, from: data), v2.version >= 2 {
            config = v2
            return
        }
        // Fall back to migrating v1.
        if let migrated = Self.migrateV1(data) {
            config = migrated
            save()  // persist migrated form
            NSLog("AnywayConnect: migrated v1 config -> v2")
            return
        }
        // Understood by neither path. Falling back to defaults is survivable; the
        // danger is the next save() flattening whatever is in the file. Move it
        // aside first so the contents are recoverable instead of overwritten.
        quarantineUnreadableFile()
        NSLog("AnywayConnect: config unreadable; using defaults")
    }

    /// Rename an unparseable config out of the way, keeping the original bytes.
    private func quarantineUnreadableFile() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = dir.appendingPathComponent("config.unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: dest)
            NSLog("AnywayConnect: kept unreadable config at \(dest.path)")
        } catch {
            NSLog("AnywayConnect: could not preserve unreadable config: \(error)")
        }
    }

    // v1 shape: { openconnectPath, csdWrapper, vpncScript, externalBrowser,
    //             settings:{protocol,authgroup,lanAccess,menubar,autoReconnect,favorites},
    //             endpoints:[{key,label,host}] }
    private static func migrateV1(_ data: Data) -> AppConfig? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Refuse anything that isn't actually v1.
        //
        // This guard is the difference between a failed decode and data loss. The
        // function used to accept any JSON object, so a *v2* file that failed to
        // decode — which happens the moment a new non-optional key is added,
        // because a synthesised Codable decoder ignores default values and throws
        // on a missing key — would arrive here, produce a profile named "Imported"
        // with zero endpoints, and get written straight back over the original.
        if (obj["version"] as? Int ?? 1) >= 2 { return nil }
        if obj["profiles"] != nil { return nil }
        // Positive evidence of the v1 shape, rather than merely absence of v2.
        guard obj["endpoints"] != nil || obj["settings"] != nil else { return nil }

        var cfg = AppConfig()
        var g = GeneralSettings()
        g.openconnectPath = obj["openconnectPath"] as? String ?? ""
        g.vpncScript = obj["vpncScript"] as? String ?? ""
        g.externalBrowser = obj["externalBrowser"] as? String ?? ""
        let settings = obj["settings"] as? [String: Any] ?? [:]
        if let mb = settings["menubar"] as? [String: Any] {
            g.menubar.showEndpointName = mb["showEndpointName"] as? Bool ?? true
        }
        if let ar = settings["autoReconnect"] as? [String: Any] {
            g.autoReconnect.enabled = ar["enabled"] as? Bool ?? false
            g.autoReconnect.maxRetries = ar["maxRetries"] as? Int ?? 5
            g.autoReconnect.retryDelaySeconds = ar["retryDelaySeconds"] as? Int ?? 5
        }
        cfg.general = g

        var p = Profile()
        p.name = "Imported"
        p.protocolName = settings["protocol"] as? String ?? "anyconnect"
        p.authgroup = settings["authgroup"] as? String ?? ""
        let csd = obj["csdWrapper"] as? String ?? ""
        p.csdWrapper = csd
        p.csdEnabled = !csd.isEmpty
        if let lan = settings["lanAccess"] as? [String: Any] {
            p.lanAccess.autoAddLocalSubnet = lan["autoAddLocalSubnet"] as? Bool ?? false
            p.lanAccess.manualExceptionRoutes = lan["manualExceptionRoutes"] as? [String] ?? []
        }
        let favs = Set(settings["favorites"] as? [String] ?? [])
        if let eps = obj["endpoints"] as? [[String: Any]] {
            p.endpoints = eps.compactMap { e in
                guard let key = e["key"] as? String, let host = e["host"] as? String else { return nil }
                return Endpoint(key: key, label: e["label"] as? String ?? key, host: host,
                                favorite: favs.contains(key))
            }
        }
        cfg.profiles = [p]
        cfg.activeProfileID = p.id
        return cfg
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("AnywayConnect: save failed: \(error)")
        }
        // Always on the main queue: save() can be called from VPNRunner's
        // background connect path, and observers touch UI.
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
    }

    // No first-run seeding. An earlier version created an "Example" profile
    // pointing at vpn.example.com, which was a trap: it was useless, and the
    // Profiles pane refused to delete the last remaining profile, so it could
    // only be edited over. Zero profiles is a legitimate state with its own
    // empty presentation, and it's what a fresh install should show.

    func update(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        repairActiveProfile()
        save()
    }

    /// Keep `activeProfileID` pointing at a profile that actually exists.
    ///
    /// Enforced here rather than at each call site so that deleting the active
    /// profile falls back correctly however it was removed — the Profiles pane,
    /// a future import that replaces the list, or a hand-edited config file.
    /// A caller that already chose a sensible successor (the Profiles pane picks
    /// the neighbouring row) is left alone, since its choice is still valid.
    private func repairActiveProfile() {
        guard let first = config.profiles.first else {
            config.activeProfileID = ""
            return
        }
        if !config.profiles.contains(where: { $0.id == config.activeProfileID }) {
            config.activeProfileID = first.id
        }
    }

    // MARK: - Active profile helpers

    var activeProfile: Profile? {
        config.profiles.first { $0.id == config.activeProfileID } ?? config.profiles.first
    }

    func setActiveProfile(id: String) {
        update { $0.activeProfileID = id }
    }

    func endpoint(inActiveProfile key: String) -> Endpoint? {
        activeProfile?.endpoints.first { $0.key == key }
    }
}
