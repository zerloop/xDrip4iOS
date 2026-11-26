// Portions derived from Juggluco (https://github.com/j-kaltes/Juggluco), Copyright (C) 2021 Jaap Korthals Altes, GPL-3.0.

import Foundation

/// firmware family of the sensor, derived from the packet format
enum SibionicsGS1Firmware {
    case legacy
    case v120
}

/// one glucose record as sent by the sensor
struct SibionicsGS1Record: Equatable {

    let index: Int
    let timeStamp: Date
    let temperatureC: Double
    /// raw sensor value in mmol/L
    let rawMmol: Double
    let dump: Int
    let extra: Int

    var rawMgDl: Double { rawMmol * ConstantsSibionicsGS1.mmolToMgDl }

    var glucoseLevelRaw: Double { rawMgDl * 1000 }

    var isInValidRange: Bool {
        rawMmol >= ConstantsSibionicsGS1.minValidMmol && rawMmol <= ConstantsSibionicsGS1.maxValidMmol
    }

}

/// result of classifying one notification packet
enum SibionicsGS1Packet: Equatable {
    case records(firmware: SibionicsGS1Firmware, records: [SibionicsGS1Record], reindex: Int?)
    case ack(cmd: UInt8, status: UInt8, aux: UInt8)
    case unknownData(cmd: UInt8, decrypted: Data)
    case invalid(raw: Data, decrypted: Data)
}

/// pure decoder for Sibionics GS1 packets, no CoreBluetooth
enum SibionicsGS1Protocol {

    /// commands that carry data we do not (yet) interpret
    private static let unknownDataCommands: Set<UInt8> = [0x0A, 0x3E, 0x40, 0x41, 0x42, 0x66, 0xF2, 0x17, 0x18, 0xF0]

    private static let plainBypassPacket: [UInt8] = [0x04, 0x00, 0x00, 0x00, 0xFC]

    /// standard RC4, key stream restarts at every call
    static func rc4(key: [UInt8], data: Data) -> Data {

        guard !key.isEmpty else { return data }

        var s = [UInt8](0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
            s.swapAt(i, j)
        }

        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var i = 0
        j = 0
        for byte in data {
            i = (i + 1) & 0xFF
            j = (j + Int(s[i])) & 0xFF
            s.swapAt(i, j)
            out.append(byte ^ s[(Int(s[i]) + Int(s[j])) & 0xFF])
        }

        return Data(out)

    }

    /// classify a raw notification packet
    static func classify(_ raw: Data, receivedAt: Date) -> SibionicsGS1Packet {

        // Data slices may have non-zero startIndex, normalise
        let rawBytes = [UInt8](raw)

        guard rawBytes.count >= 5 else {
            return .invalid(raw: raw, decrypted: Data())
        }

        // legacy firmware: plain, big endian
        if rawBytes[0] == 0xAA, rawBytes[1] == 0x55, rawBytes[2] == 0x09, checksumIsValid(rawBytes) {
            if let packet = decodeLegacy(rawBytes, receivedAt: receivedAt) {
                return packet
            }
            return .invalid(raw: raw, decrypted: raw)
        }

        // choose plain or decrypted
        let frame: [UInt8]
        if rawBytes == plainBypassPacket {
            frame = rawBytes
        } else {
            let decrypted = [UInt8](rc4(key: ConstantsSibionicsGS1.rc4Key, data: raw))
            if frameIsValid(decrypted) {
                frame = decrypted
            } else if frameIsValid(rawBytes) {
                frame = rawBytes
            } else {
                return .invalid(raw: raw, decrypted: Data(decrypted))
            }
        }

        let cmd = frame[1]

        // ack
        if frame[0] == 4 {
            return .ack(cmd: cmd, status: frame[2], aux: frame[3])
        }

        if cmd == 0x08 {
            return decodeV120(frame, raw: raw)
        }

        if unknownDataCommands.contains(cmd) {
            return .unknownData(cmd: cmd, decrypted: Data(frame))
        }

        return .invalid(raw: raw, decrypted: Data(frame))

    }

