import AppKit
import Darwin
import Foundation

@_silgen_name("proc_pidpath")
private func omnilevel_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

/// One UI app card + the PIDs whose Core Audio process objects should be tapped together.
public struct AppProcessCluster: Sendable {
    public let mainPID: pid_t
    public let appName: String
    public let bundleIdentifier: String?
    public let audioPIDs: [pid_t]

    public init(mainPID: pid_t, appName: String, bundleIdentifier: String?, audioPIDs: [pid_t]) {
        self.mainPID = mainPID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.audioPIDs = audioPIDs
    }
}

/// Resolves running application identity (name, icon, bundle ID) and audio helper clusters.
public final class ProcessIdentity: Sendable {
    public init() {}

    public func candidateApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isTerminated
        }
    }

    public func icon(for app: NSRunningApplication) -> NSImage {
        if let icon = app.icon {
            return icon
        }
        if let url = app.bundleURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: "App")
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }

    /// True for Chromium / WebKit browsers where media usually plays in helper processes.
    public func isBrowserFamily(bundleID: String?, appName: String?) -> Bool {
        let b = (bundleID ?? "").lowercased()
        let n = (appName ?? "").lowercased()
        if b.contains("chrome") || b.contains("chromium") || b.contains("firefox")
            || b.contains("safari") || b.contains("brave") || b.contains("edge")
            || b.contains("thebrowser") || b.contains("company.thebrowser")
            || b.contains("opera") || b.contains("vivaldi") || b.contains("dia")
            || b.contains("orion") || b.contains("comet") {
            return true
        }
        if n == "arc" || n.contains("chrome") || n.contains("firefox")
            || n.contains("safari") || n.contains("brave") || n.contains("edge") {
            return true
        }
        return false
    }

    /// Tokens used to match Core Audio process bundle IDs for this app family.
    public func coreAudioBundleTokens(for main: NSRunningApplication) -> [String] {
        let b = (main.bundleIdentifier ?? "").lowercased()
        let n = (main.localizedName ?? "").lowercased()
        if b.contains("thebrowser") || n == "arc" {
            return ["thebrowser"]
        }
        if b.contains("chrome") || n.contains("chrome") {
            return ["chrome", "chromium"]
        }
        if b.contains("brave") { return ["brave"] }
        if b.contains("edge") { return ["edge"] }
        if b.contains("firefox") { return ["firefox"] }
        if b.contains("safari") || n.contains("safari") {
            return ["safari", "webkit"]
        }
        if b.contains("opera") { return ["opera"] }
        if b.contains("vivaldi") { return ["vivaldi"] }
        if let bid = main.bundleIdentifier?.lowercased(), !bid.isEmpty {
            // company.thebrowser.Browser → company.thebrowser
            let parts = bid.split(separator: ".")
            if parts.count >= 2 {
                return [parts.prefix(2).joined(separator: ".")]
            }
            return [bid]
        }
        return []
    }

    /// Related PIDs for a main app (self + helpers), not yet filtered by Core Audio presence.
    public func relatedPIDs(for main: NSRunningApplication, among all: [NSRunningApplication]? = nil) -> [pid_t] {
        let pool = all ?? NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let mainPID = main.processIdentifier
        var related = Set<pid_t>([mainPID])

        let mainBundle = main.bundleIdentifier
        let mainName = (main.localizedName ?? "").lowercased()
        let mainPrefix = bundleFamilyPrefix(mainBundle)
        let browser = isBrowserFamily(bundleID: mainBundle, appName: main.localizedName)

        for app in pool {
            let pid = app.processIdentifier
            if pid == mainPID { continue }

            if sameBundleFamily(mainBundle, app.bundleIdentifier) {
                related.insert(pid)
                continue
            }

            if let prefix = mainPrefix?.lowercased(),
               let ob = app.bundleIdentifier?.lowercased(),
               ob.hasPrefix(prefix + ".") || ob == prefix {
                related.insert(pid)
                continue
            }

            // Direct child or deeper descendant (Chromium renderers are often nested).
            if Self.isDescendant(of: mainPID, pid: pid, maxDepth: browser ? 6 : 3) {
                related.insert(pid)
                continue
            }

            if Self.looksLikeAudioHelper(app),
               Self.helperBelongs(to: main, helper: app, mainName: mainName, mainPrefix: mainPrefix) {
                related.insert(pid)
            }
        }

        // Path scan: Arc/Chrome helpers often omit themselves from NSWorkspace.
        if let bundlePath = main.bundleURL?.path {
            for pid in Self.pids(underAppBundlePath: bundlePath) {
                related.insert(pid)
            }
        }

        // Core Audio registry is authoritative for which helpers can be tapped.
        let tokens = coreAudioBundleTokens(for: main)
        if !tokens.isEmpty {
            for pid in ProcessTapIO.audioProcessPIDs(bundleContains: tokens) {
                related.insert(pid)
            }
        }

        return Array(related).sorted()
    }

    /// PIDs that should be in the Core Audio tap for this app card.
    /// Browsers: prefer helper PIDs (YouTube etc.). Other apps: main PID only when possible.
    public func tapAudioPIDs(
        for main: NSRunningApplication,
        related: [pid_t]? = nil,
        resolvingProcessObject: ((pid_t) -> Bool)? = nil
    ) -> [pid_t] {
        let resolvingProcessObject = resolvingProcessObject ?? {
            let audioPIDs = ProcessTapIO.audioProcessPIDSet()
            return { audioPIDs.contains($0) }
        }()
        let mainPID = main.processIdentifier
        var relatedPIDs = Set(related ?? self.relatedPIDs(for: main))

        // Always merge live CA processes for browsers — NSWorkspace misses many Arc helpers.
        let browser = isBrowserFamily(bundleID: main.bundleIdentifier, appName: main.localizedName)
        if browser {
            let tokens = coreAudioBundleTokens(for: main)
            for pid in ProcessTapIO.audioProcessPIDs(bundleContains: tokens) {
                relatedPIDs.insert(pid)
            }
        }

        let capable = relatedPIDs.filter(resolvingProcessObject)
        let helpers = capable.filter { $0 != mainPID }

        if browser {
            // Arc/Chrome/Safari: media is almost always in helpers. Tapping main+helpers
            // double-sums; tapping main alone misses YouTube.
            if !helpers.isEmpty { return helpers.sorted() }
            if capable.contains(mainPID) { return [mainPID] }
            // No CA object yet — empty (don't claim main and spin forever rebuilding).
            return []
        }

        // Spotify-class: main only when it has a process object (keeps audio clean).
        if capable.contains(mainPID) { return [mainPID] }
        if !helpers.isEmpty { return helpers.sorted() }
        return capable.isEmpty ? [] : [mainPID]
    }

    // MARK: - Helpers

    /// Prefer a stable family root (`company.thebrowser`) over the full bundle ID so
    /// `company.thebrowser.Browser` matches `company.thebrowser.browser.helper`.
    private func bundleFamilyPrefix(_ bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let parts = bundleID.split(separator: ".")
        if parts.count >= 3 {
            return parts.dropLast().joined(separator: ".")
        }
        return bundleID
    }

    private func sameBundleFamily(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let al = a.lowercased()
        let bl = b.lowercased()
        if al == bl { return true }
        if bl.hasPrefix(al + ".") || al.hasPrefix(bl + ".") { return true }
        let ap = al.split(separator: ".")
        let bp = bl.split(separator: ".")
        let shared = zip(ap, bp).prefix(while: { $0 == $1 }).count
        return shared >= 2 && (ap.count != bp.count || shared < ap.count)
    }

    private static func looksLikeAudioHelper(_ app: NSRunningApplication) -> Bool {
        let name = (app.localizedName ?? "").lowercased()
        let bundle = (app.bundleIdentifier ?? "").lowercased()
        let tokens = [
            "helper", "webcontent", "webkit", "gpu", "plugin", "renderer",
            "audio", "media", "chromium", "electron", "networking"
        ]
        return tokens.contains { name.contains($0) || bundle.contains($0) }
    }

    private static func helperBelongs(
        to main: NSRunningApplication,
        helper: NSRunningApplication,
        mainName: String,
        mainPrefix: String?
    ) -> Bool {
        let helperName = (helper.localizedName ?? "").lowercased()
        let helperBundle = (helper.bundleIdentifier ?? "").lowercased()

        if !mainName.isEmpty, helperName.contains(mainName) {
            return true
        }
        if let prefix = mainPrefix?.lowercased(),
           helperBundle.hasPrefix(prefix.lowercased()) {
            return true
        }

        if let mb = main.bundleIdentifier?.lowercased() {
            if mb.contains("chrome"), helperBundle.contains("chrome") || helperName.contains("chrome") {
                return true
            }
            if mb.contains("chromium"), helperBundle.contains("chromium") || helperName.contains("chromium") {
                return true
            }
            if mb.contains("firefox"), helperBundle.contains("firefox") || helperName.contains("firefox") {
                return true
            }
            if mb.contains("safari") || mb == "com.apple.safari",
               helperBundle.contains("webkit") || helperBundle.contains("safari") || helperName.contains("webkit") {
                return true
            }
            if mb.contains("brave"), helperBundle.contains("brave") || helperName.contains("brave") {
                return true
            }
            if mb.contains("edge"), helperBundle.contains("edge") || helperName.contains("edge") {
                return true
            }
            // Arc — note lowercase `browser` in helper bundle IDs vs `Browser` in main.
            if mb.contains("thebrowser") || mb.contains("arc"),
               helperBundle.contains("thebrowser") || helperBundle.contains("arc")
                || helperName.contains("arc") || helperName.contains("browser helper") {
                return true
            }
            if mb.contains("spotify"), helperBundle.contains("spotify") || helperName.contains("spotify") {
                return true
            }
            if mb.contains("discord"), helperBundle.contains("discord") || helperName.contains("discord") {
                return true
            }
            if mb.contains("slack"), helperBundle.contains("slack") || helperName.contains("slack") {
                return true
            }
        }
        return false
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func isDescendant(of ancestor: pid_t, pid: pid_t, maxDepth: Int) -> Bool {
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentPID(of: current) else { return false }
            if parent == ancestor { return true }
            if parent <= 1 { return false }
            current = parent
        }
        return false
    }

    /// All live PIDs whose executable path lives under the app bundle (helpers / renderers).
    private static func pids(underAppBundlePath bundlePath: String) -> [pid_t] {
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.stride

        var result: [pid_t] = []
        result.reserveCapacity(8)
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for i in 0..<actual {
            let pid = procs[i].kp_proc.p_pid
            guard pid > 0 else { continue }
            pathBuf.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                let len = omnilevel_proc_pidpath(pid, base, UInt32(buf.count))
                guard len > 0 else { return }
                let path = String(cString: base)
                if path == bundlePath || path.hasPrefix(prefix) {
                    result.append(pid)
                }
            }
        }
        return result
    }
}
