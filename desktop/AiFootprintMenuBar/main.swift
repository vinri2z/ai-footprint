// AI Footprint — macOS menu-bar app.
//
// A thin native shell around the existing dashboard: it keeps scripts/serve-report.py
// resident in the background, shows today's CO2 in the menu bar, and opens the full
// dashboard on click. All the actual computation stays in the bundled bash/python
// pipeline (tokscale → lib-factors.sh → footprint-data.sh); this app never does math.
//
// Distributed as a Homebrew cask; python/node/jq/git come from brew formula deps.

import AppKit
import Foundation
import ServiceManagement

// MARK: - Config

let kPort = ProcessInfo.processInfo.environment["AI_FOOTPRINT_PORT"] ?? "7331"
let kBaseURL = "http://127.0.0.1:\(kPort)"
let kPollInterval: TimeInterval = 60

// GUI apps launched from Finder inherit a minimal PATH that omits Homebrew, so the
// bundled scripts can't find python3/node/jq. Prepend the usual brew locations.
let kExtraPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

// MARK: - Formatting (mirrors the JS helpers in serve-report.py)

func co2Str(_ g: Double) -> String {
    if g >= 1_000_000 { return String(format: "%.2f tCO₂", g / 1_000_000) }
    if g >= 1_000 { return String(format: "%.2f kg", g / 1_000) }
    return String(format: "%.1f g", g)
}

func co2Short(_ g: Double) -> String {
    if g >= 1_000_000 { return String(format: "%.1ft", g / 1_000_000) }
    if g >= 1_000 { return String(format: "%.1fkg", g / 1_000) }
    return String(format: "%.0fg", g)
}

func waterStr(_ l: Double) -> String {
    if l >= 1_000 { return String(format: "%.2f m³", l / 1_000) }
    if l >= 1 { return String(format: "%.2f L", l) }
    return String(format: "%.0f mL", l * 1_000)
}

// MARK: - Script discovery

/// Locate the repo root that holds scripts/ and data/.
/// Order: AI_FOOTPRINT_DIR env → bundled Resources → legacy ~/code/ai-footprint.
func resolveRoot() -> String? {
    let fm = FileManager.default
    var candidates: [String] = []
    if let env = ProcessInfo.processInfo.environment["AI_FOOTPRINT_DIR"] {
        candidates.append(env)
    }
    if let res = Bundle.main.resourcePath {
        candidates.append(res)
    }
    candidates.append((NSHomeDirectory() as NSString).appendingPathComponent("code/ai-footprint"))

    for c in candidates {
        if fm.fileExists(atPath: (c as NSString).appendingPathComponent("scripts/serve-report.py")) {
            return c
        }
    }
    return nil
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var server: Process?
    var timer: Timer?
    var root: String?

    // Latest totals, keyed period → (co2, water, cost, tokens)
    var totals: [String: (co2: Double, water: Double, cost: Double, tokens: Double)] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "AI Footprint")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = " …"
        }

        root = resolveRoot()
        rebuildMenu()

        startServerIfNeeded()

        // Give the server a moment to compute the first page, then poll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: kPollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
    }

    // MARK: Server lifecycle

    func startServerIfNeeded() {
        guard let root = root else {
            NSLog("ai-footprint: could not locate scripts/serve-report.py")
            return
        }
        // If something is already serving on the port (e.g. /footprint-report), reuse it.
        if isServerUp() { return }

        let script = (root as NSString).appendingPathComponent("scripts/serve-report.py")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", script, "--no-browser", "--port", kPort]

        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? ""
        env["PATH"] = existing.isEmpty ? kExtraPATH : "\(kExtraPATH):\(existing)"
        proc.environment = env

        do {
            try proc.run()
            server = proc
        } catch {
            NSLog("ai-footprint: failed to start server: \(error)")
        }
    }

    func stopServer() {
        server?.terminate()
        server = nil
    }

    /// Synchronous reachability check (used only at startup).
    func isServerUp() -> Bool {
        guard let url = URL(string: "\(kBaseURL)/api/data.json") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        let sem = DispatchSemaphore(value: 0)
        var up = false
        let task = URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { up = true }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 1.5)
        return up
    }

    // MARK: Data

    func refresh() {
        guard let url = URL(string: "\(kBaseURL)/api/data.json") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5.0
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            var parsed: [String: (co2: Double, water: Double, cost: Double, tokens: Double)] = [:]
            for period in ["today", "year", "all"] {
                if let t = obj[period] as? [String: Any] {
                    parsed[period] = (
                        co2: (t["co2"] as? Double) ?? 0,
                        water: (t["water"] as? Double) ?? 0,
                        cost: (t["cost"] as? Double) ?? 0,
                        tokens: (t["tokens"] as? Double) ?? 0
                    )
                }
            }
            DispatchQueue.main.async {
                self.totals = parsed
                self.updateStatusTitle()
                self.rebuildMenu()
            }
        }.resume()
    }

    // MARK: UI

    func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        if let today = totals["today"] {
            button.title = " " + co2Short(today.co2)
        } else {
            button.title = " –"
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        if root == nil {
            let item = NSMenuItem(title: "Scripts not found — set AI_FOOTPRINT_DIR", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        } else if totals.isEmpty {
            let item = NSMenuItem(title: "Loading footprint…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        } else {
            addStat(to: menu, label: "Today", period: "today")
            addStat(to: menu, label: "This year", period: "year")
            addStat(to: menu, label: "All time", period: "all")
            menu.addItem(.separator())
        }

        let open = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(manualRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled() ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit AI Footprint", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func addStat(to menu: NSMenu, label: String, period: String) {
        guard let t = totals[period] else { return }
        let header = NSMenuItem(title: "\(label): \(co2Str(t.co2))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let sub = NSMenuItem(title: "   \(waterStr(t.water)) water · $\(String(format: "%.2f", t.cost))",
                             action: nil, keyEquivalent: "")
        sub.isEnabled = false
        menu.addItem(sub)
    }

    // MARK: Actions

    @objc func openDashboard() {
        if let url = URL(string: "http://localhost:\(kPort)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func manualRefresh() { refresh() }

    @objc func quit() {
        stopServer()
        NSApp.terminate(nil)
    }

    // MARK: Launch-at-login (SMAppService, macOS 13+)

    func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSLog("ai-footprint: login toggle failed: \(error)")
            }
            rebuildMenu()
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
