import AppKit
import Foundation
import Darwin

@main struct DeveloperToolsTests {
    @MainActor static func main() throws {
        let parent = NSView(frame:NSRect(x:0,y:0,width:300,height:300))
        let title = TitleDragView(frame:NSRect(x:10,y:100,width:220,height:38))
        parent.addSubview(title)
        precondition(title.hitTest(NSPoint(x:20,y:110)) === title)
        precondition(title.hitTest(NSPoint(x:20,y:80)) == nil)
        precondition(title.acceptsFirstMouse(for:nil) && ResizeView().acceptsFirstMouse(for:nil))
        let preferences = try JSONDecoder().decode(MacPreferences.self,from:Data("{}".utf8))
        precondition(preferences.snapReordering && preferences.restoreDisplays && preferences.filteredPortals.isEmpty)
        var saved = preferences
        saved.filteredPortals.insert("portal"); saved.snapReordering = false
        let restored = try JSONDecoder().decode(MacPreferences.self,from:JSONEncoder().encode(saved))
        precondition(!restored.snapReordering && restored.filteredPortals.contains("portal"))
        let folder = FileEntry(id:"folder",path:"/tmp/node_modules",name:"node_modules",isFolder:true,mtime:0,size:0)
        precondition(DeveloperFilters.hides(folder))
        var file = folder; file.isFolder = false
        precondition(!DeveloperFilters.hides(file))
        var source = folder; source.name = "src"
        precondition(!DeveloperFilters.hides(source))

        let status = Data("# branch.head feature/test\0# branch.ab +2 -3\01 M. normal\02 R. renamed\0? misleading rename source\0? untracked\0u UU conflict\0".utf8)
        let summary = GitSummary.parse(status)
        precondition(summary.branch == "feature/test" && summary.changed == 4 && summary.ahead == 2 && summary.behind == 3)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pecofence-developer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func git(_ arguments:[String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/git")
            process.arguments = ["-C",root.path,"-c","core.hooksPath=/dev/null","-c","commit.gpgsign=false"] + arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
        }
        try git(["init","-b","main"])
        try git(["config","user.name","Fixture"]); try git(["config","user.email","fixture@example.invalid"])
        let readme = root.appendingPathComponent("README.md")
        try Data("first".utf8).write(to:readme)
        try git(["add","README.md"]); try git(["commit","-m","fixture"])
        try Data("changed".utf8).write(to:readme)
        try Data("new".utf8).write(to:root.appendingPathComponent("new file.txt"))
        let live = GitSummary.read(folder:root)
        precondition(live?.branch == "main" && live?.changed == 2)
        precondition(GitSummary.read(folder:FileManager.default.temporaryDirectory) == nil)

        let project = root.appendingPathComponent("App.xcodeproj"), workspace = root.appendingPathComponent("App.xcworkspace")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let xcode = ProjectApplication(id:"com.apple.dt.Xcode",name:"Xcode",url:URL(fileURLWithPath:"/Applications/Xcode.app"))
        precondition(ProjectActions.target(folder:root,application:xcode)?.resolvingSymlinksInPath().path == workspace.resolvingSymlinksInPath().path)
        let terminal = ProjectApplication(id:"com.apple.Terminal",name:"Terminal",url:URL(fileURLWithPath:"/System/Applications/Utilities/Terminal.app"))
        precondition(ProjectActions.target(folder:root,application:terminal)?.path == root.path)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.writeObjects([root as NSURL])
        precondition(FenceHostingView.fileURLs(from:pasteboard).map(\.path) == [root.path])
        pasteboard.releaseGlobally()
        let desktop = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at:desktop,withIntermediateDirectories:true)
        let visible = desktop.appendingPathComponent("project"), hidden = desktop.appendingPathComponent("already-hidden")
        try Data().write(to:visible); try Data().write(to:hidden)
        precondition(chflags(hidden.path,UInt32(UF_HIDDEN)) == 0)
        let journal = root.appendingPathComponent("visibility.json")
        let visibility = DesktopVisibilityController(journal:journal)
        func isHidden(_ url:URL) -> Bool {
            var info = stat(); precondition(lstat(url.path,&info) == 0)
            return info.st_flags & UInt32(UF_HIDDEN) != 0
        }
        try visibility.reconcile(paths:[visible.path,hidden.path,readme.path],desktop:desktop)
        precondition(isHidden(visible) && isHidden(hidden) && !isHidden(readme))
        // A fresh controller must recover flags using the persisted journal.
        let recovered = DesktopVisibilityController(journal:journal)
        try recovered.reconcile(paths:[],desktop:desktop)
        precondition(!isHidden(visible) && isHidden(hidden))
        try recovered.reconcile(paths:[visible.path],desktop:desktop)
        let moved = root.appendingPathComponent("moved-project")
        try FileManager.default.moveItem(at:visible,to:moved)
        try Data().write(to:visible)
        precondition(chflags(visible.path,UInt32(UF_HIDDEN)) == 0)
        try recovered.reconcile(paths:[],desktop:desktop)
        precondition(!isHidden(moved) && isHidden(visible))
        print("PASS: preferences compatibility, filter scope, Git parsing/real repository, Xcode target choice, Terminal target, Finder folder URLs")
        print("PASS: Desktop hiding scope, restart recovery, moved-file restoration, original flags and replacement-file safety")
    }
}
