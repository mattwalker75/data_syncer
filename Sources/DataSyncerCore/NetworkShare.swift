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
            // the OS knows which server URL a network volume came from; that is the reliable match
            let remount = (try? URL(fileURLWithPath: on, isDirectory: true).resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting
            if matches(mountedFrom: from, mountedOn: on, fsType: type, remount: remount, url: url) { return URL(fileURLWithPath: on, isDirectory: true) }
        }
        return nil
    }

    /// Does a mount entry belong to smb://nas/backups? `remount` is the URL macOS recorded for the volume
    /// (the reliable answer, host and share); `from` is f_mntfromname ("//matt@nas._smb._tcp.local/backups"),
    /// usable for SMB. A share whose host cannot be told is never a match — the wrong machine's "backups"
    /// share must not become the destination.
    static func matches(mountedFrom from: String, mountedOn on: String, fsType: String, remount: URL?, url: URL) -> Bool {
        func bare(_ h: String) -> String { h.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }   // IPv6 literals
        guard ["smbfs", "afpfs", "webdav", "nfs"].contains(fsType), let wantHost = url.host.map(bare) else { return false }
        let wantShare = url.path.split(separator: "/").first.map { String($0).removingPercentEncoding?.lowercased() ?? String($0).lowercased() } ?? ""
        guard !wantShare.isEmpty else { return false }
        func label(_ s: String) -> String { String(s.split(separator: ".").first ?? Substring(s)) }
        // "nas", "nas.local" and "nas._smb._tcp.local" are one machine; an address is only ever itself
        func isAddress(_ h: String) -> Bool { h.contains(":") || h.allSatisfy { $0.isNumber || $0 == "." } }
        func sameHost(_ a: String) -> Bool { let a = bare(a); return a == wantHost || (!isAddress(a) && !isAddress(wantHost) && label(a) == label(wantHost)) }
        if let remount, let h = remount.host {
            let share = remount.path.split(separator: "/").first.map { String($0).removingPercentEncoding?.lowercased() ?? String($0).lowercased() } ?? ""
            return sameHost(h) && share == wantShare
        }
        guard from.hasPrefix("//") else { return false }
        var hostPart = "", sharePart = ""
        let rest = from.dropFirst(2)
        if let slash = rest.firstIndex(of: "/") {
            hostPart = String(rest[..<slash]); sharePart = String(rest[rest.index(after: slash)...])
        }
        if let at = hostPart.lastIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
        if hostPart.hasPrefix("["), let close = hostPart.firstIndex(of: "]") { hostPart = String(hostPart[hostPart.index(after: hostPart.startIndex)..<close]) }   // [::1]:445
        else if let colon = hostPart.firstIndex(of: ":") { hostPart = String(hostPart[..<colon]) }
        sharePart = sharePart.removingPercentEncoding ?? sharePart
        return !hostPart.isEmpty && sameHost(hostPart) && sharePart.lowercased() == wantShare
    }

    /// Connects the share the way Finder's "Connect to Server" does, without any window, and returns where it
    /// was mounted. `user`/`password` nil = whatever the Keychain or the server allows (a guest share, say).
    /// Runs on NetFS's own queue so a slow or absent server never blocks, and a cancelled run stops the attempt.
    public static func mount(_ url: URL, user: String?, password: String?) async throws -> URL {
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionNoUI
        let mountOpts = NSMutableDictionary()
        mountOpts[kNetFSAllowSubMountsKey] = true
        let request = Locked<AsyncRequestID?>(nil)
        // NetFS never calls the block once a request is cancelled, so the cancel handler resumes the wait itself;
        // whichever side comes first resumes, the other finds `pending` empty
        let pending = Locked<CheckedContinuation<[String], Error>?>(nil)
        func resume(_ r: Result<[String], Error>) {
            let c = pending.with { c -> CheckedContinuation<[String], Error>? in let v = c; c = nil; return v }
            guard let c else { return }
            switch r { case .success(let p): c.resume(returning: p); case .failure(let e): c.resume(throwing: e) }
        }
        let paths: [String] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], Error>) in
                pending.value = cont
                if Task.isCancelled { resume(.failure(CancellationError())); return }
                let queue = DispatchQueue(label: "datasyncer.netfs")
                var id: AsyncRequestID?
                let status = NetFSMountURLAsync(url as CFURL, nil, user as CFString?, password as CFString?, open, mountOpts, &id, queue) { status, _, points in
                    if status != 0 { resume(.failure(status == ECANCELED ? CancellationError() : explain(status, url))); return }
                    resume(.success((points as? [String]) ?? []))
                }
                if status != 0 { resume(.failure(explain(status, url))); return }
                request.value = id
            }
        } onCancel: {
            if let id = request.value { NetFSMountURLCancel(id) }
            resume(.failure(CancellationError()))
        }
        if let first = paths.first { return URL(fileURLWithPath: first, isDirectory: true) }
        // mounted, but no path came back: look it up
        if let p = mountPoint(for: url) { return p }
        throw DSError("The share \(url.absoluteString) was connected but its folder could not be found.")
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
