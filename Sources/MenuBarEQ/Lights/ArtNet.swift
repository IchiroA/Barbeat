import Foundation
import Darwin
import QuartzCore

/// Art-Net 4 packets, DMX layout, node search and WLED detection.
enum ArtNet {
    static let port: UInt16 = 6454
    private static let header: [UInt8] = Array("Art-Net".utf8) + [0]

    /// ArtDmx: one universe of DMX data. `universe` is the 15-bit port address.
    static func dmxPacket(universe: Int, sequence: UInt8, data: [UInt8]) -> [UInt8] {
        var data = data
        if data.count % 2 == 1 { data.append(0) }          // length must be even
        if data.count < 2 { data += [UInt8](repeating: 0, count: 2 - data.count) }
        let length = min(512, data.count)
        var packet = header
        packet += [0x00, 0x50]                               // OpCode 0x5000, little-endian
        packet += [0x00, 14]                                 // protocol version 14
        packet += [sequence, 0]                              // sequence, physical
        packet += [UInt8(universe & 0xFF), UInt8((universe >> 8) & 0x7F)] // SubUni, Net
        packet += [UInt8(length >> 8), UInt8(length & 0xFF)]
        packet += data.prefix(length)
        return packet
    }

    /// ArtPoll: asks every node on the network to answer with an ArtPollReply.
    static let pollPacket: [UInt8] = header + [0x00, 0x20, 0x00, 14, 0x00, 0x00]

    /// A node that answered an ArtPoll.
    struct Node: Identifiable, Equatable {
        var ip: String
        var shortName: String
        var longName: String
        /// Port address of its first output.
        var universe: Int
        var id: String { ip }
        var name: String { shortName.isEmpty ? (longName.isEmpty ? ip : longName) : shortName }
    }

