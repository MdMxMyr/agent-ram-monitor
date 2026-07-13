// agent-ram-monitor-bar: macOS menu bar companion for agent-ram-monitor.
// Polls `agent-ram-monitor --json`, shows total agent RAM in the status bar,
// turns red when any single session exceeds the threshold (default 3 GB,
// override with AGENT_RAM_MONITOR_ALERT_GB). Menu lists sessions with their
// MCP/browser/child breakdown; click actions kill and/or copy the
// resume command.
//
// Build: swiftc -O main.swift -o agent-ram-monitor-bar

import AppKit

let agentTopPath: String = {
    if let env = ProcessInfo.processInfo.environment["AGENT_RAM_MONITOR_PATH"], !env.isEmpty {
        return env
    }
    // Default: the agent-ram-monitor CLI at the repo root, one level above this binary.
    let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("agent-ram-monitor").path
    if FileManager.default.isExecutableFile(atPath: sibling) {
        return sibling
    }
    return "/usr/local/bin/agent-ram-monitor"
}()
let thresholdGb = Double(ProcessInfo.processInfo.environment["AGENT_RAM_MONITOR_ALERT_GB"] ?? "") ?? 3.0
let pollSeconds: TimeInterval = 10

struct Child {
    let pid: Int, depth: Int, kind: String, label: String, ramGb: Double
    let pids: [Int]
}

struct AppUsage {
    let name: String, ramGb: Double, procs: Int
}

struct Session {
    let tool: String, pid: Int, ramGb: Double, cpu: Double
    let uptimeS: Int, project: String, title: String?, sessionId: String?
    let state: String?, resume: String?, host: String?, children: [Child]
    let ramHistory: [Double]?, tty: String?, c11Workspace: String?, c11Surface: String?
}

struct MemStats {
    let totalGb: Double, usedGb: Double
}

func memStats() -> MemStats {
    let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    var stats = vm_statistics64_data_t()
    var size = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
        }
    }
    guard kr == KERN_SUCCESS else { return MemStats(totalGb: total, usedGb: 0) }
    // Activity Monitor's "Memory Used": app memory (internal - purgeable)
    // + wired + compressed.
    let pages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        + Double(stats.wire_count) + Double(stats.compressor_page_count)
    return MemStats(totalGb: total,
                    usedGb: max(0, pages * Double(vm_kernel_page_size) / 1_073_741_824))
}

/// Header view for the menu: total / used / agent RAM as a stacked bar.
final class RamBarView: NSView {
    var totalGb: Double = 0, usedGb: Double = 0, agentsGb: Double = 0
    var activeCount = 0, hog = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 14
        let width = bounds.width - pad * 2
        guard width > 40, totalGb > 0 else { return }

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        ("AGENT SESSIONS · \(activeCount) ACTIVE" as NSString)
            .draw(at: NSPoint(x: pad, y: 6), withAttributes: headerAttrs)

        let usage = String(format: "%.1fG agents / %.1fG used / %.0fG",
                           agentsGb, usedGb, totalGb) as NSString
        let usageAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let usageSize = usage.size(withAttributes: usageAttrs)
        usage.draw(at: NSPoint(x: bounds.width - pad - usageSize.width, y: 6),
                   withAttributes: usageAttrs)

        let barRect = NSRect(x: pad, y: 24, width: width, height: 7)
        let track = NSBezierPath(roundedRect: barRect, xRadius: 3.5, yRadius: 3.5)
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        track.fill()

        func segment(from: Double, to: Double, color: NSColor) {
            let x0 = barRect.minX + barRect.width * CGFloat(min(1, max(0, from)))
            let x1 = barRect.minX + barRect.width * CGFloat(min(1, max(0, to)))
            guard x1 - x0 > 0.5 else { return }
            NSGraphicsContext.current?.saveGraphicsState()
            track.addClip()
            color.setFill()
            NSRect(x: x0, y: barRect.minY, width: x1 - x0, height: barRect.height).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        let agentsFrac = agentsGb / totalGb
        let usedFrac = max(usedGb, agentsGb) / totalGb
        segment(from: agentsFrac, to: usedFrac,
                color: NSColor.labelColor.withAlphaComponent(0.28))
        segment(from: 0, to: agentsFrac,
                color: hog ? .systemRed : .controlAccentColor)
    }
}

