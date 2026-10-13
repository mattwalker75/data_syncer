// Network shares (SMB/AFP): one that is already connected in Finder is used where it is mounted; one that isn't
// is connected by Data Syncer with the saved sign-in (owner decision 8: both ways). Once mounted, a share is a
// folder on this Mac, so LocalStorage does the copying.
import Foundation
import NetFS

public enum NetworkShare {
    /// Where `url` (smb://host/share) is mounted right now, if it is.
    public static func mountPoint(for url: URL) -> URL? {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return nil }
        for i in 0..<Int(n) {
            var fs = buf[i]
            let from = withUnsafePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            let on = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            let type = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
            if matches(mountedFrom: from, mountedOn: on, fsType: type, url: url) { return URL(fileURLWithPath: on, isDirectory: true) }
        }
        return nil
    }

    /// Does a mount entry ("//matt@nas._smb._tcp.local/backups" on "/Volumes/backups") belong to smb://nas/backups?
    static func matches(mountedFrom from: String, mountedOn on: String, fsType: String, url: URL) -> Bool {
        guard ["smbfs", "afpfs", "webdav", "nfs"].contains(fsType), let wantHost = url.host?.lowercased() else { return false }
        let wantShare = url.path.split(separator: "/").first.map { String($0).removingPercentEncoding?.lowercased() ?? String($0).lowercased() } ?? ""
        guard !wantShare.isEmpty else { return false }
        // the share name: the last part of f_mntfromname, or of the mount point for file systems that hide it
        var hostPart = "", sharePart = ""
        if from.hasPrefix("//") {
            let rest = from.dropFirst(2)
            if let slash = rest.firstIndex(of: "/") {
                hostPart = String(rest[..<slash]); sharePart = String(rest[rest.index(after: slash)...])
            }
            if let at = hostPart.lastIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
            if let colon = hostPart.firstIndex(of: ":") { hostPart = String(hostPart[..<colon]) }
        } else {
            sharePart = (on as NSString).lastPathComponent
        }
        sharePart = sharePart.removingPercentEncoding ?? sharePart
        guard sharePart.lowercased() == wantShare else { return false }
        if hostPart.isEmpty { return true }
        let a = hostPart.lowercased(), b = wantHost
        // "nas", "nas.local" and "nas._smb._tcp.local" are the same machine
        func label(_ s: String) -> String { String(s.split(separator: ".").first ?? Substring(s)) }
        return a == b || label(a) == label(b)
    }

    /// Connects the share the way Finder's "Connect to Server" does, without any window, and returns where it
    /// was mounted. `user`/`password` nil = whatever the Keychain or the server allows (a guest share, say).
    public static func mount(_ url: URL, user: String?, password: String?) throws -> URL {
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionNoUI
        let mountOpts = NSMutableDictionary()
        mountOpts[kNetFSAllowSubMountsKey] = true
        var points: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil, user as CFString?, password as CFString?, open, mountOpts, &points)
        guard status == 0 else { throw explain(status, url) }
        guard let list = points?.takeRetainedValue() as? [String], let first = list.first else {
            // mounted, but no path came back: look it up
            if let p = mountPoint(for: url) { return p }
            throw DSError("The share \(url.absoluteString) was connected but its folder could not be found.")
        }
        return URL(fileURLWithPath: first, isDirectory: true)
    }

    static func explain(_ status: Int32, _ url: URL) -> DSError {
        let where_ = url.host ?? url.absoluteString
        switch status {
        case 80, 13, 1: return DSError("\(where_) refused the sign-in for \(url.absoluteString). Check the user name and password saved for this destination.")
        case 2, -6003: return DSError("The share \(url.absoluteString) isn't there. Check the share name (the part after the server).")
        case 60, 65, 64, 51: return DSError("\(where_) isn't answering. Check that it's on and reachable from this network.")
        case 17: return DSError("The share \(url.absoluteString) is already connected but could not be found. Eject it in Finder and try again.")
        case 61: return DSError("\(where_) isn't accepting file-sharing connections. Check that file sharing is on at the server.")
        default: return DSError("The share \(url.absoluteString) could not be connected (error \(status)).")
        }
    }
}
