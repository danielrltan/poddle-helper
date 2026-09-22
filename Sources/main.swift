// Poddle Helper: lets the Poddle web page (https://poddleball.com) read one AirPod's motion.
//
// What this file does, top to bottom:
//   1. A WebSocket server on 127.0.0.1 and ::1 only (never reachable from other machines).
//   2. It only accepts browser pages from Poddle's own addresses (Origin allowlist).
//   3. While at least one Poddle page is connected, it reads headphone motion from CoreMotion
//      and sends each sample to the page as one small JSON message. When the last page
//      disconnects, it stops reading motion.
//   4. A menu bar icon that shows what is going on.
//
// It never opens a connection to the internet. It reads nothing except headphone motion.

import AppKit
import CoreMotion
import CryptoKit
import Foundation
import Network

let env = ProcessInfo.processInfo.environment
let port = UInt16(env["PODDLE_HELPER_PORT"] ?? "") ?? 8787
let fakeMotion = env["PODDLE_HELPER_FAKE"] == "1"   // test hook: synthetic samples, no AirPods needed

let poddleURL = URL(string: "https://poddleball.com")!
let sourceURL = URL(string: "https://github.com/danielrltan/poddle-helper")!
let motionSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Motion")!

func log(_ s: String) { FileHandle.standardError.write(("[poddle-helper] " + s + "\n").data(using: .utf8)!) }

// MARK: - Who may connect

/// Web pages send an Origin header saying which site they come from. Only Poddle's sites
/// (and localhost, for development) are allowed. Native programs on this Mac send no Origin.
func originAllowed(_ origin: String?) -> Bool {
    guard let origin = origin else { return true }
    guard let url = URLComponents(string: origin), let host = url.host?.lowercased() else { return false }
    switch url.scheme?.lowercased() {
    case "https": return url.port == nil && ["poddleball.com", "www.poddleball.com", "poddle.fly.dev"].contains(host)
    case "http":  return ["localhost", "127.0.0.1"].contains(host)
    default:      return false
    }
}

// MARK: - WebSocket server (loopback only)
//
// A deliberately small WebSocket server (RFC 6455) written by hand on top of plain TCP,
// so that we can read the browser's Origin header ourselves before accepting anything.
// It only ever sends text messages, and only reads what the page sends to notice ping/close.

final class Server {
    private var listeners: [NWListener] = []
    private var clients: [ObjectIdentifier: NWConnection] = [:]   // only connections that passed the checks
    var clientCount: Int { clients.count }
    var onClientsChanged: () -> Void = {}
    var onError: (String) -> Void = { _ in }