final class App: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var sessions: [Session] = []
    var apps: [AppUsage] = []
    var lastError: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.menu = NSMenu()
        statusItem.button?.title = "✳ …"
        refresh()
        Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { _ in self.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let (sessions, apps, error) = self.scan()
            DispatchQueue.main.async {
                if let sessions { self.sessions = sessions }
                if error == nil { self.apps = apps }  // keep last good on a failed scan
                self.lastError = error
                self.updateUI()
            }
        }
    }

    func scan() -> ([Session]?, [AppUsage], String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: agentTopPath)
        proc.arguments = ["--json", "--log"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return (nil, [], "can't run agent-ram-monitor: \(error.localizedDescription)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let parsed = try? JSONSerialization.jsonObject(with: data)
        var appDicts: [[String: Any]] = []
        let arr: [[String: Any]]
        if let dict = parsed as? [String: Any] {
            arr = dict["sessions"] as? [[String: Any]] ?? []
            appDicts = dict["apps"] as? [[String: Any]] ?? []
        } else if let legacy = parsed as? [[String: Any]] {
            arr = legacy
        } else {
            return (nil, [], "agent-ram-monitor returned invalid JSON")
        }
        let apps = appDicts.map {
            AppUsage(name: $0["name"] as? String ?? "?",
                     ramGb: $0["ram_gb"] as? Double ?? 0,
                     procs: $0["procs"] as? Int ?? 0)
        }
        let sessions = arr.map { d -> Session in
            let children = (d["children"] as? [[String: Any]] ?? []).map { c in
                Child(pid: c["pid"] as? Int ?? 0, depth: c["depth"] as? Int ?? 0,
                      kind: c["kind"] as? String ?? "?", label: c["label"] as? String ?? "?",
                      ramGb: c["ram_gb"] as? Double ?? 0,
                      pids: c["pids"] as? [Int] ?? [c["pid"] as? Int ?? 0])
            }
            return Session(
                tool: d["tool"] as? String ?? "?", pid: d["pid"] as? Int ?? 0,
                ramGb: d["ram_gb"] as? Double ?? 0, cpu: d["cpu"] as? Double ?? 0,
                uptimeS: d["uptime_s"] as? Int ?? 0,
                project: (d["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "?",
                title: d["title"] as? String, sessionId: d["session"] as? String,
                state: d["state"] as? String, resume: d["resume"] as? String,
                host: d["host"] as? String, children: children,
                ramHistory: d["ram_history"] as? [Double],
                tty: (d["tty"] as? String).flatMap { $0 == "-" ? nil : "/dev/" + $0 },
                c11Workspace: d["c11_workspace"] as? String,
                c11Surface: d["c11_surface"] as? String)
        }
        return (sessions, apps, nil)
    }

    func updateUI() {
        guard let button = statusItem.button else { return }
        let total = sessions.reduce(0) { $0 + $1.ramGb }
        let hog = sessions.contains { $0.ramGb >= thresholdGb }
        if lastError == nil && sessions.isEmpty {
            button.attributedTitle = statusTitle("✳ –", color: NSColor.secondaryLabelColor, numberRange: nil)
        } else if lastError != nil {
            button.attributedTitle = statusTitle("✳ ?", color: hog ? NSColor.systemRed : nil, numberRange: nil)
        } else {
            let value = String(format: "%.1fG", total)
            let text = "✳ \(value)"
            let range = (text as NSString).range(of: value)
            button.attributedTitle = statusTitle(text, color: hog ? NSColor.systemRed : nil, numberRange: range)
        }
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let total = sessions.reduce(0) { $0 + $1.ramGb }
        let active = sessions.filter { $0.state == "busy" }.count
        let mem = memStats()
        let bar = RamBarView(frame: NSRect(x: 0, y: 0, width: 440, height: 38))
        bar.autoresizingMask = [.width]
        bar.totalGb = mem.totalGb
        bar.usedGb = mem.usedGb
        bar.agentsGb = total
        bar.activeCount = active
        bar.hog = sessions.contains { $0.ramGb >= thresholdGb }
        let barItem = NSMenuItem()
        barItem.view = bar
        menu.addItem(barItem)
        if !apps.isEmpty {
            let appsItem = NSMenuItem(title: "Memory by App", action: nil, keyEquivalent: "")
            appsItem.image = symbol("chart.bar", "Memory by App")
            let sub = NSMenu()
            var rows: [(name: String, gb: Double, count: String)] =
                [("✳ coding agents", total, "\(sessions.count) sessions")]
            rows += apps.map { ($0.name, $0.ramGb, "\($0.procs) proc\($0.procs == 1 ? "" : "s")") }
            rows.sort { $0.gb > $1.gb }
            for row in rows {
                let line = String(format: "%5.1fG  %@ · %@", row.gb, row.name, row.count)
                let item = disabled(line)
                item.attributedTitle = NSAttributedString(
                    string: line,
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                 .foregroundColor: row.name.hasPrefix("✳")
                                     ? NSColor.labelColor : NSColor.secondaryLabelColor])
                sub.addItem(item)
            }
            appsItem.submenu = sub
            menu.addItem(appsItem)
        }
        if let err = lastError {
            menu.addItem(disabledSecondary(err))
        }
        if sessions.isEmpty && lastError == nil {
            menu.addItem(disabledSecondary("No agent sessions running"))
        }
        for s in sessions {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            if isHelperSession(s) {
                item.attributedTitle = helperTitle(s)
                item.submenu = helperSubmenu(s)
            } else {
                item.attributedTitle = sessionTitle(s)
                item.submenu = sessionSubmenu(s)
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(footerNote(String(format: "Red at ≥ %@ GB · polling %.0fs",
                                       thresholdLabel(thresholdGb), pollSeconds)))
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.keyEquivalentModifierMask = [.command]
        refreshItem.image = symbol("arrow.clockwise", "Refresh")
        menu.addItem(refreshItem)
        let quit = NSMenuItem(title: "Quit agent-ram-monitor-bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.image = symbol("power", "Quit")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func statusTitle(_ text: String, color: NSColor?, numberRange: NSRange?) -> NSAttributedString {
        let statusSize = NSFont.systemFontSize
        let baseFont = NSFont.menuBarFont(ofSize: statusSize)
        let title = NSMutableAttributedString(
            string: text,
            attributes: [.font: baseFont,
                         .foregroundColor: color ?? NSColor.labelColor])
        if let numberRange {
            title.addAttribute(
                .font,
                value: NSFont.monospacedDigitSystemFont(ofSize: statusSize, weight: .regular),
                range: numberRange)
        }
        return title
    }

    func sessionTitle(_ s: Session) -> NSAttributedString {
        let ram = String(format: "%.1fG", s.ramGb)
        let title = ellipsize(s.title ?? s.sessionId.map { String($0.prefix(8)) } ?? "?", limit: 48)
        let indent = String(repeating: " ", count: ram.count + 2)
        let state = normalizedState(s.state)
        var parts = [toolLabel(s.tool)]
        if let host = s.host { parts.append(host) }
        parts += [s.project, state, formatUptime(s.uptimeS)]
        let meta = parts.joined(separator: " · ")
        let full = "\(ram)  \(title)\n\(indent)●  \(meta)"
        let out = NSMutableAttributedString(
            string: full,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .regular),
                         .foregroundColor: NSColor.labelColor])

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))

        let ramFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let metaFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let ramRange = NSRange(location: 0, length: (ram as NSString).length)
        let spacerRange = NSRange(location: ramRange.upperBound, length: 2)
        let titleRange = NSRange(location: spacerRange.upperBound, length: (title as NSString).length)
        let indentRange = NSRange(location: titleRange.upperBound + 1, length: indent.count)
        let dotRange = NSRange(location: indentRange.upperBound, length: ("●" as NSString).length)
        let metaRange = NSRange(location: dotRange.upperBound + 2, length: (meta as NSString).length)

        out.addAttributes([.font: ramFont, .foregroundColor: ramColor(s.ramGb)], range: ramRange)
        out.addAttributes([.font: ramFont], range: spacerRange)
        out.addAttributes([.font: ramFont, .foregroundColor: NSColor.clear], range: indentRange)
        out.addAttributes([.font: titleFont, .foregroundColor: NSColor.labelColor], range: titleRange)
        out.addAttributes([.font: metaFont, .foregroundColor: dotColor(state)], range: dotRange)
        out.addAttributes([.font: metaFont, .foregroundColor: NSColor.secondaryLabelColor], range: metaRange)
        if let img = sparkImage(s.ramHistory, buckets: 12, size: NSSize(width: 54, height: 9)) {
            out.append(NSAttributedString(string: "   ", attributes: [.font: metaFont]))
            out.append(sparkAttachment(img, yOffset: -1))
            out.addAttribute(.paragraphStyle, value: paragraph,
                             range: NSRange(location: 0, length: out.length))
        }
        return out
    }

    func helperTitle(_ s: Session) -> NSAttributedString {
        let ram = String(format: "%.1fG", s.ramGb)
        let label = "\(ram)  \(toolLabel(s.tool)) · IDE helper"
        let out = NSMutableAttributedString(
            string: label,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor])
        out.addAttribute(
            .font,
            value: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            range: (label as NSString).range(of: ram))
        return out
    }

    func footerNote(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }

    func sessionSubmenu(_ s: Session) -> NSMenu {
        let sub = NSMenu()
        var info = [String(format: "PID %d · %.2f GB · CPU %.0f%%", s.pid, s.ramGb, s.cpu)]
        if let state = s.state { info[0] += " · \(state)" }
        info.forEach { sub.addItem(disabledSecondary($0)) }
        if let sid = s.sessionId { sub.addItem(disabledSecondary("Session \(sid)")) }
        if let h = s.ramHistory, let lo = h.min(), let hi = h.max(),
           let img = sparkImage(h, buckets: 24, size: NSSize(width: 132, height: 14)) {
            let item = disabled("")
            let t = NSMutableAttributedString(attributedString: sparkAttachment(img, yOffset: -3))
            t.append(NSAttributedString(
                string: String(format: "   %.1f–%.1fG · last hour", lo, hi),
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = t
            sub.addItem(item)
        }
        sub.addItem(.separator())
        if let host = s.host {
            var payload: [String: Any] = ["host": host]
            if let tty = s.tty { payload["tty"] = tty }
            if let ws = s.c11Workspace { payload["workspace"] = ws }
            if let surf = s.c11Surface { payload["surface"] = surf }
            sub.addItem(action("Bring to Front (\(host))", #selector(focusSession(_:)),
                               payload, symbolName: "macwindow"))
        }
        let freed = String(format: " (frees ~%.1fG)", s.ramGb)
        let toolToken = expectToken(s.tool)
        if let resume = s.resume {
            sub.addItem(action("Kill & Copy Resume Command" + freed,
                               #selector(killAndCopy(_:)),
                               ["pid": s.pid, "resume": resume, "expect": toolToken],
                               symbolName: "xmark.circle"))
            sub.addItem(action("Copy Resume Command", #selector(copyText(_:)), ["text": resume],
                               symbolName: "doc.on.clipboard"))
        } else {
            sub.addItem(action("Kill" + freed, #selector(killOnly(_:)),
                               ["pids": [s.pid], "expect": toolToken],
                               symbolName: "xmark.circle"))
        }
        let notable = s.children.filter { $0.kind != "cmd" || $0.ramGb >= 0.1 }
        if !notable.isEmpty {
            sub.addItem(.separator())
            sub.addItem(disabledSecondary("Subprocesses:"))
            let ramWidth = notable.map { String(format: "%.2fG", $0.ramGb).count }.max() ?? 5
            for c in notable {
                let pad = String(repeating: "   ", count: c.depth)
                let ram = String(format: "%.2fG", c.ramGb)
                let paddedRam = String(repeating: " ", count: max(0, ramWidth - ram.count)) + ram
                let line = "\(pad)\(paddedRam)  \(c.kind)  \(c.label)"
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(
                    string: line,
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                 .foregroundColor: NSColor.secondaryLabelColor])
                let what = c.pids.count > 1 ? "\(c.pids.count) processes" : "\(c.label) [\(c.pid)]"
                let kill = action(String(format: "Kill %@ (frees ~%.1fG)", what, c.ramGb),
                                  #selector(killOnly(_:)),
                                  ["pids": c.pids, "expect": expectToken(c.label)],
                                  symbolName: "xmark.circle")
                let csub = NSMenu()
                csub.addItem(kill)
                item.submenu = csub
                sub.addItem(item)
            }
        }
        return sub
    }

    func helperSubmenu(_ s: Session) -> NSMenu {
        let sub = NSMenu()
        sub.addItem(action("Kill", #selector(killOnly(_:)),
                           ["pids": [s.pid], "expect": expectToken(s.tool)],
                           symbolName: "xmark.circle"))
        return sub
    }

    func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func disabledSecondary(_ title: String) -> NSMenuItem {
        let item = disabled(title)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }

    func action(_ title: String, _ sel: Selector, _ payload: [String: Any], symbolName: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        if let symbolName {
            item.image = symbol(symbolName, title)
        }
        return item
    }

    func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    func isHelperSession(_ s: Session) -> Bool {
        s.tool.contains("(") && s.sessionId == nil && s.resume == nil
    }

    func toolLabel(_ tool: String) -> String {
        tool.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "  ", with: " ")
    }

    func normalizedState(_ state: String?) -> String {
        guard let state, !state.isEmpty else { return "unknown" }
        return state
    }

    func dotColor(_ state: String) -> NSColor {
        switch state {
        case "busy": return NSColor.systemGreen
        case "shell": return NSColor.systemBlue
        case "idle": return NSColor.tertiaryLabelColor
        default: return NSColor.tertiaryLabelColor
        }
    }

    func ramColor(_ ramGb: Double) -> NSColor {
        if ramGb >= thresholdGb { return NSColor.systemRed }
        if ramGb >= thresholdGb / 2 { return NSColor.systemOrange }
        return NSColor.labelColor
    }

    func ellipsize(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    func formatUptime(_ seconds: Int) -> String {
        if seconds >= 86400 {
            return "\(seconds / 86400)d\((seconds % 86400) / 3600)h"
        }
        if seconds >= 3600 {
            return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
        }
        return "\(seconds / 60)m"
    }

    func downsampled(_ history: [Double]?, _ width: Int) -> [Double]? {
        guard var vals = history, vals.count >= 2 else { return nil }
        if vals.count > width {
            let step = Double(vals.count) / Double(width)
            vals = (0..<width).map { i in
                let a = Int(Double(i) * step)
                let b = max(a + 1, Int(Double(i + 1) * step))
                return vals[a..<min(b, vals.count)].max() ?? vals[a]
            }
        }
        return vals
    }

    func sparkImage(_ history: [Double]?, buckets: Int, size: NSSize) -> NSImage? {
        guard let vals = downsampled(history, buckets) else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            let maxV = max(vals.max() ?? 0, 0.0001)
            let gap: CGFloat = 1.5
            let barW = (rect.width - CGFloat(vals.count - 1) * gap) / CGFloat(vals.count)
            for (i, v) in vals.enumerated() {
                let h = max(1.5, CGFloat(v / maxV) * rect.height)
                let color: NSColor = v >= thresholdGb ? .systemRed
                    : (i == vals.count - 1 ? .secondaryLabelColor : .tertiaryLabelColor)
                color.setFill()
                let bar = NSRect(x: CGFloat(i) * (barW + gap), y: 0, width: barW, height: h)
                NSBezierPath(roundedRect: bar, xRadius: barW / 3, yRadius: barW / 3).fill()
            }
            return true
        }
    }

    func sparkAttachment(_ img: NSImage, yOffset: CGFloat) -> NSAttributedString {
        let att = NSTextAttachment()
        att.image = img
        att.bounds = NSRect(x: 0, y: yOffset, width: img.size.width, height: img.size.height)
        return NSAttributedString(attachment: att)
    }

    func thresholdLabel(_ threshold: Double) -> String {
        threshold.rounded() == threshold ? String(format: "%.0f", threshold) : String(format: "%.1f", threshold)
    }

    @objc func refreshNow() { refresh() }

    @objc func focusSession(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [String: Any],
              let host = p["host"] as? String else { return }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == host || $0.bundleURL?.lastPathComponent == "\(host).app"
        }) {
            app.activate()
        }
        let tty = p["tty"] as? String
        if host == "Terminal", let tty {
            runAppleScript("""
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                  end if
                end repeat
              end repeat
            end tell
            """)
        } else if host.hasPrefix("iTerm"), let tty {
            runAppleScript("""
            tell application "iTerm2"
              repeat with w in windows
                repeat with tb in tabs of w
                  repeat with sn in sessions of tb
                    if tty of sn is "\(tty)" then
                      select sn
                      select tb
                      select w
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """)
        } else if host == "c11" || host == "cmux" {
            // Needs the host app's socket mode set to "Focus commands only"
            // (or looser) — the default ancestry mode rejects external peers
            // and these writes become harmless no-ops.
            var cmds: [String] = []
            if let ws = p["workspace"] as? String { cmds.append("select_workspace \(ws)") }
            if let surf = p["surface"] as? String { cmds.append("focus_surface \(surf)") }
            if !cmds.isEmpty {
                let sock = NSString(
                    string: "~/Library/Application Support/\(host)/\(host).sock").expandingTildeInPath
                muxSocketSend(cmds, socketPath: sock)
            }
        }
    }

    func muxSocketSend(_ commands: [String], socketPath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let ok: Bool = socketPath.withCString { src in
                withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                    guard socketPath.utf8.count < dst.count else { return false }
                    strlcpy(dst.baseAddress!.assumingMemoryBound(to: CChar.self), src, dst.count)
                    return true
                }
            }
            guard ok else { return }
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { return }
            var buf = [UInt8](repeating: 0, count: 1024)
            for cmd in commands {
                let line = cmd + "\n"
                guard line.withCString({ write(fd, $0, strlen($0)) }) > 0 else { return }
                _ = read(fd, &buf, buf.count)  // drain one response, best effort
            }
        }
    }

    func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: source)?.executeAndReturnError(nil)
        }
    }

    @objc func killAndCopy(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [String: Any],
              let pid = p["pid"] as? Int, let resume = p["resume"] as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resume, forType: .string)
        verifiedKill([pid], expect: p["expect"] as? String ?? "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    @objc func killOnly(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [String: Any],
              let pids = p["pids"] as? [Int] else { return }
        verifiedKill(pids, expect: p["expect"] as? String ?? "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    /// Menu data can be minutes old (the poll timer pauses while a menu is
    /// open) and pids get recycled. Never signal blind: a pid is only killed
    /// if it still exists AND its current argv matches the identity token
    /// recorded when the menu row was built. Stale/reused pids are skipped.
    func verifiedKill(_ pids: [Int], expect: String) {
        let live = currentArgs(of: pids)  // one ps for the whole set
        for pid in pids where pid > 1 {
            guard let args = live[pid] else { continue }  // already gone
            if !expect.isEmpty, !args.localizedCaseInsensitiveContains(expect) {
                continue  // pid was recycled by an unrelated process
            }
            kill(pid_t(pid), SIGTERM)
        }
    }

    /// Live argv for each still-running pid, via a single `ps` call.
    func currentArgs(of pids: [Int]) -> [Int: String] {
        let targets = pids.filter { $0 > 1 }.map(String.init)
        guard !targets.isEmpty else { return [:] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", targets.joined(separator: ","), "-o", "pid=,args="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var map: [Int: String] = [:]
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int(t[..<sp]) else { continue }
            map[pid] = String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        }
        return map
    }

    /// Identity token for a child row: first word of its label, pool prefix
    /// stripped ("13× node …" -> "node", "chrome-devtools-mcp" -> itself).
    func expectToken(_ label: String) -> String {
        var l = label
        if let r = l.range(of: #"^\d+× "#, options: .regularExpression) {
            l.removeSubrange(r)
        }
        return l.split(separator: " ").first.map(String.init) ?? ""
    }

    @objc func copyText(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [String: Any],
              let text = p["text"] as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
