import Foundation

public enum TargetDisposition: String, Codable, Equatable, Sendable {
    case stop
    case leaveRunning
}

public enum TargetFailureSeverity: String, Codable, Equatable, Sendable {
    case blocking
    case warning
}

public struct TargetPolicy: Codable, Equatable, Identifiable, Sendable {
    public var id: String { targetIdentifier }
    public let targetIdentifier: String
    public let disposition: TargetDisposition
    public let restoreOrder: Int
    public let restoreDelayMilliseconds: Int
    public let failureSeverity: TargetFailureSeverity

    public init(
        targetIdentifier: String,
        disposition: TargetDisposition = .stop,
        restoreOrder: Int = 0,
        restoreDelayMilliseconds: Int = 0,
        failureSeverity: TargetFailureSeverity = .blocking
    ) {
        self.targetIdentifier = targetIdentifier
        self.disposition = disposition
        self.restoreOrder = restoreOrder
        self.restoreDelayMilliseconds = restoreDelayMilliseconds
        self.failureSeverity = failureSeverity
    }
}

public struct CleanroomProfile: Codable, Equatable, Sendable {
    public static let robloxBundleIdentifier = "com.roblox.RobloxPlayer"

    public let identifier: String
    public let name: String
    public let triggerBundleIdentifier: String
    public let applications: [ManagedApplication]
    public let services: [ManagedService]
    public let processes: [ManagedProcess]
    public let preferences: [PreferenceAction]
    public let processCPUWarningPercent: Double
    public let processCPUCriticalPercent: Double
    public let blockAutomaticEntryOnCriticalPreflight: Bool
    public let targetPolicies: [TargetPolicy]
    public let suppressBuiltInTrackpadWhenLidOpen: Bool

    public init(
        identifier: String = "custom",
        name: String,
        triggerBundleIdentifier: String = robloxBundleIdentifier,
        applications: [ManagedApplication],
        services: [ManagedService],
        processes: [ManagedProcess],
        preferences: [PreferenceAction],
        processCPUWarningPercent: Double = 20,
        processCPUCriticalPercent: Double = 50,
        blockAutomaticEntryOnCriticalPreflight: Bool = false,
        targetPolicies: [TargetPolicy] = [],
        suppressBuiltInTrackpadWhenLidOpen: Bool = true
    ) {
        self.identifier = identifier
        self.name = name
        self.triggerBundleIdentifier = triggerBundleIdentifier
        self.applications = applications
        self.services = services
        self.processes = processes
        self.preferences = preferences
        self.processCPUWarningPercent = processCPUWarningPercent
        self.processCPUCriticalPercent = processCPUCriticalPercent
        self.blockAutomaticEntryOnCriticalPreflight = blockAutomaticEntryOnCriticalPreflight
        self.targetPolicies = targetPolicies
        self.suppressBuiltInTrackpadWhenLidOpen = suppressBuiltInTrackpadWhenLidOpen
    }

    public static func phantomForces(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)

