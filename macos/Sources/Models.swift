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
struct LayoutSnapshot: Codable, Identifiable { var id, name: String; var displays: [String]? }
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
    private var portalEntries: [String:(Date,[FileEntry])] = [:]
    @Published var state = DesktopState()
    @Published var error: String?
    @Published var busy = false
    @Published var dropTarget: String?
    @Published var closingFences: Set<String> = []
    @Published var reorderTarget: String?
    @Published var preferences = MacPreferences()
    @Published var gitSummaries: [String:GitSummary] = [:]
    private let queue = DispatchQueue(label: "jp.jiang.pecofence.engine")
    private let gitQueue = DispatchQueue(label:"jp.jiang.pecofence.git",qos:.utility)
    private var gitUpdated: [String:Date] = [:]
    private var gitPending: Set<String> = []
    private var gitFolders: [String:URL] = [:]
    private var previousReply = Data()
    private var refreshing = false
    var changed: (() -> Void)?
    private var preferencesURL: URL { Engine.configDirectory.appendingPathComponent("mac-preferences.json") }
    init() {
        if let bytes = try? Data(contentsOf:preferencesURL) {
            do { preferences = try JSONDecoder().decode(MacPreferences.self,from:bytes) }
            catch { self.error = "Mac preferences could not be read; original file is preserved." }
        }
    }
    func savePreferences() {
        do {
            try FileManager.default.createDirectory(at:Engine.configDirectory,withIntermediateDirectories:true)
            if FileManager.default.fileExists(atPath:preferencesURL.path) {
                let backup = preferencesURL.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at:backup)
                try FileManager.default.copyItem(at:preferencesURL,to:backup)
            }
            try JSONEncoder().encode(preferences).write(to:preferencesURL,options:.atomic)
        } catch { self.error = error.localizedDescription }
    }
    func toggleFilters(_ fence:Fence) {
        if preferences.filteredPortals.contains(fence.id) { preferences.filteredPortals.remove(fence.id) }
        else { preferences.filteredPortals.insert(fence.id) }
        savePreferences()
    }
    func requestGit(_ folder:URL, fenceID:String) {
        gitFolders[fenceID] = folder
        let path = folder.path
        guard !gitPending.contains(path), Date().timeIntervalSince(gitUpdated[path] ?? .distantPast) >= 10 else { return }
        gitPending.insert(path)
        gitQueue.async {
            let summary = GitSummary.read(folder:folder)
            DispatchQueue.main.async {
                self.gitPending.remove(path); self.gitUpdated[path] = Date()
                if self.gitSummaries[path] != summary { self.gitSummaries[path] = summary }
            }
        }
    }
    func refreshGit() {
        let live = Set(state.fences.filter { $0.kind == "folderPortal" }.map(\.id))
        gitFolders = gitFolders.filter { live.contains($0.key) }
        for (id,folder) in gitFolders { requestGit(folder,fenceID:id) }
    }
    var desktop: URL {
        if let path = ProcessInfo.processInfo.environment["PECOFENCE_DESKTOP_DIR"] { return URL(fileURLWithPath:path) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func send(_ command: [String: Any], quiet: Bool = false, completion: ((DesktopState) -> Void)? = nil) {
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
                    completion?(state)
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
        var command: [String: Any] = ["rolledUp":!fence.rolledUp,"geometries":capturedGeometries()]
        if let controller = AppDelegate.shared.fences[fence.id], let screen = controller.panel.screen {
            let frame = controller.layoutFrame, work = screen.visibleFrame
            geometry.x = frame.minX - work.minX; geometry.y = work.maxY - frame.maxY
            geometry.w = frame.width; geometry.workW = work.width; geometry.workH = work.height
            geometry.monitor = DisplayIdentity.identifier(screen)
            if !fence.rolledUp { geometry.h = frame.height }
            if let encoded = try? JSONEncoder().encode(geometry), let value = try? JSONSerialization.jsonObject(with:encoded) {
                command["geometry"] = value
            }
            if let primary = NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                command["mainMonitor"] = NSScreen.screens.first.map(DisplayIdentity.identifier) ?? String(primary.uint32Value)
            }
        }
        update(fence,command)
    }
    func assign(_ urls: [URL], to fence: Fence) {
        send(["op":"assign", "fence":fence.id, "paths": urls.map(\.path)])
    }
    func capturedGeometries() -> [String:Any] {
        var geometries: [String:Any] = [:]
        for (id,controller) in AppDelegate.shared.fences {
            guard let screen = controller.panel.screen else { continue }
            let frame = controller.layoutFrame, work = screen.visibleFrame
            var geometry = controller.fence.geometry
            geometry.monitor = DisplayIdentity.identifier(screen)
            geometry.x = frame.minX-work.minX; geometry.y = work.maxY-frame.maxY
            geometry.w = frame.width; geometry.workW = work.width; geometry.workH = work.height
            if !controller.fence.rolledUp { geometry.h = frame.height }
            if let bytes = try? JSONEncoder().encode(geometry) { geometries[id] = try? JSONSerialization.jsonObject(with:bytes) }
        }
        return geometries
    }
    func saveWorkspace(_ name:String) {
        send(["op":"snapshot-save","name":name,"fingerprint":DisplayIdentity.fingerprint,"geometries":capturedGeometries()]) { state in
            self.preferences.activeWorkspace = state.snapshots.last?.id; self.savePreferences()
            self.changed?()
        }
    }
    func restoreWorkspace(_ snapshot:LayoutSnapshot) {
        send(["op":"snapshot-restore","id":snapshot.id]) { _ in
            self.preferences.activeWorkspace = snapshot.id; self.savePreferences(); self.changed?()
        }
    }
    func cycleWorkspace(step:Int) {
        let snapshots = state.snapshots
        guard !snapshots.isEmpty else { return }
        let index = snapshots.firstIndex(where: { $0.id == preferences.activeWorkspace }) ?? (step > 0 ? -1 : 0)
        restoreWorkspace(snapshots[(index+step+snapshots.count)%snapshots.count])
    }
    func restoreDisplayWorkspace() {
        guard preferences.restoreDisplays, let match = state.snapshots.last(where: { $0.displays?.sorted() == DisplayIdentity.identifiers }) else { return }
        restoreWorkspace(match)
    }
    func entries(_ fence: Fence, directory: URL? = nil) -> [FileEntry] {
        var entries = fence.items
        if fence.kind == "folderPortal", let path = fence.source.path {
            let folder = directory ?? URL(fileURLWithPath: path)
            do {
                if let cached = portalEntries[folder.path], Date().timeIntervalSince(cached.0) < 3 { entries = cached.1 }
                else {
                    entries = try FileManager.default.contentsOfDirectory(at: folder,
                        includingPropertiesForKeys: [.isDirectoryKey,.contentModificationDateKey,.fileSizeKey], options: [.skipsHiddenFiles])
                        .map { url in
                            let info = try url.resourceValues(forKeys: [.isDirectoryKey,.contentModificationDateKey,.fileSizeKey])
                            return FileEntry(id:url.path, path:url.path, name:url.lastPathComponent,
                                isFolder:info.isDirectory ?? false, mtime:Int64(info.contentModificationDate?.timeIntervalSince1970 ?? 0), size:UInt64(info.fileSize ?? 0))
                        }
                portalEntries[folder.path] = (Date(),entries)
                }
            } catch { return [] }
            if preferences.filteredPortals.contains(fence.id) { entries.removeAll(where:DeveloperFilters.hides) }
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
