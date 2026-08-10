import Foundation

public actor FileRecoveryReceiptStore: RecoveryReceiptPersisting {
    public nonisolated let receiptsURL: URL

    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumReceipts: Int

    public init(
        directoryURL: URL = CleanroomPaths.applicationSupportDirectory,
        maximumReceipts: Int = 3,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.receiptsURL = directoryURL.appendingPathComponent("recovery-history.json")
        self.maximumReceipts = max(1, maximumReceipts)
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func saveReceipt(_ receipt: RecoveryReceipt) throws {
        try receipt.validate()
        var receipts = try loadReceipts()
        receipts.removeAll { $0.sessionIdentifier == receipt.sessionIdentifier }
        receipts.insert(receipt, at: 0)
        receipts = Array(receipts.prefix(maximumReceipts))
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try encoder.encode(receipts).write(to: receiptsURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptsURL.path)
        } catch {
            throw CleanroomError.persistenceFailed("recovery receipt: \(error.localizedDescription)")
        }
    }

    public func recentReceipts(limit: Int = 3) throws -> [RecoveryReceipt] {
        Array(try loadReceipts().prefix(max(0, limit)))
    }

    private func loadReceipts() throws -> [RecoveryReceipt] {
        guard fileManager.fileExists(atPath: receiptsURL.path) else { return [] }
        do {
            let receipts = try decoder.decode([RecoveryReceipt].self, from: Data(contentsOf: receiptsURL))
            for receipt in receipts {
                try receipt.validate()
            }
            return receipts.sorted { $0.restoredAt > $1.restoredAt }
        } catch let error as CleanroomError {
            throw error
        } catch {
            throw CleanroomError.invalidReceipt(error.localizedDescription)
        }
    }
}
