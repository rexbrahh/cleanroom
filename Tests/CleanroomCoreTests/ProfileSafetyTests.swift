import Testing

@testable import CleanroomCore

@Suite("Phantom Forces mutation boundary")
struct ProfileSafetyTests {
    @Test("network infrastructure remains operator-controlled")
    func networkInfrastructureIsNeverManaged() {
        let profile = CleanroomProfile.phantomForces()
        let mutationIdentifiers =
            profile.applications.flatMap { [$0.bundleIdentifier, $0.executableName] }
            + profile.services.map(\.label)
            + profile.processes.flatMap { [$0.executableName] + $0.relaunchCommand }
            + profile.preferences.flatMap { [$0.domain, $0.key] }
        let forbiddenNetworkTerms = [
            "vpn", "tailscale", "mullvad", "wireguard", "little snitch",
            "littlesnitch", "networkextension", "firewall", "packetfilter",
        ]

        #expect(
            mutationIdentifiers.allSatisfy { identifier in
                forbiddenNetworkTerms.allSatisfy {
                    !identifier.localizedCaseInsensitiveContains($0)
                }
            }
        )
        #expect(
            Set(profile.services.map(\.label)) == [
                "org.nix-community.home.skhd",
                "org.nix-community.home.yabai",
            ])
    }
}
