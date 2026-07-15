import Foundation

public struct CleanroomProfile: Codable, Equatable, Sendable {
    public static let robloxBundleIdentifier = "com.roblox.RobloxPlayer"

    public let name: String
    public let applications: [ManagedApplication]
    public let services: [ManagedService]
    public let processes: [ManagedProcess]
    public let preferences: [PreferenceAction]
    public let processCPUWarningPercent: Double
    public let processCPUCriticalPercent: Double
    public let blockAutomaticEntryOnCriticalPreflight: Bool

    public init(
        name: String,
        applications: [ManagedApplication],
        services: [ManagedService],
        processes: [ManagedProcess],
        preferences: [PreferenceAction],
        processCPUWarningPercent: Double = 20,
        processCPUCriticalPercent: Double = 50,
        blockAutomaticEntryOnCriticalPreflight: Bool = false
    ) {
        self.name = name
        self.applications = applications
        self.services = services
        self.processes = processes
        self.preferences = preferences
        self.processCPUWarningPercent = processCPUWarningPercent
        self.processCPUCriticalPercent = processCPUCriticalPercent
        self.blockAutomaticEntryOnCriticalPreflight = blockAutomaticEntryOnCriticalPreflight
    }

    public static func phantomForces(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let launchAgents = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)

        return Self(
            name: "Roblox / Phantom Forces",
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
                .init(name: "Raycast", bundleIdentifier: "com.raycast.macos", executableName: "Raycast"),
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
}