    func start() {
        // One listener per loopback address. "localhost" can mean either one in the browser.
        for host in [NWEndpoint.Host.ipv4(.loopback), NWEndpoint.Host.ipv6(.loopback)] {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true   // lets a restart reuse the port right away
            do {
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] c in c.start(queue: .main); self?.handshake(c) }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        log("listener on \(host) failed: \(error)")
                        self?.onError("Port \(port) is busy. Is another copy running?")
                    }
                }
                listener.start(queue: .main)
                listeners.append(listener)
            } catch {
                log("could not listen on \(host):\(port): \(error)")
                onError("Port \(port) is busy. Is another copy running?")
            }
        }
        log("listening on ws://127.0.0.1:\(port) and ws://[::1]:\(port)")
    }

    // Step 1: read the HTTP upgrade request, check it, answer 101 (accept) or 403 (reject).
    private func handshake(_ c: NWConnection, buffer: Data = Data()) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error != nil || done || buffer.count > 16384 { c.cancel() } else { self.handshake(c, buffer: buffer) }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let origin = headers["origin"]
            guard lines.first?.hasPrefix("GET ") == true,
                  headers["upgrade"]?.lowercased() == "websocket",
                  let key = headers["sec-websocket-key"],
                  originAllowed(origin) else {
                log("REJECTED connection from origin \(origin ?? "(none)")")
                let reply = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
                return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
            log("accepted connection from origin \(origin ?? "(none)")")

            let id = ObjectIdentifier(c)
            self.clients[id] = c
            c.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    if self?.clients.removeValue(forKey: id) != nil { self?.onClientsChanged() }
                default: break
                }
            }
            self.onClientsChanged()
            self.readFrames(c, buffer: Data(buffer[end.upperBound...]))
        }
    }

    // Step 2: read frames from the page. We only act on ping (answer pong) and close.
    private func readFrames(_ c: NWConnection, buffer: Data) {
        var buffer = buffer
        while let (opcode, payload, used) = Server.parseFrame(buffer) {
            buffer.removeFirst(used)
            if opcode == 0x8 { c.send(content: Server.frame(opcode: 0x8, payload: Data()), completion: .contentProcessed { _ in c.cancel() }); return }
            if opcode == 0x9 { c.send(content: Server.frame(opcode: 0xA, payload: payload), completion: .idempotent) }
        }
        if buffer.count > 1 << 20 { c.cancel(); return }   // the page has no reason to send us much
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            if error != nil || done { c.cancel(); return }
            self?.readFrames(c, buffer: buffer + (data ?? Data()))
        }
    }

    /// Parses one client frame: returns opcode, unmasked payload, and bytes used; nil if incomplete.
    static func parseFrame(_ d: Data) -> (UInt8, Data, Int)? {
        let b = [UInt8](d.prefix(14))
        guard b.count >= 2 else { return nil }
        var len = Int(b[1] & 0x7F), pos = 2
        if len == 126 { guard b.count >= 4 else { return nil }; len = Int(b[2]) << 8 | Int(b[3]); pos = 4 }
        if len == 127 { guard b.count >= 10 else { return nil }; len = b[2..<10].reduce(0) { $0 << 8 | Int($1) }; pos = 10 }
        if len > 1 << 20 { return (0x8, Data(), d.count) }   // absurdly large: treat as close
        let masked = b[1] & 0x80 != 0
        let mask = masked ? Array(d.dropFirst(pos).prefix(4)) : []
        pos += masked ? 4 : 0
        guard d.count >= pos + len else { return nil }
        var payload = [UInt8](d.dropFirst(pos).prefix(len))
        if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
        return (b[0] & 0x0F, Data(payload), pos + len)
    }

    /// Builds one unmasked server frame (servers never mask).
    static func frame(opcode: UInt8, payload: Data) -> Data {
        var f = Data([0x80 | opcode])
        switch payload.count {
        case ..<126:   f.append(UInt8(payload.count))
        case ..<65536: f.append(126); f.append(UInt8(payload.count >> 8)); f.append(UInt8(payload.count & 0xFF))
        default:       f.append(127); for s in stride(from: 56, through: 0, by: -8) { f.append(UInt8((payload.count >> s) & 0xFF)) }
        }
        return f + payload
    }

    func broadcast(_ text: String) {
        let f = Server.frame(opcode: 0x1, payload: Data(text.utf8))
        for c in clients.values { c.send(content: f, completion: .idempotent) }
    }
}

// MARK: - Motion

/// One sample, in the exact shape the Poddle page expects:
/// t = seconds, loc = which bud (1 left, 2 right, 0 unknown), q = attitude quaternion [x,y,z,w],
/// r = rotation rate in rad/s [x,y,z], a = user acceleration in g [x,y,z].
func sampleJSON(t: Double, loc: Int, q: [Double], r: [Double], a: [Double]) -> String {
    let obj: [String: Any] = ["t": t, "loc": loc, "q": q, "r": r, "a": a]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(decoding: data, as: UTF8.self)
}

