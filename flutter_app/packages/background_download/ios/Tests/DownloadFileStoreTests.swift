import Foundation

// Run with the production helper using swiftc (no Flutter engine or device required).
private final class DeniedMoveManager: FileManager {
  let source: URL
  let denyCopy: Bool
  var copies = 0

  init(source: URL, denyCopy: Bool = false) {
    self.source = source
    self.denyCopy = denyCopy
    super.init()
  }

  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    if srcURL == source {
      throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
    try super.moveItem(at: srcURL, to: dstURL)
  }

  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    copies += 1
    if denyCopy {
      // A failed copy may have created a partial destination.
      try Data([0]).write(to: dstURL)
      throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    }
    try super.copyItem(at: srcURL, to: dstURL)
  }
}

@main
enum DownloadFileStoreTests {
  static func main() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory
      .appendingPathComponent("agp-download-tests-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let source = directory.appendingPathComponent("CFNetworkDownload_test.tmp")
    let target = directory.appendingPathComponent("episode.mp4")
    let original = Data([1, 2, 3])
    let replacement = Data([4, 5, 6, 7])

    try original.write(to: source)
    try DownloadFileStore.save(source, to: target)
    let saved = try Data(contentsOf: target)
    precondition(saved == original && !manager.fileExists(atPath: source.path))

    try replacement.write(to: source)
    try DownloadFileStore.save(source, to: target)
    let replaced = try Data(contentsOf: target)
    precondition(replaced == replacement)

    // A readable system temp file can still be saved when moving it is denied.
    try original.write(to: source)
    let denied = DeniedMoveManager(source: source)
    try DownloadFileStore.save(source, to: target, manager: denied)
    let copied = try Data(contentsOf: target)
    precondition(copied == original && denied.copies == 1)
    precondition(manager.fileExists(atPath: source.path)) // URLSession owns cleanup.

    // Neither the existing target nor partial data is published after a failed copy.
    let deniedCopy = DeniedMoveManager(source: source, denyCopy: true)
    do {
      try DownloadFileStore.save(source, to: target, manager: deniedCopy)
      preconditionFailure("Expected a copy failure")
    } catch {
      let description = downloadErrorDescription(error)
      precondition(description.contains("NSCocoaErrorDomain \(NSFileWriteNoPermissionError)"))
      precondition(description.contains("NSCocoaErrorDomain \(NSFileWriteOutOfSpaceError)"))
    }
    let preserved = try Data(contentsOf: target)
    precondition(preserved == original)
    let remaining = try manager.contentsOfDirectory(atPath: directory.path)
    precondition(Set(remaining) == Set([source.lastPathComponent, target.lastPathComponent]))

    // A missing source must not erase an already downloaded video.
    try manager.removeItem(at: source)
    do {
      try DownloadFileStore.save(source, to: target)
      preconditionFailure("Expected a missing source failure")
    } catch {}
    let afterMissing = try Data(contentsOf: target)
    precondition(afterMissing == original)

    let part = directory.appendingPathComponent("episode.mp4.part")
    try replacement.write(to: part)
    try DownloadFileStore.promote(part, to: target)
    let resumed = try Data(contentsOf: target)
    precondition(resumed == replacement && !manager.fileExists(atPath: part.path))

    let underlying = NSError(domain: NSPOSIXErrorDomain, code: 13)
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
      userInfo: [NSUnderlyingErrorKey: underlying, "resumeData": "do-not-display"])
    let description = downloadErrorDescription(error)
    precondition(description.contains("NSCocoaErrorDomain \(NSFileWriteNoPermissionError)"))
    precondition(description.contains("NSPOSIXErrorDomain 13"))
    precondition(!description.contains("do-not-display"))
    print("DownloadFileStore tests passed")
  }
}