    static func parsePollReply(_ bytes: [UInt8]) -> Node? {
        guard bytes.count >= 194, Array(bytes[0..<8]) == header, bytes[8] == 0x00, bytes[9] == 0x21 else { return nil }
        let ip = "\(bytes[10]).\(bytes[11]).\(bytes[12]).\(bytes[13])"
        func text(_ range: Range<Int>) -> String {
            let raw = bytes[range].prefix { $0 != 0 }
            return String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        let universe = (Int(bytes[18] & 0x7F) << 8) | (Int(bytes[19] & 0x0F) << 4) | Int(bytes[190] & 0x0F)
        return Node(ip: ip, shortName: text(26..<44), longName: text(44..<108), universe: universe)
    }

    // MARK: - DMX layout

    /// The DMX data for a device's lights: fixture after fixture from the start address, moving on to the
    /// next universe when one is full (170 RGB pixels each, like WLED).
    static func universes(for device: ArtNetDevice, colors: [LightColor]) -> [(universe: Int, data: [UInt8])] {
        let footprint = device.profile.channels
        var buffers: [Int: [UInt8]] = [:]
        var universe = device.universe
        var address = max(0, min(511, device.startAddress - 1))
        for color in colors {
            if address + footprint > 512 {
                universe += 1
                address = 0
            }
            guard universe <= 0x7FFF else { break }
            var buffer = buffers[universe] ?? []
            if buffer.count < address { buffer += [UInt8](repeating: 0, count: address - buffer.count) }
            let values = channelValues(color, profile: device.profile, gamma: device.gamma)
            buffer.replaceSubrange(address..<min(buffer.count, address + footprint), with: values)
            buffers[universe] = buffer
            address += footprint
        }
        return buffers.keys.sorted().map { ($0, buffers[$0]!) }
    }

    /// One fixture's channel values. Colors are perceptual, LEDs are linear, so gamma correction makes dim colors right.
    static func channelValues(_ c: LightColor, profile: FixtureProfile, gamma: Bool) -> [UInt8] {
        func level(_ v: Float) -> Float {
            let v = min(1, max(0, v))
            return gamma ? pow(v, 2.2) : v
        }
        func byte(_ v: Float) -> UInt8 { UInt8((min(1, max(0, v)) * 255).rounded()) }
        let shown = c.shown
        let full = SIMD3(level(c.r), level(c.g), level(c.b))
        let lit = SIMD3(level(shown.x), level(shown.y), level(shown.z))
        let dim = byte(level(c.brightness))
        func whiteSplit(_ v: SIMD3<Float>) -> [UInt8] {
            let w = min(v.x, v.y, v.z)
            return [byte(v.x - w), byte(v.y - w), byte(v.z - w), byte(w)]
        }
        switch profile {
        case .rgb: return [byte(lit.x), byte(lit.y), byte(lit.z)]
        case .grb: return [byte(lit.y), byte(lit.x), byte(lit.z)]
        case .rgbw: return whiteSplit(lit)
        case .dimmerRGB: return [dim, byte(full.x), byte(full.y), byte(full.z)]
        case .rgbDimmer: return [byte(full.x), byte(full.y), byte(full.z), dim]
        case .dimmerRGBW: return [dim] + whiteSplit(full)
        }
    }

    // MARK: - Network

    /// Turns "192.168.1.20", "wled.local" or "host:port" into a socket address. Blocks: call off the main thread.
    static func resolve(_ host: String) -> sockaddr_in? {
        var name = host.trimmingCharacters(in: .whitespaces)
        var port = ArtNet.port
        if let colon = name.lastIndex(of: ":"), let p = UInt16(name[name.index(after: colon)...]) {
            port = p
            name = String(name[..<colon])
        }
        guard !name.isEmpty else { return nil }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let raw = first.pointee.ai_addr else { return nil }
        var address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        address.sin_port = port.bigEndian
        return address
    }

    /// Sends an ArtPoll to every network and collects the answers for `seconds`.
    static func findNodes(seconds: Double = 2, completion: @escaping ([Node], String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = poll(seconds: seconds)
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
    }

    private static func poll(seconds: Double) -> ([Node], String?) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return ([], "Couldn't open a network socket.") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = ArtNet.port.bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            return ([], "Couldn't listen for answers on port 6454. Is another Art-Net app open?")
        }
        var sent = 0
        for target in broadcastAddresses() {
            var address = target
            address.sin_port = ArtNet.port.bigEndian
            let n = pollPacket.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if n > 0 { sent += 1 }
        }
        guard sent > 0 else {
            return ([], "Couldn't send on the local network. If macOS asked, allow Barbeat under Privacy & Security › Local Network.")
        }
        var nodes: [Node] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0, let node = parsePollReply(Array(buffer[0..<n])) else { continue }
            if !nodes.contains(where: { $0.ip == node.ip }) { nodes.append(node) }
        }
        return (nodes, nil)
    }

    /// The broadcast address of every IPv4 network the Mac is on, plus the all-networks one.
    private static func broadcastAddresses() -> [sockaddr_in] {
        var list: [sockaddr_in] = []
        var all = sockaddr_in()
        all.sin_family = sa_family_t(AF_INET)
        all.sin_addr.s_addr = INADDR_BROADCAST
        list.append(all)
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return list }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let broadcast = ifa.ifa_dstaddr else { continue }
            list.append(broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee })
        }
        return list
    }

    /// What a WLED controller reports about itself (nil if the address isn't WLED).
    struct WLEDInfo {
        var name: String
        var ledCount: Int
        var rgbw: Bool
        var universe: Int?
        var startAddress: Int?
        /// WLED's realtime receiver listens for Art-Net (port 6454) rather than E1.31.
        var usesArtNet: Bool?
        var receiverOn: Bool?
    }

    static func detectWLED(host: String) async -> WLEDInfo? {
        let base = "http://\(host.trimmingCharacters(in: .whitespaces))"
        func json(_ path: String) async -> [String: Any]? {
            guard let url = URL(string: base + path) else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let info = await json("/json/info"), let leds = info["leds"] as? [String: Any] else { return nil }
        var result = WLEDInfo(name: info["name"] as? String ?? "WLED", ledCount: leds["count"] as? Int ?? 1,
                              rgbw: leds["rgbw"] as? Bool ?? false)
        if let config = await json("/json/cfg"), let interfaces = config["if"] as? [String: Any],
           let live = interfaces["live"] as? [String: Any] {
            result.receiverOn = live["en"] as? Bool
            if let port = live["port"] as? Int { result.usesArtNet = port == Int(ArtNet.port) }
            if let dmx = live["dmx"] as? [String: Any] {
                result.universe = dmx["uni"] as? Int
                result.startAddress = dmx["addr"] as? Int
            }
        }
        return result
    }
}

/// The one UDP socket Barbeat sends Art-Net from (an ephemeral port, so it never blocks other Art-Net apps).
final class ArtNetSocket {
    static let shared = ArtNetSocket()
    private var fd: Int32 = -1

    /// Returns 0, or the errno of a failed send.
    func send(_ packet: [UInt8], to address: sockaddr_in) -> Int32 {
        if fd < 0 {
            fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return errno }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        var address = address
        let n = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return n < 0 ? errno : 0
    }
}

/// Plays the light show on an Art-Net device.
final class ArtNetOutput: LightOutput {
    private(set) var device: ArtNetDevice
    let id: String
    let kind = "Art-Net"
    var title: String { device.name.isEmpty ? device.host : device.name }
    private(set) var slots: [LightSlot]
    let maxRate = 44.0
    var onChange: (() -> Void)?
    private(set) var state: LightOutputState = .idle { didSet { if state != oldValue { onChange?() } } }

    private var address: sockaddr_in?
    private var sequence: UInt8 = 0
    private var lastFrame: [LightColor] = []
    private var errors = 0
    private var fadeTimer: Timer?
    private var resolving = 0

    init(device: ArtNetDevice) {
        self.device = device
        id = "artnet:\(device.id.uuidString)"
        slots = LightSlot.row(max(1, device.count), reversed: device.reversed)
    }