final class Motion: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private var watchdog: Timer?
    private var fakeTimer: Timer?
    private(set) var running = false
    private(set) var samples = 0
    private(set) var budsConnected = false
    private(set) var lastLoc = 0
    private(set) var problem: String?           // shown in the menu when something is wrong
    var onSample: (String) -> Void = { _ in }
    var onStatus: () -> Void = {}

    var accessDenied: Bool {
        let s = CMHeadphoneMotionManager.authorizationStatus()
        return s == .denied || s == .restricted
    }

    func start() {
        guard !running else { return }
        running = true; samples = 0; problem = nil
        log("motion STARTED (a Poddle page is connected)")
        if fakeMotion { startFake(); return }

        manager.delegate = self
        guard manager.isDeviceMotionAvailable else {
            problem = "Headphone motion is not available on this Mac"
            onStatus(); return
        }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] m, error in
            guard let self = self else { return }
            if let error = error { log("motion error: \(error.localizedDescription)"); return }
            guard let m = m else { return }
            let q = m.attitude.quaternion, r = m.rotationRate, a = m.userAcceleration
            self.deliver(sampleJSON(t: m.timestamp, loc: m.sensorLocation.rawValue,
                                    q: [q.x, q.y, q.z, q.w], r: [r.x, r.y, r.z], a: [a.x, a.y, a.z]),
                         loc: m.sensorLocation.rawValue)
        }
        // Watchdog: CoreMotion fails silently, so turn "nothing is happening" into a reason.
        var lastCount = 0
        watchdog = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.accessDenied {
                self.problem = "Motion access is off"
            } else if self.samples == lastCount {
                self.problem = self.budsConnected
                    ? "No motion. Turn off Automatic Ear Detection"
                    : "AirPods not found. Connect them as sound output"
                log("no samples in 4s: \(self.problem!)")
            } else {
                self.problem = nil
                log("\(self.samples) samples")
            }
            lastCount = self.samples
            self.onStatus()
        }
        onStatus()
    }

    func stop() {
        guard running else { return }
        running = false
        watchdog?.invalidate(); watchdog = nil
        fakeTimer?.invalidate(); fakeTimer = nil
        if !fakeMotion { manager.stopDeviceMotionUpdates() }
        log("motion STOPPED (no Poddle page connected)")
        onStatus()
    }

    private func deliver(_ json: String, loc: Int) {
        samples += 1
        lastLoc = loc
        if samples == 1 { problem = nil; log("first sample received, motion is live") }
        onSample(json)
        if samples % 50 == 0 || samples == 1 { onStatus() }
    }

    /// Test hook: a slow rotation about the vertical axis at 50 Hz.
    private func startFake() {
        let t0 = Date()
        fakeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 50, repeats: true) { [weak self] _ in
            let t = Date().timeIntervalSince(t0), angle = t * 0.5
            self?.deliver(sampleJSON(t: t, loc: 1, q: [0, sin(angle / 2), 0, cos(angle / 2)],
                                     r: [0, 0.5, 0], a: [0, 0, 0]), loc: 1)
        }
    }

    func headphoneMotionManagerDidConnect(_ m: CMHeadphoneMotionManager) {
        budsConnected = true; log("headphones connected"); onStatus()
    }
    func headphoneMotionManagerDidDisconnect(_ m: CMHeadphoneMotionManager) {
        budsConnected = false; log("headphones disconnected"); onStatus()
    }
}

// MARK: - Menu bar

final class App: NSObject, NSApplicationDelegate {
    let server = Server()
    let motion = Motion()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let settingsItem = NSMenuItem(title: "Turn on Motion access…", action: #selector(openMotionSettings), keyEquivalent: "")
    var serverError: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        if let image = NSImage(systemSymbolName: "airpod.right", accessibilityDescription: "Poddle Helper") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "Poddle"
        }

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Poddle", #selector(openPoddle)))
        menu.addItem(item("About / View source", #selector(openSource)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Poddle Helper", #selector(NSApplication.terminate(_:)), key: "q"))
        statusItem.menu = menu

        server.onClientsChanged = { [unowned self] in
            log("clients connected: \(server.clientCount)")
            if server.clientCount > 0 { motion.start() } else { motion.stop() }
            refresh()
        }
        server.onError = { [unowned self] msg in serverError = msg; refresh() }
        motion.onSample = { [unowned self] json in server.broadcast(json) }
        motion.onStatus = { [unowned self] in refresh() }
        server.start()
        refresh()
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action != #selector(NSApplication.terminate(_:)) { i.target = self }
        return i
    }

    func refresh() {
        let text: String
        if let e = serverError {
            text = e
        } else if server.clientCount == 0 {
            text = "Waiting for Poddle to connect"
        } else if motion.accessDenied {
            text = "Motion access is off"
        } else if let p = motion.problem {
            text = p
        } else if motion.samples == 0 {
            text = "Poddle connected. Take one AirPod out"
        } else {
            let bud = [1: "left ", 2: "right "][motion.lastLoc] ?? ""
            text = "Streaming from \(bud)AirPod (\(motion.samples) samples)"
        }
        statusLine.title = text
        settingsItem.isHidden = !motion.accessDenied
    }

    @objc func openPoddle() { NSWorkspace.shared.open(poddleURL) }
    @objc func openSource() { NSWorkspace.shared.open(sourceURL) }
    @objc func openMotionSettings() { NSWorkspace.shared.open(motionSettingsURL) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
