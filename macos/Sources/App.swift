import AppKit
import SwiftUI
import Carbon

@MainActor final class FencePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class FenceHostingView: NSHostingView<FenceView> {
    let store: DesktopStore
    let fenceID: String
    convenience init(store:DesktopStore, fenceID:String) {
        self.init(rootView:FenceView(store:store,fenceID:fenceID))
    }
    required init(rootView:FenceView) {
        store = rootView.store; fenceID = rootView.fenceID
        super.init(rootView:rootView)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) unsupported") }
    static func fileURLs(from pasteboard:NSPasteboard) -> [URL] {
        let files = pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [NSURL] ?? []
        return files.map { $0 as URL }
    }
    private func droppedURLs(_ sender:NSDraggingInfo) -> [URL] { Self.fileURLs(from:sender.draggingPasteboard) }
    private func accepts(_ sender:NSDraggingInfo) -> Bool {
        store.state.fences.first(where: { $0.id == fenceID })?.kind != "folderPortal" && !droppedURLs(sender).isEmpty
    }
    override func draggingEntered(_ sender:NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        store.dropTarget = fenceID
        return .copy
    }
    override func draggingUpdated(_ sender:NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? .copy : []
    }
    override func draggingExited(_ sender:NSDraggingInfo?) { store.dropTarget = nil }
    override func prepareForDragOperation(_ sender:NSDraggingInfo) -> Bool { accepts(sender) }
    override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
        store.dropTarget = nil
        guard let fence = store.state.fences.first(where: { $0.id == fenceID }), fence.kind != "folderPortal" else { return false }
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { store.error = "Finder did not provide readable file URLs for this drop."; return false }
        store.assign(urls,to:fence)
        return true
    }
    override func concludeDragOperation(_ sender:NSDraggingInfo?) { store.dropTarget = nil }
}

