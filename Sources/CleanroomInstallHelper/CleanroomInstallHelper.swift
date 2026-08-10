import Darwin
import Foundation

enum TransactionalAppInstaller {
    static func swap(stagedURL: URL, destinationURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stagedURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard stagedURL.pathExtension == "app", destinationURL.pathExtension == "app" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let result: Int32
        if fileManager.fileExists(atPath: destinationURL.path) {
            result = stagedURL.withUnsafeFileSystemRepresentation { stagedPath in
                destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                    renamex_np(stagedPath, destinationPath, UInt32(RENAME_SWAP))
                }
            }
        } else {
            result = stagedURL.withUnsafeFileSystemRepresentation { stagedPath in
                destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                    rename(stagedPath, destinationPath)
                }
            }
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: destinationURL.path]
            )
        }
    }
}

@main
struct CleanroomInstallHelper {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try TransactionalAppInstaller.swap(
            stagedURL: URL(fileURLWithPath: CommandLine.arguments[1]),
            destinationURL: URL(fileURLWithPath: CommandLine.arguments[2])
        )
    }
}