        return Self(
            identifier: "roblox-phantom-forces",
            name: "Roblox / Phantom Forces",
            triggerBundleIdentifier: robloxBundleIdentifier,
            applications: [
                .init(name: "Thaw", bundleIdentifier: "com.stonerl.Thaw", executableName: "Thaw"),
                .init(
                    name: "Supercharge", bundleIdentifier: "com.sindresorhus.Supercharge", executableName: "Supercharge"
                ),
                .init(
                    name: "BetterDisplay", bundleIdentifier: "pro.betterdisplay.BetterDisplay",
                    executableName: "BetterDisplay"),
                .init(
                    name: "BetterMouse", bundleIdentifier: "com.naotanhaocan.BetterMouse", executableName: "BetterMouse"
                ),
                .init(
                    name: "Bartender", bundleIdentifier: "com.surteesstudios.Bartender", executableName: "Bartender 6"),
                .init(name: "Paste", bundleIdentifier: "com.wiheads.paste-direct", executableName: "Paste"),
                .init(
                    name: "superwhisper", bundleIdentifier: "com.superduper.superwhisper",
                    executableName: "superwhisper"),
                .init(name: "Alfred", bundleIdentifier: "com.runningwithcrayons.Alfred", executableName: "Alfred"),
                .init(name: "CleanShot X", bundleIdentifier: "pl.maketheweb.cleanshotx", executableName: "CleanShot X"),
                .init(
                    name: "BetterTouchTool", bundleIdentifier: "com.hegenberg.BetterTouchTool",
                    executableName: "BetterTouchTool"),
                .init(
                    name: "Hammerspoon", bundleIdentifier: "org.hammerspoon.Hammerspoon", executableName: "Hammerspoon"),
                .init(name: "OBS", bundleIdentifier: "com.obsproject.obs-studio", executableName: "OBS"),
                .init(name: "Discord", bundleIdentifier: "com.hnc.Discord", executableName: "Discord"),
            ],
            services: [
                .init(
                    name: "skhd",
                    label: "org.nix-community.home.skhd",
                    propertyListURL: launchAgents.appendingPathComponent("org.nix-community.home.skhd.plist")
                ),
                .init(
                    name: "yabai",
                    label: "org.nix-community.home.yabai",
                    propertyListURL: launchAgents.appendingPathComponent("org.nix-community.home.yabai.plist")
                ),
            ],
            processes: [
                .init(
                    name: "JankyBorders",
                    executableName: "borders",
                    relaunchCommand: [
                        "/opt/homebrew/bin/borders",
                        "active_color=0xffe1e3e4",
                        "inactive_color=0xff494d64",
                        "width=5.0",
                        "style=round",
                        "hidpi=on",
                    ]
                )
            ],
            preferences: [
                .init(
                    domain: "NSGlobalDomain",
                    key: "com.apple.mouse.linear",
                    kind: .boolean,
                    activeValue: "true"
                ),
                .init(
                    domain: "com.apple.AppleMultitouchTrackpad",
                    key: "USBMouseStopsTrackpad",
                    kind: .boolean,
                    activeValue: "true"
                ),
                .init(
                    domain: "com.apple.driver.AppleBluetoothMultitouch.trackpad",
                    key: "USBMouseStopsTrackpad",
                    kind: .boolean,
                    activeValue: "true"
                ),
                .init(
                    domain: "com.apple.dock",
                    key: "wvous-br-corner",
                    kind: .integer,
                    activeValue: "1",
                    synchronizeProcess: "Dock"
                ),
                .init(
                    domain: "com.apple.dock",
                    key: "wvous-br-modifier",
                    kind: .integer,
                    activeValue: "0",
                    synchronizeProcess: "Dock"
                ),
            ]
        )
    }

    public static func minecraft(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let base = phantomForces(homeDirectory: homeDirectory)
        return Self(
            identifier: "minecraft-competitive",
            name: "Minecraft",
            triggerBundleIdentifier: "com.mojang.minecraftlauncher",
            applications: base.applications,
            services: base.services,
            processes: base.processes,
            preferences: base.preferences,
            processCPUWarningPercent: base.processCPUWarningPercent,
            processCPUCriticalPercent: base.processCPUCriticalPercent,
            blockAutomaticEntryOnCriticalPreflight: base.blockAutomaticEntryOnCriticalPreflight,
            targetPolicies: base.targetPolicies,
            suppressBuiltInTrackpadWhenLidOpen: base.suppressBuiltInTrackpadWhenLidOpen
        )
    }

    public static func builtIn(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Self] {
        [phantomForces(homeDirectory: homeDirectory), minecraft(homeDirectory: homeDirectory)]
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case name
        case triggerBundleIdentifier
        case applications
        case services
        case processes
        case preferences
        case processCPUWarningPercent
        case processCPUCriticalPercent
        case blockAutomaticEntryOnCriticalPreflight
        case targetPolicies
        case suppressBuiltInTrackpadWhenLidOpen
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        name = try container.decode(String.self, forKey: .name)
        triggerBundleIdentifier = try container.decode(String.self, forKey: .triggerBundleIdentifier)
        applications = try container.decode([ManagedApplication].self, forKey: .applications)
        services = try container.decode([ManagedService].self, forKey: .services)
        processes = try container.decode([ManagedProcess].self, forKey: .processes)
        preferences = try container.decode([PreferenceAction].self, forKey: .preferences)
        processCPUWarningPercent = try container.decode(Double.self, forKey: .processCPUWarningPercent)
        processCPUCriticalPercent = try container.decode(Double.self, forKey: .processCPUCriticalPercent)
        blockAutomaticEntryOnCriticalPreflight = try container.decode(
            Bool.self, forKey: .blockAutomaticEntryOnCriticalPreflight)
        targetPolicies = try container.decode([TargetPolicy].self, forKey: .targetPolicies)
        suppressBuiltInTrackpadWhenLidOpen =
            try container.decodeIfPresent(Bool.self, forKey: .suppressBuiltInTrackpadWhenLidOpen) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(name, forKey: .name)
        try container.encode(triggerBundleIdentifier, forKey: .triggerBundleIdentifier)
        try container.encode(applications, forKey: .applications)
        try container.encode(services, forKey: .services)
        try container.encode(processes, forKey: .processes)
        try container.encode(preferences, forKey: .preferences)
        try container.encode(processCPUWarningPercent, forKey: .processCPUWarningPercent)
        try container.encode(processCPUCriticalPercent, forKey: .processCPUCriticalPercent)
        try container.encode(blockAutomaticEntryOnCriticalPreflight, forKey: .blockAutomaticEntryOnCriticalPreflight)
        try container.encode(targetPolicies, forKey: .targetPolicies)
        try container.encode(suppressBuiltInTrackpadWhenLidOpen, forKey: .suppressBuiltInTrackpadWhenLidOpen)
    }
}