    /// line used to compare raw values with calibrated values, parsable from the log
    static func comparisonLine(_ r: SibionicsGS1Record, calibratedMgDl: Double?) -> String {

        let ms = Int((r.timeStamp.timeIntervalSince1970 * 1000).rounded())
        let calibrated = calibratedMgDl.map { String(Int($0.rounded())) } ?? "-"

        return "SIBCMP;\(ms);\(r.index);\(r.rawMmol);\(r.temperatureC);\(calibrated)"

    }

    // MARK: - private helpers

    /// sum of all bytes (including checksum byte) must be 0 modulo 256
    private static func checksumIsValid(_ bytes: [UInt8]) -> Bool {
        return bytes.reduce(0, { $0 &+ $1 }) == 0
    }

    /// length field must match the packet length and checksum must be valid
    private static func frameIsValid(_ bytes: [UInt8]) -> Bool {
        return bytes.count >= 5 && Int(bytes[0]) == bytes.count - 1 && checksumIsValid(bytes)
    }

    private static func u16LE(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }

    private static func u16BE(_ b: [UInt8], _ o: Int) -> Int { (Int(b[o]) << 8) | Int(b[o + 1]) }

    /// v1.2.0 firmware: [len][0x08][count][index u16][itime u32][count * 8 bytes: temp, dump, current, extra][reindex u16][checksum], little endian
    private static func decodeV120(_ frame: [UInt8], raw: Data) -> SibionicsGS1Packet {

        let count = Int(frame[2])

        if count == 0 {
            return .records(firmware: .v120, records: [], reindex: nil)
        }

        // payload between the 3 header bytes and the checksum
        let payloadSize = frame.count - 4

        guard 6 + 8 * count + 2 <= payloadSize else {
            return .invalid(raw: raw, decrypted: Data(frame))
        }

        let startIndex = u16LE(frame, 3)
        let itime = Int(frame[5]) | (Int(frame[6]) << 8) | (Int(frame[7]) << 16) | (Int(frame[8]) << 24)

        var records = [SibionicsGS1Record]()
        for i in 0..<count {
            let o = 9 + 8 * i
            records.append(SibionicsGS1Record(
                index: startIndex + i,
                timeStamp: Date(timeIntervalSince1970: TimeInterval(itime + 60 * i)),
                temperatureC: Double(u16LE(frame, o)) / 10.0,
                rawMmol: Double(u16LE(frame, o + 4)) / 10.0,
                dump: u16LE(frame, o + 2),
                extra: u16LE(frame, o + 6)))
        }

        return .records(firmware: .v120, records: records, reindex: u16LE(frame, 9 + 8 * count))

    }

    /// legacy firmware: AA 55 09 [count] count * 14 bytes big endian [checksum]
    private static func decodeLegacy(_ b: [UInt8], receivedAt: Date) -> SibionicsGS1Packet? {

        let count = Int(b[3])

        guard count > 0, b.count == 4 + 14 * count + 1 else { return nil }

        var records = [SibionicsGS1Record]()
        for i in 0..<count {
            let o = 4 + 14 * i
            let unreceived = u16BE(b, o + 10)
            let addTime = u16BE(b, o + 12)
            let offTime = addTime - unreceived * 60
            // a record can not be in the future
            let timeStamp = offTime > 0 ? receivedAt : receivedAt.addingTimeInterval(TimeInterval(offTime))
            records.append(SibionicsGS1Record(
                index: u16BE(b, o),
                timeStamp: timeStamp,
                temperatureC: Double(u16BE(b, o + 2)) / 10.0,
                rawMmol: Double(u16BE(b, o + 6)) / 10.0,
                dump: u16BE(b, o + 4),
                extra: u16BE(b, o + 8)))
        }

        return .records(firmware: .legacy, records: records, reindex: nil)

    }

}
