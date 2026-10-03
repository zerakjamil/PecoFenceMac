import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PanelTitle: NSViewRepresentable {
    var title: String
    var locked: Bool
    var portal: Bool
    var collapse: () -> Void
    var rename: () -> Void
    func makeNSView(context: Context) -> TitleDragView { TitleDragView() }
    func updateNSView(_ view: TitleDragView, context: Context) {
        view.label.stringValue = title; view.locked = locked; view.collapse = collapse
        view.rename = rename; view.leading.constant = portal ? 32 : 12
        view.setAccessibilityLabel(title)
        view.setAccessibilityHelp("Click to expand or collapse. Double-click name to rename. Drag to move.")
    }
}
final class TitleDragView: NSView {
    let label = NSTextField(labelWithString: "")
    var locked = false
    var collapse: (() -> Void)?
    var rename: (() -> Void)?
    var leading: NSLayoutConstraint!
    private var pendingClick: DispatchWorkItem?
    override init(frame: NSRect) {
        super.init(frame:frame)
        label.font = .systemFont(ofSize:13, weight:.semibold)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        leading = label.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12)
        NSLayoutConstraint.activate([leading, label.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-80), label.centerYAnchor.constraint(equalTo:centerYAnchor)])
        label.setAccessibilityElement(false)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name:"Rename",target:self,selector:#selector(renameAccessibly))])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) unsupported") }
    override func hitTest(_ point:NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func accessibilityPerformPress() -> Bool { pendingClick?.cancel(); collapse?(); return true }
    @objc func renameAccessibly() -> Bool { pendingClick?.cancel(); rename?(); return true }
    override func mouseDown(with event:NSEvent) {
        pendingClick?.cancel()
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow,from:nil)
            let nameWidth = min(label.intrinsicContentSize.width,label.frame.width)
            if point.x >= label.frame.minX && point.x <= label.frame.minX + nameWidth { rename?() }
            else { collapse?() }
            return
        }
        guard let window else { return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp {
                let click = DispatchWorkItem { [weak self] in self?.collapse?() }
                pendingClick = click
                DispatchQueue.main.asyncAfter(deadline:.now()+NSEvent.doubleClickInterval,execute:click)
                return
            }
            if !locked && hypot(next.locationInWindow.x-start.x,next.locationInWindow.y-start.y) >= 3 {
                window.performDrag(with:event)
                return
            }
        }
    }
}
struct ResizeGrip: NSViewRepresentable {
    var locked: Bool
    func makeNSView(context:Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view:ResizeView, context:Context) { view.locked = locked }
}
final class ResizeView: NSView {
    var locked = false
    override func mouseDown(with event:NSEvent) {
        guard !locked, let window else { return }
        let start = NSEvent.mouseLocation, original = window.frame
        while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = NSEvent.mouseLocation
            let width = max(220, original.width + point.x - start.x)
            let height = max(160, original.height - point.y + start.y)
            window.setFrame(NSRect(x:original.minX,y:original.maxY-height,width:width,height:height), display:true)
        }
        (window.delegate as? FenceController)?.persistGeometry()
    }
    override func draw(_ dirtyRect:NSRect) {
        guard !locked else { return }
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.move(to:NSPoint(x:4,y:3)); path.line(to:NSPoint(x:13,y:12))
        path.move(to:NSPoint(x:8,y:3)); path.line(to:NSPoint(x:13,y:8)); path.stroke()
    }
}

struct FenceView: View {
    @ObservedObject var store: DesktopStore
    let fenceID: String
    @State private var directory: URL?
    @State private var selected: String?
    var fence: Fence? { store.state.fences.first { $0.id == fenceID } }