public struct CleanroomProfileSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { identifier }
    public let identifier: String
    public let name: String
    public let triggerBundleIdentifier: String

    public init(profile: CleanroomProfile) {
        identifier = profile.identifier
        name = profile.name
        triggerBundleIdentifier = profile.triggerBundleIdentifier
    }
}

public struct ProfileMutationPreview: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(action)\u{0}\(target)" }
    public let action: String
    public let target: String
    public let detail: String
}

public struct ProfileValidationReport: Codable, Equatable, Sendable {
    public let profileIdentifier: String
    public let mutations: [ProfileMutationPreview]
    public let errors: [String]

    public var isValid: Bool { errors.isEmpty }
}

public struct ProfileTransferDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let profile: CleanroomProfile

    public init(schemaVersion: Int = currentSchemaVersion, profile: CleanroomProfile) {
        self.schemaVersion = schemaVersion
        self.profile = profile
    }
}

public struct ProfileImportPreview: Codable, Equatable, Sendable {
    public let profile: CleanroomProfile
    public let validation: ProfileValidationReport
    public let addedMutations: [ProfileMutationPreview]
    public let removedMutations: [ProfileMutationPreview]

    public var canImport: Bool { validation.isValid }
}

extension CleanroomProfile {
    public func applying(_ calibration: DeviceCalibration?) -> Self {
        guard let calibration else { return self }
        return Self(
            identifier: identifier,
            name: name,
            triggerBundleIdentifier: triggerBundleIdentifier,
            applications: applications,
            services: services,
            processes: processes,
            preferences: preferences.map { preference in
                guard preference.domain == "NSGlobalDomain",
                    preference.key == "com.apple.mouse.linear",
                    preference.kind == .boolean
                else { return preference }
                return PreferenceAction(
                    domain: preference.domain,
                    key: preference.key,
                    kind: preference.kind,
                    activeValue: calibration.pointerLinearEnabled ? "true" : "false",
                    synchronizeProcess: preference.synchronizeProcess
                )
            },
            processCPUWarningPercent: processCPUWarningPercent,
            processCPUCriticalPercent: processCPUCriticalPercent,
            blockAutomaticEntryOnCriticalPreflight: blockAutomaticEntryOnCriticalPreflight,
            targetPolicies: targetPolicies,
            suppressBuiltInTrackpadWhenLidOpen: suppressBuiltInTrackpadWhenLidOpen
        )
    }

