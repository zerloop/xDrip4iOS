// Protocol facts from JugglucoNG PR #1011 (https://github.com/ctqvva/JugglucoNG/pull/1011), GPL-3.0. Independent Swift implementation.

import Foundation

/// a decoded Instara G1 frame
enum InstaraG1Packet: Equatable {
    case realtime(seq: Int, mmol: Double)
    case historyHeader(frameCount: Int)
    case history(startSeq: Int, durationField: Int, mmolValues: [Double])
    case battery(percent: Int)
    case handshake(hardware: Int, software: Int)
    case interval(minutes: Int)
    case unlisted(cmd: UInt8, payload: Data)
    /// reason is one of "HEADER", "CRC-FAIL", "LAYOUT-MISMATCH", "FRAGMENT-TIMEOUT"
    case invalid(reason: String, raw: Data)
}

/// frame layout: 55 AA | cmd | len | payload[len] | crc8
enum InstaraG1Protocol {

    static let headerByte0: UInt8 = 0x55
    static let headerByte1: UInt8 = 0xAA

    /// CRC-8/MAXIM: init 0, reflected polynomial 0x8C
    static func crc8(_ bytes: Data) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 0x01) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1
            }
        }
        return crc
    }

    /// parses one complete frame
    static func parse(frame: Data) -> InstaraG1Packet {
        let b = Array(frame)

        guard b.count >= 2, b[0] == headerByte0, b[1] == headerByte1 else {
            return .invalid(reason: "HEADER", raw: frame)
        }
        // header + cmd + len + crc = 5 bytes minimum
        guard b.count >= 5, Int(b[3]) == b.count - 5 else {
            return .invalid(reason: "LAYOUT-MISMATCH", raw: frame)
        }
        guard crc8(Data(b[0..<(b.count - 1)])) == b[b.count - 1] else {
            return .invalid(reason: "CRC-FAIL", raw: frame)
        }

        let cmd = b[2]
        let payload = Array(b[4..<(b.count - 1)])

        func u16(_ i: Int) -> Int { (Int(payload[i]) << 8) | Int(payload[i + 1]) }
        func mmol(_ i: Int) -> Double { Double(u16(i)) / 10.0 }
        func mismatch() -> InstaraG1Packet { .invalid(reason: "LAYOUT-MISMATCH", raw: frame) }

        switch cmd {
        case 0x01, 0x10:
            guard payload.count >= 4 else { return mismatch() }
            return .realtime(seq: u16(0), mmol: mmol(2))
        case 0x30:
            guard payload.count >= 6, (payload.count - 4) % 2 == 0 else { return mismatch() }
            var values = [Double]()
            var i = 4
            while i + 1 < payload.count {
                values.append(mmol(i))
                i += 2
            }
            return .history(startSeq: u16(0), durationField: u16(2), mmolValues: values)
        case 0x03:
            guard payload.count >= 1 else { return mismatch() }
            return .historyHeader(frameCount: Int(payload[0]))
        case 0x02, 0x20:
            guard payload.count >= 1 else { return mismatch() }
            return .battery(percent: Int(payload[0]))
        case 0xF0:
            guard payload.count >= 2 else { return mismatch() }
            return .handshake(hardware: Int(payload[0]), software: Int(payload[1]))
        case 0x0A:
            guard payload.count >= 2 else { return mismatch() }
            return .interval(minutes: u16(0))
        default:
            return .unlisted(cmd: cmd, payload: Data(payload))
        }
    }

    /// single log line for a packet; invalid and unlisted packets carry the raw hex
    static func logLine(_ packet: InstaraG1Packet) -> String {
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        switch packet {
        case let .realtime(seq, mmol):
            return "INSTARA-PKT;cmd=realtime;seq=\(seq);mmol=\(mmol)"
        case let .historyHeader(frameCount):
            return "INSTARA-PKT;cmd=historyHeader;frames=\(frameCount)"
        case let .history(startSeq, durationField, mmolValues):
            return "INSTARA-PKT;cmd=history;startSeq=\(startSeq);duration=\(durationField);count=\(mmolValues.count)"
        case let .battery(percent):
            return "INSTARA-PKT;cmd=battery;percent=\(percent)"
        case let .handshake(hardware, software):
            return "INSTARA-PKT;cmd=handshake;hw=\(hardware);sw=\(software)"
        case let .interval(minutes):
            return "INSTARA-PKT;cmd=interval;minutes=\(minutes)"
        case let .unlisted(cmd, payload):
            return "INSTARA-PKT;cmd=unlisted;id=\(String(format: "%02x", cmd));raw=\(hex(payload))"
        case let .invalid(reason, raw):
            return "INSTARA-PKT;cmd=invalid;reason=\(reason);raw=\(hex(raw))"
        }
    }
}

/// reassembles frames from BLE notifications: several frames per notification, or one frame split over two
struct InstaraG1FrameAssembler {

    private var buffer = [UInt8]()

    /// when the currently pending fragment started; not refreshed while the same fragment merely grows
    private var pendingSince: Date?

    mutating func feed(_ data: Data, now: Date) -> [InstaraG1Packet] {
        // a stale partial frame will never complete, drop it
        if !buffer.isEmpty, let since = pendingSince, now.timeIntervalSince(since) > ConstantsInstaraG1.fragmentTimeout {
            buffer.removeAll()
        }
        if buffer.isEmpty { pendingSince = nil }
        buffer.append(contentsOf: data)

        var packets = [InstaraG1Packet]()
        var advanced = false

        while true {
            // discard everything before the next header
            guard let start = headerIndex() else {
                // keep a trailing 0x55 which may be the first half of a header
                if let last = buffer.last, last == InstaraG1Protocol.headerByte0 {
                    if buffer.count > 1 { advanced = true }
                    buffer = [last]
                } else {
                    if !buffer.isEmpty { advanced = true }
                    buffer.removeAll()
                }
                break
            }
            if start > 0 { buffer.removeFirst(start); advanced = true }

            // need header + cmd + len to know the frame size
            guard buffer.count >= 4 else { break }
            let total = Int(buffer[3]) + 5
            guard buffer.count >= total else { break }

            let packet = InstaraG1Protocol.parse(frame: Data(buffer[0..<total]))
            packets.append(packet)
            advanced = true
            if case .invalid(let reason, _) = packet, reason == "CRC-FAIL" {
                // len may be corrupt: skip only the header and resync on the next one
                buffer.removeFirst(2)
            } else {
                buffer.removeFirst(total)
            }
        }

        if buffer.isEmpty {
            pendingSince = nil
        } else if advanced || pendingSince == nil {
            pendingSince = now
        }

        return packets
    }

    private func headerIndex() -> Int? {
        guard buffer.count >= 2 else { return nil }
        for i in 0..<(buffer.count - 1) where buffer[i] == InstaraG1Protocol.headerByte0 && buffer[i + 1] == InstaraG1Protocol.headerByte1 {
            return i
        }
        return nil
    }
}