@MainActor final class FenceController: NSObject, NSWindowDelegate {
    let panel: FencePanel
    var fence: Fence
    let store: DesktopStore
    private var applying = false
    private var geometrySave: DispatchWorkItem?
    static var desktopLevel: NSWindow.Level { NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.desktopIconWindow)) + 1) }
    init(fence: Fence, store: DesktopStore) {
        self.fence = fence; self.store = store
        panel = FencePanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        panel.title = fence.title
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces,.stationary,.ignoresCycle,.fullScreenAuxiliary]
        panel.level = Self.desktopLevel
        panel.contentView = FenceHostingView(store:store,fenceID:fence.id)
        panel.delegate = self
        apply(fence)
    }
    func screen(for geometry:Geometry) -> NSScreen? {
        NSScreen.screens.first { String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == geometry.monitor } ?? NSScreen.screens.first
    }
    func apply(_ fence:Fence) {
        self.fence = fence
        applying = true
        panel.title = fence.title
        panel.appearance = store.state.theme == "dark" ? NSAppearance(named:.darkAqua) : store.state.theme == "light" ? NSAppearance(named:.aqua) : nil
        if let screen = screen(for:fence.geometry) {
            let work = screen.visibleFrame, g = fence.geometry
            let width = min(max(220,g.w),work.width)
            let height = fence.rolledUp ? 38 : min(max(160,g.h),work.height)
            let x = min(max(work.minX + g.x,work.minX),work.maxX-width)
            let top = min(max(work.maxY-g.y,work.minY+height),work.maxY)
            panel.setFrame(NSRect(x:x,y:top-height,width:width,height:height),display:true)
        }
        applying = false
    }
    func windowDidMove(_ notification:Notification) {
        guard !applying else { return }
        geometrySave?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.persistGeometry() }
        geometrySave = task
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:task)
    }
    func persistGeometry() {
        guard !applying, !fence.locked, let screen = panel.screen else { return }
        let work = screen.visibleFrame, frame = panel.frame
        let monitor = String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
        store.update(fence,["geometry":["monitor":monitor,"x":frame.minX-work.minX,"y":work.maxY-frame.maxY,
            "w":frame.width,"h":fence.rolledUp ? fence.geometry.h : frame.height,"workW":work.width,"workH":work.height,"anchor":"leftTop"]])
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    let store = DesktopStore()
    var fences: [String:FenceController] = [:]
    var statusItem: NSStatusItem!
    var settings: NSWindow?
    var timer: Timer?
    var hidden = false
    var peeking = false
    var previousApplication: NSRunningApplication?
    var hotkey: EventHotKeyRef?
    var hotkeyHandler: EventHandlerRef?
    var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification:Notification) {
        AppDelegate.shared = self
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier:Bundle.main.bundleIdentifier ?? "jp.jiang.pecofence.mac")
        if let peer = peers.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            peer.activate(options:[]); NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        setupMenus()
        store.changed = { [weak self] in self?.applyState() }
        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh(); self?.refreshPortals() }
        }
        NotificationCenter.default.addObserver(self,selector:#selector(screensChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        registerPeek()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.endPeek() } }
            return event
        }
        if !FileManager.default.fileExists(atPath:Engine.configDirectory.appendingPathComponent("config.json").path) { showSettings() }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline:.now()+4) {
                if self.store.state.fences.isEmpty { fputs("SMOKE FAILED: no panels\n",stderr); exit(1) }
                let pasteboard = NSPasteboard.withUniqueName()
                pasteboard.writeObjects([self.store.desktop as NSURL])
                guard FenceHostingView.fileURLs(from:pasteboard).first?.standardizedFileURL == self.store.desktop.standardizedFileURL else {
                    fputs("SMOKE FAILED: Finder folder pasteboard decoding\n",stderr); exit(1)
                }
                pasteboard.releaseGlobally()
                for controller in self.fences.values {
                    guard controller.panel.isVisible, controller.panel.frame.width >= 220,
                          controller.panel.level == FenceController.desktopLevel else {
                        fputs("SMOKE FAILED: invalid desktop panel\n",stderr); exit(1)
                    }
                }
                self.togglePeek()
                guard self.fences.values.allSatisfy({ $0.panel.level == .floating }) else { exit(1) }
                self.endPeek()
                guard self.fences.values.allSatisfy({ $0.panel.level == FenceController.desktopLevel && $0.panel.isVisible }) else { exit(1) }
                print("SMOKE OK: \(self.fences.count) native desktop panels")
                NSApp.terminate(nil)
            }
        }
    }
    func applicationWillTerminate(_ notification:Notification) {
        timer?.invalidate()
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        showSettings(); return true
    }
    func setupMenus() {
        let main = NSMenu(), app = NSMenu(), edit = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = app; main.addItem(appItem)
        app.addItem(withTitle:"Settings…",action:#selector(showSettings),keyEquivalent:",").target = self
        app.addItem(withTitle:"Quit PecoFence",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem = NSMenuItem(title:"Edit",action:nil,keyEquivalent:""); editItem.submenu = edit; main.addItem(editItem)
        for (title,selector,key) in [("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] {
            edit.addItem(withTitle:title,action:selector,keyEquivalent:key)
        }
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName:"rectangle.split.3x1",accessibilityDescription:"PecoFence")
        let menu = NSMenu()
        for (title,action,key) in [("New fence…",#selector(createFence),""),("Folder portal…",#selector(createPortal),""),("Show / hide fences",#selector(toggleHidden),""),("Peek  ⌘⌥Space",#selector(togglePeek),""),("Settings…",#selector(showSettings),"")] {
            menu.addItem(withTitle:title,action:action,keyEquivalent:key).target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle:"Quit PecoFence",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        statusItem.menu = menu
    }
    func applyState() {
        NSApp.appearance = store.state.theme == "dark" ? NSAppearance(named:.darkAqua) : store.state.theme == "light" ? NSAppearance(named:.aqua) : nil
        let ids = Set(store.state.fences.map(\.id))
        for key in Array(fences.keys) where !ids.contains(key) { fences.removeValue(forKey:key)?.panel.close() }
        for fence in store.state.fences {
            let controller = fences[fence.id] ?? FenceController(fence:fence,store:store)
            fences[fence.id] = controller
            controller.apply(fence)
            controller.panel.level = peeking ? .floating : FenceController.desktopLevel
            if hidden { controller.panel.orderOut(nil) } else { controller.panel.orderFrontRegardless() }
        }
    }
    func refreshPortals() {
        // Directory membership is live and independent of virtual-item config changes.
        if store.state.fences.contains(where: { $0.kind == "folderPortal" }) { store.objectWillChange.send() }
    }
    @objc func screensChanged() { applyState() }
    @objc func toggleHidden() { hidden.toggle(); applyState() }
    @objc func togglePeek() {
        if peeking { endPeek(); return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        peeking = true; hidden = false; applyState()
        NSApp.activate(ignoringOtherApps:true)
        fences.values.first?.panel.makeKeyAndOrderFront(nil)
    }
    func endPeek() {
        guard peeking else { return }; peeking = false; applyState()
        if let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate(options:[])
        }
        previousApplication = nil
    }
    @objc func showSettings() {
        if settings == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:510),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title = "PecoFence"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:SettingsView(store:store))
            window.center(); settings = window
        }
        NSApp.activate(ignoringOtherApps:true); settings?.makeKeyAndOrderFront(nil)
    }
    func prompt(_ title:String, initial:String = "") -> String? {
        NSApp.activate(ignoringOtherApps:true)
        let alert = NSAlert(); alert.messageText = title
        alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel")
        let field = NSTextField(string:initial); field.frame = NSRect(x:0,y:0,width:300,height:24)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    @objc func createFence() {
        if let title = prompt("New fence",initial:"Untitled") { store.send(["op":"create","title":title]) }
    }
    @objc func createPortal() {
        NSApp.activate(ignoringOtherApps:true)
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Create portal"; panel.message = "Choose a folder to browse from your desktop."
        if panel.runModal() == .OK, let url = panel.url { store.send(["op":"create","title":url.lastPathComponent,"path":url.path]) }
    }
    func rename(_ fence:Fence) {
        if let title = prompt("Rename fence",initial:fence.title) { store.update(fence,["title":title]) }
    }
    func addFiles(_ fence:Fence) {
        NSApp.activate(ignoringOtherApps:true)
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.prompt = "Add to fence"
        panel.message = "Files stay in their original locations."
        if panel.runModal() == .OK { store.assign(panel.urls,to:fence) }
    }
    func delete(_ fence:Fence) {
        let alert = NSAlert(); alert.messageText = "Delete \(fence.title)?"
        alert.informativeText = "Files remain on disk. Virtual assignments return to the Desktop fence."
        alert.addButton(withTitle:"Delete fence"); alert.addButton(withTitle:"Cancel")
        NSApp.activate(ignoringOtherApps:true)
        if alert.runModal() == .alertFirstButtonReturn { store.send(["op":"delete","id":fence.id]) }
    }
    func applyRules() {
        let alert = NSAlert(); alert.messageText = "Apply rules to all files?"
        alert.informativeText = "This replaces manual fence assignments. Save a layout first if you want to restore them. Files remain on disk."
        alert.addButton(withTitle:"Apply rules"); alert.addButton(withTitle:"Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.send(["op":"apply-rules"]) }
    }
    func exportConfig() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "pecofence-mac.json"
        if panel.runModal() == .OK, let url = panel.url { store.send(["op":"export","path":url.path]) }
    }
    func importConfig() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            let alert = NSAlert(); alert.messageText = "Replace current configuration?"
            alert.informativeText = "A backup of your current configuration is retained. Windows paths require reassignment on Mac."
            alert.addButton(withTitle:"Import"); alert.addButton(withTitle:"Cancel")
            if alert.runModal() == .alertFirstButtonReturn { store.send(["op":"import","path":url.path]) }
        }
    }
    func registerPeek() {
        var type = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,_,_ in
            DispatchQueue.main.async { AppDelegate.shared.togglePeek() }; return noErr
        },1,&type,nil,&hotkeyHandler)
        let status = RegisterEventHotKey(UInt32(kVK_Space),UInt32(cmdKey | optionKey),EventHotKeyID(signature:0x5045434F,id:1),GetApplicationEventTarget(),0,&hotkey)
        if status != noErr { store.error = "⌘⌥Space is already in use. Peek remains available from the menu bar." }
    }
}

@main struct PecoFenceMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
