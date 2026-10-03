import AppKit
import Quartz

struct MacPreferences: Codable {
    var filteredPortals: Set<String> = []
    var restoreDisplays = true
    var snapReordering = true
    var hideFencedDesktop = false
    var activeWorkspace: String?

    enum CodingKeys: String, CodingKey { case filteredPortals, restoreDisplays, snapReordering, hideFencedDesktop, activeWorkspace }
    init() {}
    init(from decoder:Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        filteredPortals = try values.decodeIfPresent(Set<String>.self,forKey:.filteredPortals) ?? []
        restoreDisplays = try values.decodeIfPresent(Bool.self,forKey:.restoreDisplays) ?? true
        snapReordering = try values.decodeIfPresent(Bool.self,forKey:.snapReordering) ?? true
        hideFencedDesktop = try values.decodeIfPresent(Bool.self,forKey:.hideFencedDesktop) ?? false
        activeWorkspace = try values.decodeIfPresent(String.self,forKey:.activeWorkspace)
    }
}

enum DeveloperFilters {
    static let directories: Set<String> = [".git","node_modules",".build","target","build","dist","coverage","__pycache__",".next",".nuxt","pods","carthage","deriveddata"]
    static func hides(_ file:FileEntry) -> Bool { file.isFolder && directories.contains(file.name.lowercased()) }
}

struct GitSummary: Equatable {
    var branch = ""
    var changed = 0
    var ahead = 0
    var behind = 0
    var label: String {
        var parts = [branch == "(detached)" ? "Detached HEAD" : branch]
        if changed > 0 { parts.append("\(changed) changes") }
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator:" · ")
    }
    static func parse(_ bytes:Data) -> GitSummary {
        let records = String(decoding:bytes,as:UTF8.self).split(separator:"\0",omittingEmptySubsequences:true)
        var summary = GitSummary(), index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# branch.head ") { summary.branch = String(record.dropFirst(14)) }
            else if record.hasPrefix("# branch.ab ") {
                let fields = record.split(separator:" ")
                if fields.count == 4 { summary.ahead = Int(fields[2].dropFirst()) ?? 0; summary.behind = Int(fields[3].dropFirst()) ?? 0 }
            } else if record.hasPrefix("1 ") || record.hasPrefix("u ") || record.hasPrefix("? ") { summary.changed += 1 }
            else if record.hasPrefix("2 ") { summary.changed += 1; index += 1 }
            index += 1
        }
        return summary
    }
    static func read(folder:URL) -> GitSummary? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/git")
        process.arguments = ["--no-optional-locks","-c","core.fsmonitor=false","-c","color.ui=false","-C",folder.path,"status","--porcelain=v2","--branch","-z"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline:.now()+4,execute:timeout)
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let summary = parse(bytes)
        return summary.branch.isEmpty ? nil : summary
    }
}

struct ProjectApplication: Identifiable {
    let id, name: String
    let url: URL
}

@MainActor enum ProjectActions {
    static var applications: [ProjectApplication] {
        [("com.apple.Terminal","Terminal"),("com.microsoft.VSCode","VS Code"),("com.apple.dt.Xcode","Xcode")]
            .compactMap { id, name in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier:id).map { ProjectApplication(id:id,name:name,url:$0) }
            }
    }
    static func folder(for file:FileEntry) -> URL {
        let url = URL(fileURLWithPath:file.path)
        return file.isFolder ? url : url.deletingLastPathComponent()
    }
    static func target(folder:URL, application:ProjectApplication) -> URL? {
        guard application.id == "com.apple.dt.Xcode" else { return folder }
        if ["xcworkspace","xcodeproj"].contains(folder.pathExtension) { return folder }
        let contents = (try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? []
        return contents.filter { $0.pathExtension == "xcworkspace" }.sorted { $0.path < $1.path }.first
            ?? contents.filter { $0.pathExtension == "xcodeproj" }.sorted { $0.path < $1.path }.first
    }
    static func open(folder:URL, application:ProjectApplication, store:DesktopStore) {
        guard let target = target(folder:folder,application:application) else { store.error = "No Xcode project or workspace in this folder."; return }
        NSWorkspace.shared.open([target],withApplicationAt:application.url,configuration:NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { store.error = error.localizedDescription } }
        }
    }
    static func copyPath(_ url:URL) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path,forType:.string)
    }
}

@MainActor final class PreviewCoordinator: NSResponder, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel:QLPreviewPanel!) -> Bool { !urls.isEmpty }
    override func beginPreviewPanelControl(_ panel:QLPreviewPanel!) { attach(panel) }
    override func endPreviewPanelControl(_ panel:QLPreviewPanel!) { detach(panel) }
    var urls: [URL] = []
    private var selectedIndex = 0
    func show(files:[FileEntry], selected:String, window:NSWindow?) {
        urls = files.map { URL(fileURLWithPath:$0.path) }
        selectedIndex = files.firstIndex(where: { $0.id == selected }) ?? 0
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps:true); window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let panel = QLPreviewPanel.shared() else { return }
            window?.makeKeyAndOrderFront(nil); window?.makeMain()
            panel.makeKeyAndOrderFront(nil)
            panel.updateController()
            guard panel.currentController != nil else {
                panel.orderOut(nil)
                AppDelegate.shared.store.error = "Quick Look could not attach to this fence."
                return
            }
            panel.reloadData(); panel.currentPreviewItemIndex = self.selectedIndex
        }
    }
    func attach(_ panel:QLPreviewPanel) { panel.dataSource = self; panel.delegate = self }
    func detach(_ panel:QLPreviewPanel) { panel.dataSource = nil; panel.delegate = nil }
    func numberOfPreviewItems(in panel:QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel:QLPreviewPanel!, previewItemAt index:Int) -> QLPreviewItem! { urls[index] as NSURL }
    func previewPanel(_ panel:QLPreviewPanel!, handle event:NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 || event.keyCode == 53 { panel.orderOut(nil); return true }
        if [123,124,125,126].contains(event.keyCode) {
            let step = [123,126].contains(event.keyCode) ? -1 : 1
            panel.currentPreviewItemIndex = min(max(0,panel.currentPreviewItemIndex+step),urls.count-1)
            return true
        }
        if event.keyCode == 8 && event.modifierFlags.contains(.command), urls.indices.contains(panel.currentPreviewItemIndex) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([urls[panel.currentPreviewItemIndex] as NSURL]); return true
        }
        return false
    }
}

enum DisplayIdentity {
    static func identifier(_ screen:NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() {
            return CFUUIDCreateString(nil,uuid) as String
        }
        return String(number)
    }
    @MainActor static var fingerprint: [[String:Any]] {
        NSScreen.screens.map { ["devicePath":identifier($0),"workDip":[$0.visibleFrame.width,$0.visibleFrame.height],"dpi":96] }
            .sorted { ($0["devicePath"] as? String ?? "") < ($1["devicePath"] as? String ?? "") }
    }
    @MainActor static var identifiers: [String] { NSScreen.screens.map(identifier).sorted() }
}

@MainActor enum FileIcons {
    private static let cache: NSCache<NSString,NSImage> = {
        let cache = NSCache<NSString,NSImage>(); cache.countLimit = 512; return cache
    }()
    static func icon(_ file:FileEntry) -> NSImage {
        let key = "\(file.path):\(file.mtime)" as NSString
        if let image = cache.object(forKey:key) { return image }
        let image = NSWorkspace.shared.icon(forFile:file.path)
        cache.setObject(image,forKey:key); return image
    }
}
