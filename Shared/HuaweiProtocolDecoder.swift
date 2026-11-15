import Foundation

/// Direction of a captured BLE GATT packet.
public enum PacketDirection: String, Codable, Sendable {
    case rx = "RX"
    case tx = "TX"
}

/// Decoded Type-Length-Value item inside a Huawei Link Protocol (0x5A) frame.
public struct HuaweiTLV: Identifiable, Equatable, Sendable {
    public let id: String
    public let tag: UInt8
    public let value: Data

    public init(index: Int, tag: UInt8, value: Data) {
        self.id = "\(index)-\(tag)"
        self.tag = tag
        self.value = value
    }

    public var tagHex: String {
        String(format: "0x%02X", tag)
    }

    public var valueHex: String {
        value.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    public var integerValue: UInt64? {
        guard !value.isEmpty, value.count <= 8 else { return nil }
        return value.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// Parsed Huawei Link Protocol frame starting with magic byte 0x5A.
public struct HuaweiFrame: Equatable, Sendable {
    public let controlByte: UInt8
    public let serviceID: UInt8
    public let commandID: UInt8
    public let tlvs: [HuaweiTLV]
    public let crcValid: Bool
    public let rawHex: String

    public var summary: String {
        let crcLabel = crcValid ? "CRC OK" : "CRC ERR"
        let tlvDesc = tlvs.map { tlv in
            if let num = tlv.integerValue {
                return "\(tlv.tagHex)=\(num) [\(tlv.valueHex)]"
            }
            return "\(tlv.tagHex)=[\(tlv.valueHex)]"
        }.joined(separator: ", ")
        let base = String(format: "0x5A Svc:0x%02X Cmd:0x%02X (%@)", serviceID, commandID, crcLabel)
        return tlvDesc.isEmpty ? base : "\(base) • \(tlvDesc)"
    }
}

/// Captured BLE packet entry displayed in the Protocol Sniffer log.
public struct BLEPacketLogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let direction: PacketDirection
    public let characteristicUUID: String
    public let rawHex: String
    public let decodedSummary: String
    public let parsedFrame: HuaweiFrame?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        direction: PacketDirection,
        characteristicUUID: String,
        rawHex: String,
        decodedSummary: String,
        parsedFrame: HuaweiFrame? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.characteristicUUID = characteristicUUID
        self.rawHex = rawHex
        self.decodedSummary = decodedSummary
        self.parsedFrame = parsedFrame
    }
}

/// CRC-16/XMODEM (CCITT, poly 0x1021, init 0x0000) used in Huawei 0x5A Link Protocol frames.
public enum HuaweiCRC16 {
    public static func xmodem(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0x0000
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }
}

/// Encodes and decodes Huawei 0x5A Link Protocol packets and raw hex strings.
public enum HuaweiProtocolDecoder {
    public static let magicByte: UInt8 = 0x5A

    /// Builds a framed 0x5A packet: [0x5A] [LenHi LenLo] [Ctrl] [ServiceID] [CommandID] [TLVs...] [CRC16_Hi CRC16_Lo].
    public static func buildFrame(
        serviceID: UInt8,
        commandID: UInt8,
        controlByte: UInt8 = 0x00,
        tlvs: [(tag: UInt8, value: Data)] = []
    ) -> Data {
        var content = Data([serviceID, commandID])
        for item in tlvs {
            content.append(item.tag)
            content.append(contentsOf: encodeVarLength(item.value.count))
            content.append(item.value)
        }

        // Length field encodes CONTENT + 1 (covering the control byte or content span per Huawei framing).
        let lengthValue = UInt16(content.count + 1)
        var frame = Data([
            magicByte,
            UInt8((lengthValue >> 8) & 0xFF),
            UInt8(lengthValue & 0xFF),
            controlByte
        ])
        frame.append(content)

        let crc = HuaweiCRC16.xmodem(frame)
        frame.append(UInt8((crc >> 8) & 0xFF))
        frame.append(UInt8(crc & 0xFF))
        return frame
    }

    /// Parses a received 0x5A frame if valid header and minimum length are present.
    public static func parseFrame(_ data: Data) -> HuaweiFrame? {
        guard data.count >= 8, data[data.startIndex] == magicByte else { return nil }

        let bytes = Array(data)
        let ctrl = bytes[3]
        let serviceID = bytes[4]
        let commandID = bytes[5]

        let payloadWithoutCRC = Data(bytes[0..<(bytes.count - 2)])
        let expectedCRC = HuaweiCRC16.xmodem(payloadWithoutCRC)
        let receivedCRC = (UInt16(bytes[bytes.count - 2]) << 8) | UInt16(bytes[bytes.count - 1])
        let crcValid = (expectedCRC == receivedCRC)

        let tlvSlice = Array(bytes[6..<(bytes.count - 2)])
        let tlvs = parseTLVs(tlvSlice)

        return HuaweiFrame(
            controlByte: ctrl,
            serviceID: serviceID,
            commandID: commandID,
            tlvs: tlvs,
            crcValid: crcValid,
            rawHex: bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        )
    }

    /// Converts a space- or dash-separated hex string (e.g. "5A 00 03 00 01 08 A1 B2") into Data.
    public static func dataFromHexString(_ hex: String) -> Data? {
        let cleaned = hex
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .filter { $0.isHexDigit }
        guard cleaned.count >= 2, cleaned.count.isMultiple(of: 2) else { return nil }

        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func encodeVarLength(_ count: Int) -> [UInt8] {
        if count < 0x80 {
            return [UInt8(count)]
        }
        return [UInt8((count >> 7) | 0x80), UInt8(count & 0x7F)]
    }

    private static func parseTLVs(_ bytes: [UInt8]) -> [HuaweiTLV] {
        var result: [HuaweiTLV] = []
        var cursor = 0
        var idx = 0

        while cursor < bytes.count {
            let tag = bytes[cursor]
            cursor += 1
            guard cursor < bytes.count else { break }

            var length = Int(bytes[cursor] & 0x7F)
            let hasMore = (bytes[cursor] & 0x80) != 0
            cursor += 1
            if hasMore, cursor < bytes.count {
                length = (length << 7) | Int(bytes[cursor] & 0x7F)
                cursor += 1
            }

            guard length >= 0, cursor + length <= bytes.count else { break }
            let val = Data(bytes[cursor..<(cursor + length)])
            result.append(HuaweiTLV(index: idx, tag: tag, value: val))
            cursor += length
            idx += 1
        }
        return result
    }
}
