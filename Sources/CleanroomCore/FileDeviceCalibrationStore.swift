import Foundation

public actor FileDeviceCalibrationStore: DeviceCalibrationPersisting {
    public nonisolated let calibrationsURL: URL
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(
        directoryURL: URL = CleanroomPaths.applicationSupportDirectory,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.calibrationsURL = directoryURL.appendingPathComponent("device-calibrations.json")
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    public func calibration(for hardwareIdentifier: String) throws -> DeviceCalibration? {
        try load().first { $0.hardwareIdentifier == hardwareIdentifier }
    }

    public func saveCalibration(_ calibration: DeviceCalibration) throws {
        try calibration.validate()
        var calibrations = try load()
        calibrations.removeAll { $0.hardwareIdentifier == calibration.hardwareIdentifier }
        calibrations.insert(calibration, at: 0)
        calibrations = Array(calibrations.prefix(8))
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encoder.encode(calibrations).write(to: calibrationsURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: calibrationsURL.path
            )
        } catch {
            throw CleanroomError.persistenceFailed("device calibration: \(error.localizedDescription)")
        }
    }

    private func load() throws -> [DeviceCalibration] {
        guard fileManager.fileExists(atPath: calibrationsURL.path) else { return [] }
        do {
            let calibrations = try decoder.decode(
                [DeviceCalibration].self,
                from: Data(contentsOf: calibrationsURL)
            )
            for calibration in calibrations { try calibration.validate() }
            return calibrations
        } catch let error as CleanroomError {
            throw error
        } catch {
            throw CleanroomError.invalidCalibration(error.localizedDescription)
        }
    }
}