    var body: some View {
        if let fence {
            VStack(spacing:0) {
                ZStack {
                    PanelTitle(title:fence.title, locked:fence.locked, portal:fence.kind == "folderPortal",
                        collapse:{ store.toggleCollapsed(fence) }, rename:{ AppDelegate.shared.rename(fence) })
                    HStack(spacing:8) {
                    if fence.kind == "folderPortal" { Image(systemName:"folder").foregroundStyle(.secondary).allowsHitTesting(false) }
                    Spacer()
                    if let error = store.error {
                        Button { AppDelegate.shared.showSettings() } label: { Image(systemName:"exclamationmark.triangle") }
                            .buttonStyle(.plain).help(error).accessibilityLabel(error)
                    }
                    Menu {
                        Button("Rename…") { AppDelegate.shared.rename(fence) }
                        Button("Add files…") { AppDelegate.shared.addFiles(fence) }.disabled(fence.kind == "folderPortal")
                        if fence.kind == "folderPortal", let path = fence.source.path {
                            Button("Open folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath:path)) }
                        }
                        Menu("View") {
                            Button("Icons") { store.update(fence,["view":"icons"]) }
                            Button("List") { store.update(fence,["view":"list"]) }
                        }
                        Menu("Sort") {
                            ForEach(["name","type","date","manual"], id:\.self) { sort in
                                Button(sort.capitalized) { store.update(fence,["sort":sort]) }
                            }
                        }
                        Button(fence.locked ? "Unlock position" : "Lock position") { store.update(fence,["locked":!fence.locked]) }
                        Button("Settings…") { AppDelegate.shared.showSettings() }
                        if fence.kind != "inbox" {
                            Divider()
                            Button("Delete fence…") { AppDelegate.shared.delete(fence) }
                        }
                    } label: { Image(systemName:"ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Fence options")
                    Button { store.toggleCollapsed(fence) } label: {
                        Image(systemName:fence.rolledUp ? "chevron.down" : "chevron.up")
                    }.buttonStyle(.plain).accessibilityLabel(fence.rolledUp ? "Expand fence" : "Collapse fence")
                    }.padding(.horizontal,12)
                }.frame(height:38)
                if !fence.rolledUp {
                    Divider()
                    if fence.kind == "folderPortal", let path = fence.source.path {
                        HStack {
                            Button { directory = directory?.deletingLastPathComponent() } label: { Image(systemName:"chevron.left") }
                                .disabled(directory == nil || directory?.path == path).accessibilityLabel("Parent folder")
                            Text(directory?.lastPathComponent ?? URL(fileURLWithPath:path).lastPathComponent)
                                .font(.caption).lineLimit(1)
                            Spacer()
                            Button { directory = nil } label: { Image(systemName:"house") }.accessibilityLabel("Portal root")
                        }.buttonStyle(.plain).padding(.horizontal,12).padding(.vertical,6)
                    }
                    content(fence)
                    HStack {
                        Text("\(store.entries(fence,directory:directory).count) files").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        ResizeGrip(locked:fence.locked).frame(width:18,height:18).accessibilityLabel("Resize fence")
                    }.padding(.leading,12).padding(.trailing,2).frame(height:24)
                }
            }
            .background(DesktopMaterial())
            .clipShape(RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(store.dropTarget == fenceID ? Color.accentColor : Color.primary.opacity(0.15),lineWidth:store.dropTarget == fenceID ? 2 : 1))
            .onExitCommand { AppDelegate.shared.endPeek() }
        }
    }
    @ViewBuilder func content(_ fence:Fence) -> some View {
        let files = store.entries(fence,directory:directory)
        if files.isEmpty {
            VStack(spacing:8) {
                Text(fence.kind == "folderPortal" ? "Folder empty or unavailable" : "Drop files here")
                    .font(.callout).foregroundStyle(.secondary)
                if fence.kind != "folderPortal" {
                    Button("Choose files…") { AppDelegate.shared.addFiles(fence) }
                        .buttonStyle(.link)
                    Text("Files stay in their original folders.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Open in Finder") {
                        if let path = fence.source.path { NSWorkspace.shared.open(directory ?? URL(fileURLWithPath:path)) }
                    }.buttonStyle(.link)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            ScrollView {
                if fence.view == "list" {
                    LazyVStack(spacing:2) {
                        ForEach(files) { file in fileView(file,fence:fence,list:true) }
                    }.padding(8)
                } else {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:82),spacing:4)],spacing:8) {
                        ForEach(files) { file in fileView(file,fence:fence,list:false) }
                    }.padding(10)
                }
            }
        }
    }
    func fileView(_ file:FileEntry,fence:Fence,list:Bool)->some View {
        let url = URL(fileURLWithPath:file.path)
        return Group {
            if list {
                HStack(spacing:8) {
                    Image(nsImage:NSWorkspace.shared.icon(forFile:file.path)).resizable().frame(width:24,height:24)
                    Text(file.name).lineLimit(1).font(.system(size:12)); Spacer()
                }.padding(5)
            } else {
                VStack(spacing:5) {
                    Image(nsImage:NSWorkspace.shared.icon(forFile:file.path)).resizable().frame(width:44,height:44)
                    Text(file.name).font(.system(size:11)).lineLimit(2).multilineTextAlignment(.center).frame(height:30,alignment:.top)
                }.padding(5).frame(maxWidth:.infinity)
            }
        }
        .background(selected == file.id ? Color.accentColor.opacity(0.23) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius:5))
        .contentShape(Rectangle())
        .onTapGesture(count:2) { open(file,fence:fence) }
        .onTapGesture { selected = file.id }
        .focusable()
        .onKeyPress(.return) { open(file,fence:fence); return .handled }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(file.name).accessibilityAddTraits(.isButton)
        .onDrag { NSItemProvider(object:url as NSURL) }
        .contextMenu {
            Button("Open") { open(file,fence:fence) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy file") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL])
            }
            if fence.kind != "folderPortal" {
                Menu("Move to fence") {
                    ForEach(store.state.fences.filter { $0.kind != "folderPortal" && $0.id != fence.id }) { destination in
                        Button(destination.title) { store.assign([url],to:destination) }
                    }
                }
            }
        }
    }
    func open(_ file:FileEntry,fence:Fence) {
        if file.isFolder && fence.kind == "folderPortal" { directory = URL(fileURLWithPath:file.path) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath:file.path)) }
    }
}

