import Foundation
import Darwin

// A journal entry owns only UF_HIDDEN on this inode; other flags remain untouched.
final class DesktopVisibilityController: @unchecked Sendable {
    private let lock = NSLock()
    struct Record: Codable {
        var path: String
        var device: Int32
        var inode: UInt64
        var bookmark: Data?
        var filesystem: [Int32]?
    }
    let journal: URL
    private var records: [Record]?
    init(journal:URL) { self.journal = journal }

    private func metadata(_ path:String) -> stat? {
        var info = stat()
        guard lstat(path,&info) == 0 else { return nil }
        return info
    }
    private func resolved(_ record:Record) -> String? {
        if let info = metadata(record.path), info.st_dev == record.device && info.st_ino == record.inode { return record.path }
        if let filesystem = record.filesystem, filesystem.count == 2 {
            var id = fsid_t(val:(filesystem[0],filesystem[1]))
            var buffer = [CChar](repeating:0,count:Int(PATH_MAX))
            if fsgetpath(&buffer,buffer.count,&id,record.inode) > 0 {
                let path = String(cString:buffer)
                if let info = metadata(path), info.st_dev == record.device && info.st_ino == record.inode { return path }
            }
        }
        if let bookmark = record.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData:bookmark,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale),
               let info = metadata(url.path), info.st_dev == record.device && info.st_ino == record.inode { return url.path }
        }
        return nil
    }
    private func save() throws {
        try FileManager.default.createDirectory(at:journal.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(records ?? []).write(to:journal,options:.atomic)
    }
    func reconcile(paths:Set<String>, desktop:URL) throws {
        lock.lock(); defer { lock.unlock() }
        if records == nil {
            records = FileManager.default.fileExists(atPath:journal.path) ? try JSONDecoder().decode([Record].self,from:Data(contentsOf:journal)) : []
        }
        let parent = desktop.standardizedFileURL.resolvingSymlinksInPath().path
        let desired = Set(paths.filter { URL(fileURLWithPath:$0).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == parent })
        for record in records ?? [] {
            guard let path = resolved(record), !desired.contains(path), let info = metadata(path) else { continue }
            guard chflags(path,info.st_flags & ~UInt32(UF_HIDDEN)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            records?.removeAll { $0.device == record.device && $0.inode == record.inode }
        }
        try save()
        for path in desired {
            guard let info = metadata(path), info.st_mode & S_IFMT != S_IFLNK, info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
            if !(records ?? []).contains(where: { $0.device == info.st_dev && $0.inode == info.st_ino }) {
                let url = URL(fileURLWithPath:path)
                var volume = statfs()
                let filesystem = statfs(path,&volume) == 0 ? [volume.f_fsid.val.0,volume.f_fsid.val.1] : nil
                records?.append(Record(path:path,device:info.st_dev,inode:info.st_ino,bookmark:try? url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil),filesystem:filesystem))
                try save()
            }
            guard chflags(path,info.st_flags | UInt32(UF_HIDDEN)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        }
    }
}
