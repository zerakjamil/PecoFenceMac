import AppKit
import Foundation

struct Geometry: Codable {
    var monitor: String
    var x, y, w, h, workW, workH: Double
    var anchor: String
}
struct FileEntry: Codable, Identifiable {
    var id, path, name: String
    var isFolder: Bool
    var mtime: Int64
    var size: UInt64
}
struct FolderSource: Codable { var kind: String; var path: String? }
struct Fence: Codable, Identifiable {
    var id, title, kind: String
    var source: FolderSource
    var geometry: Geometry
    var rolledUp, locked: Bool
    var view, sort: String
    var items: [FileEntry]
}
struct RoutingRule: Codable, Identifiable { var id, name: String }
struct LayoutSnapshot: Codable, Identifiable { var id, name: String }
struct DesktopState: Codable {
    var fences: [Fence] = []
    var rules: [RoutingRule] = []
    var snapshots: [LayoutSnapshot] = []
    var theme = "system"
    var keepUpdated = true
    var configPath: String?
    var recoveryWarning: String?
}
struct EngineReply: Codable { var ok: Bool; var state: DesktopState?; var error: String? }

enum Engine {
    static var configDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["PECOFENCE_CONFIG_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PecoFence", isDirectory: true)
    }
    static func request(_ command: [String: Any]) throws -> (DesktopState, Data) {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pecofence-mac-cli")
        process.arguments = ["--config-dir", configDirectory.path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: command))
        try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let reply = try JSONDecoder().decode(EngineReply.self, from: bytes)
        guard process.terminationStatus == 0, reply.ok, let state = reply.state else {
            throw NSError(domain: "PecoFence", code: 1, userInfo: [NSLocalizedDescriptionKey: reply.error ?? "Engine failed"])
        }
        return (state, bytes)
    }
}

@MainActor final class DesktopStore: ObservableObject {
    @Published var state = DesktopState()
    @Published var error: String?
    @Published var busy = false
    @Published var dropTarget: String?
    private let queue = DispatchQueue(label: "jp.jiang.pecofence.engine")
    private var previousReply = Data()
    private var refreshing = false
    var changed: (() -> Void)?
    var desktop: URL {
        if let path = ProcessInfo.processInfo.environment["PECOFENCE_DESKTOP_DIR"] { return URL(fileURLWithPath:path) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func send(_ command: [String: Any], quiet: Bool = false) {
        if !quiet { busy = true }
        queue.async {
            do {
                let (state, bytes) = try Engine.request(command)
                DispatchQueue.main.async {
                    self.busy = false; self.refreshing = false
                    if self.previousReply != bytes {
                        self.state = state; self.previousReply = bytes; self.changed?()
                    }
                    if !quiet { self.error = nil }
                    if let warning = state.recoveryWarning { self.error = warning }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.busy = false; self.refreshing = false
                    if self.error != message { self.error = message }
                }
            }
        }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        send(["op":"sync", "desktop": desktop.path], quiet: true)
    }
    func update(_ fence: Fence, _ values: [String: Any]) {
        send(["op":"update", "id":fence.id].merging(values) { _, new in new })
    }
    func toggleCollapsed(_ fence: Fence) {
        var geometry = fence.geometry
        var command: [String: Any] = ["rolledUp":!fence.rolledUp]
        if let controller = AppDelegate.shared.fences[fence.id], let screen = controller.panel.screen {
            let frame = controller.panel.frame, work = screen.visibleFrame
            geometry.x = frame.minX - work.minX; geometry.y = work.maxY - frame.maxY
            geometry.w = frame.width; geometry.workW = work.width; geometry.workH = work.height
            if !fence.rolledUp { geometry.h = frame.height }
            if let encoded = try? JSONEncoder().encode(geometry), let value = try? JSONSerialization.jsonObject(with:encoded) {
                command["geometry"] = value
            }
            if let primary = NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                command["mainMonitor"] = String(primary.uint32Value)
            }
        }
        update(fence,command)
    }
    func assign(_ urls: [URL], to fence: Fence) {
        send(["op":"assign", "fence":fence.id, "paths": urls.map(\.path)])
    }
    func entries(_ fence: Fence, directory: URL? = nil) -> [FileEntry] {
        var entries = fence.items
        if fence.kind == "folderPortal", let path = fence.source.path {
            let folder = directory ?? URL(fileURLWithPath: path)
            do {
                entries = try FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: [.isDirectoryKey,.contentModificationDateKey,.fileSizeKey], options: [.skipsHiddenFiles])
                    .map { url in
                        let info = try url.resourceValues(forKeys: [.isDirectoryKey,.contentModificationDateKey,.fileSizeKey])
                        return FileEntry(id:url.path, path:url.path, name:url.lastPathComponent,
                            isFolder:info.isDirectory ?? false, mtime:Int64(info.contentModificationDate?.timeIntervalSince1970 ?? 0), size:UInt64(info.fileSize ?? 0))
                    }
            } catch { return [] }
        }
        switch fence.sort {
        case "date": entries.sort { $0.mtime > $1.mtime }
        case "type": entries.sort { URL(fileURLWithPath:$0.path).pathExtension < URL(fileURLWithPath:$1.path).pathExtension }
        case "manual": break
        default: entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return entries
    }
}