    public func policy(for targetIdentifier: String) -> TargetPolicy {
        targetPolicies.first { $0.targetIdentifier == targetIdentifier }
            ?? TargetPolicy(targetIdentifier: targetIdentifier)
    }

    public func validationReport() -> ProfileValidationReport {
        let mutations =
            applications.map {
                ProfileMutationPreview(
                    action: "stop application",
                    target: $0.bundleIdentifier,
                    detail: $0.name
                )
            }
            + services.map {
                ProfileMutationPreview(action: "stop service", target: $0.label, detail: $0.name)
            }
            + processes.map {
                ProfileMutationPreview(action: "stop process", target: $0.executableName, detail: $0.name)
            }
            + preferences.map {
                ProfileMutationPreview(
                    action: "set preference",
                    target: "\($0.domain):\($0.key)",
                    detail: $0.activeValue
                )
            }
            + (suppressBuiltInTrackpadWhenLidOpen
                ? [
                    ProfileMutationPreview(
                        action: "suppress built-in trackpad",
                        target: "built-in-trackpad",
                        detail: "When the lid is open and an external pointer is present"
                    )
                ] : [])
        var errors: [String] = []
        if identifier.isEmpty || name.isEmpty || triggerBundleIdentifier.isEmpty {
            errors.append("Profile identifier, name, and trigger bundle ID are required.")
        }
        if !triggerBundleIdentifier.contains(".") {
            errors.append("Trigger bundle ID must use reverse-DNS notation.")
        }
        let targets = mutations.map(\.id)
        if Set(targets).count != targets.count {
            errors.append("Mutation actions and targets must be unique.")
        }
        let forbidden = [
            "vpn", "tailscale", "wireguard", "firewall", "networkextension",
            "little snitch", "littlesnitch", "packetfilter", "route", "dns",
        ]
        let inspected =
            [triggerBundleIdentifier]
            + mutations.flatMap { [$0.target, $0.detail] }
            + processes.flatMap(\.relaunchCommand)
        if inspected.contains(where: { value in
            forbidden.contains { value.localizedCaseInsensitiveContains($0) }
        }) {
            errors.append("Network and security infrastructure cannot be managed by a profile.")
        }
        if services.contains(where: {
            $0.label.hasPrefix("com.apple.")
                || !$0.propertyListURL.path.contains("/Library/LaunchAgents/")
        }) {
            errors.append("Services must be user LaunchAgents and cannot be Apple system services.")
        }
        if processCPUWarningPercent < 0 || processCPUCriticalPercent < processCPUWarningPercent {
            errors.append("CPU thresholds must be ordered and non-negative.")
        }
        let policyTargets = Set(
            applications.map(\.bundleIdentifier) + services.map(\.label) + processes.map(\.executableName)
        )
        if Set(targetPolicies.map(\.targetIdentifier)).count != targetPolicies.count
            || targetPolicies.contains(where: { !policyTargets.contains($0.targetIdentifier) })
        {
            errors.append("Target policies must be unique and refer to an application or helper target.")
        }
        if targetPolicies.contains(where: {
            !(0...10_000).contains($0.restoreOrder)
                || !(0...30_000).contains($0.restoreDelayMilliseconds)
        }) {
            errors.append("Restore order must be 0...10000 and delay must be 0...30000 ms.")
        }
        return ProfileValidationReport(
            profileIdentifier: identifier,
            mutations: mutations,
            errors: errors
        )
    }
}