struct SettingsView: View {
    @ObservedObject var store: DesktopStore
    @State private var ruleName = ""
    @State private var extensions = ""
    @State private var destination = ""
    @State private var snapshotName = ""
    var body: some View {
        VStack(spacing:0) {
            if let error = store.error {
                HStack(alignment:.top) {
                    Image(systemName:"exclamationmark.triangle")
                    Text(error).textSelection(.enabled).font(.callout)
                    Spacer()
                    Button("Retry") { store.refresh() }
                }.padding(12).background(Color.orange.opacity(0.15))
            }
            TabView {
                general.tabItem { Text("General") }
                rules.tabItem { Text("Rules") }
                snapshots.tabItem { Text("Layouts") }
            }.padding(16)
            HStack {
                Text(store.busy ? "Saving…" : "Native macOS port · PecoFence 0.1.3").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.padding(.horizontal,20).padding(.bottom,16)
        }.frame(minWidth:540,minHeight:460)
    }
    var general: some View {
        Form {
            Section("Desktop") {
                HStack {
                    Button("New fence…") { AppDelegate.shared.createFence() }
                    Button("Folder portal…") { AppDelegate.shared.createPortal() }
                }
                HStack {
                    Button("Show / hide fences") { AppDelegate.shared.toggleHidden() }
                    Button("Peek") { AppDelegate.shared.togglePeek() }
                }
                Text("⌘⌥Space: bring fences above apps. Esc: return to desktop.").font(.caption).foregroundStyle(.secondary)
                Text("Click title bar to collapse. Double-click name to rename. Drag title to move; bottom-right corner to resize.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Theme", selection:Binding(get:{store.state.theme},set:{store.send(["op":"settings","theme":$0])})) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }.pickerStyle(.segmented)
            }
            Section("Configuration") {
                HStack {
                    Button("Export…") { AppDelegate.shared.exportConfig() }
                    Button("Import…") { AppDelegate.shared.importConfig() }
                    Button("Show backups") { NSWorkspace.shared.open(Engine.configDirectory) }
                }
                Text("Grouping references files; it does not move or delete them. Finder desktop icons remain visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    var rules: some View {
        VStack(alignment:.leading,spacing:12) {
            Toggle("Sort new Desktop files automatically",isOn:Binding(get:{store.state.keepUpdated},set:{store.send(["op":"settings","keepUpdated":$0])}))
            Text("First matching rule wins. Manual assignments stay until you apply rules to all files.").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(store.state.rules) { rule in
                    HStack { Text(rule.name); Spacer(); Button("Remove") { store.send(["op":"rule-delete","id":rule.id]) } }
                }
                if store.state.rules.isEmpty { Text("No rules yet.").foregroundStyle(.secondary) }
            }
            HStack {
                TextField("Rule name",text:$ruleName)
                TextField("Extensions: pdf, txt",text:$extensions)
            }
            HStack {
                Picker("Send to",selection:$destination) {
                    Text("Choose fence").tag("")
                    ForEach(store.state.fences.filter { $0.kind != "folderPortal" }) { fence in Text(fence.title).tag(fence.id) }
                }
                Button("Add rule") {
                    store.send(["op":"rule-add","name":ruleName,"extensions":extensions,"fence":destination])
                    ruleName = ""; extensions = ""
                }.disabled(ruleName.trimmingCharacters(in:.whitespaces).isEmpty || extensions.isEmpty || destination.isEmpty)
            }
            Button("Apply rules to all files…") { AppDelegate.shared.applyRules() }
        }.padding(12)
    }
    var snapshots: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Save fence positions and file memberships. Restoring a layout does not change files on disk.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(store.state.snapshots) { snapshot in
                    HStack { Text(snapshot.name); Spacer(); Button("Restore") { store.send(["op":"snapshot-restore","id":snapshot.id]) } }
                }
                if store.state.snapshots.isEmpty { Text("No saved layouts.").foregroundStyle(.secondary) }
            }
            HStack {
                TextField("Layout name",text:$snapshotName)
                Button("Save layout") { store.send(["op":"snapshot-save","name":snapshotName]); snapshotName = "" }
                    .disabled(snapshotName.trimmingCharacters(in:.whitespaces).isEmpty)
            }
        }.padding(12)
    }
}