    var detail: String {
        let count = max(1, device.count)
        return "\(count) \(count == 1 ? "light" : "lights") · universe \(device.universe), address \(device.startAddress) · \(device.profile.title)"
    }

    func update(_ device: ArtNetDevice) {
        let moved = device.host != self.device.host
        self.device = device
        slots = LightSlot.row(max(1, device.count), reversed: device.reversed)
        if moved {
            address = nil
            if state == .live { resolveAndGoLive() }
        }
        if case .failed = state { state = .idle }
        if case .needsSetup = state { state = .idle }
    }

    func takeOver() {
        fadeTimer?.invalidate()
        resolveAndGoLive()
    }

    private func resolveAndGoLive() {
        guard !device.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            state = .needsSetup("Enter the device's IP address.")
            return
        }
        if address != nil {
            errors = 0
            state = .live
            return
        }
        state = .connecting
        resolving += 1
        let ticket = resolving, host = device.host
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = ArtNet.resolve(host)
            DispatchQueue.main.async {
                guard ticket == self.resolving, self.state == .connecting else { return }
                if let resolved {
                    self.address = resolved
                    self.errors = 0
                    self.state = .live
                } else {
                    self.state = .failed("Can't find \(host) on the network.")
                }
            }
        }
    }

    func send(_ colors: [LightColor]) {
        guard state == .live else { return }
        lastFrame = colors
        transmit(colors)
    }

    private func transmit(_ colors: [LightColor]) {
        guard let address else { return }
        for (universe, data) in ArtNet.universes(for: device, colors: colors) {
            sequence = sequence == 255 ? 1 : sequence + 1
            let error = ArtNetSocket.shared.send(ArtNet.dmxPacket(universe: universe, sequence: sequence, data: data), to: address)
            if error == 0 || error == ENOBUFS || error == EAGAIN {
                if error == 0 { errors = 0 }
                continue
            }
            errors += 1
            // A few misses are normal (Wi-Fi hiccups); many in a row mean the device can't be reached.
            if errors > 40, state == .live {
                state = .failed(error == EHOSTUNREACH || error == EPERM
                    ? "Can't reach \(device.host). If macOS asked, allow Barbeat under Privacy & Security › Local Network."
                    : "Can't reach \(device.host) (\(String(cString: strerror(error)))).")
            }
        }
    }

    var endWithLightsOff = false

    func giveBack(completion: @escaping () -> Void) {
        resolving += 1
        if endWithLightsOff {
            // Sleep timer: black, and WLED switched off so it doesn't go back to its own effect.
            endWithLightsOff = false
            if !lastFrame.isEmpty { transmit(lastFrame.map { _ in .off }) }
            Self.switchOffWLED(host: device.host)
            state = .idle
            completion()
            return
        }
        guard state == .live, !lastFrame.isEmpty else {
            state = .idle
            completion()
            return
        }
        state = .givingBack
        switch device.onStop {
        case .handBack:
            state = .idle
            completion()
        case .hold:
            transmit(lastFrame)
            state = .idle
            completion()
        case .fadeOut:
            let start = CACurrentMediaTime(), from = lastFrame
            fadeTimer?.invalidate()
            fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let t = Float(min(1, (CACurrentMediaTime() - start) / 1.0))
                self.transmit(from.map { var c = $0; c.brightness *= 1 - t; return c })
                if t >= 1 {
                    timer.invalidate()
                    self.transmit(from.map { _ in .off })
                    self.state = .idle
                    completion()
                }
            }
        }
    }

    /// Asks a WLED at `host` to switch off (its JSON API). Anything else just doesn't answer.
    static func switchOffWLED(host: String) {
        let address = host.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty, let url = URL(string: "http://\(address)/json/state") else { return }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"on":false}"#.utf8)
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    /// Quitting: no timers will run, so do the device's stop action right away.
    func giveBackBeforeQuit() {
        resolving += 1
        fadeTimer?.invalidate()
        if state == .live || state == .givingBack, !lastFrame.isEmpty {
            switch device.onStop {
            case .handBack: break
            case .hold: transmit(lastFrame)
            case .fadeOut: transmit(lastFrame.map { _ in .off })
            }
        }
        state = .idle
    }

    /// One white flash, so you can tell which device this is.
    func identify() {
        let white = slots.map { _ in LightColor.white }
        let flash = { [weak self] in
            guard let self else { return }
            for delay in [0.0, 0.15, 0.3, 0.45] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.transmit(white) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if self.state != .live { self.transmit(self.slots.map { _ in .off }) }
            }
        }
        if address != nil { flash(); return }
        let host = device.host
        DispatchQueue.global().async {
            let resolved = ArtNet.resolve(host)
            DispatchQueue.main.async {
                self.address = resolved
                if resolved != nil { flash() }
            }
        }
    }

    func shutdown() {
        resolving += 1
        fadeTimer?.invalidate()
    }
}
