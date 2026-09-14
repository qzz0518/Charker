import A2345Protocol
import Foundation

/// Errors intentionally carry no source string, payload bytes or parser detail.
/// Cloud messages can contain account and device identifiers and must never be
/// copied into logs through an error description.
public enum A2345CloudPayloadError: Error, Sendable, Equatable, Hashable {
    case emptyPayload
    case inputTooLarge
    case candidateTooLarge
    case malformedJSON
    case maximumDepthExceeded
    case tooManyJSONNodes
    case invalidBase64
    case nonFF09Payload
    case invalidFrame
    case frameNotFound
    case ambiguousFrames
}

/// Extracts one validated A2345 FF09 frame from an MQTT PUBLISH payload.
///
/// Supported forms are raw FF09 bytes, JSON whose `payload` string contains
/// another JSON document, and base64 FF09 bytes under `data` or `payload` keys
/// at any permitted nesting level. Distinct multiple frames are rejected rather
/// than resolved by dictionary traversal order.
public enum A2345CloudPayloadDecoder {
    public static let maximumInputBytes = 256 * 1_024
    public static let maximumJSONDepth = 8
    public static let maximumJSONNodes = 512
    public static let maximumBase64Characters =
        ((A2345PacketCodec.maximumFrameLength + 2) / 3) * 4

    public static func decode(_ payload: Data) throws -> [UInt8] {
        guard !payload.isEmpty else { throw A2345CloudPayloadError.emptyPayload }
        guard payload.count <= maximumInputBytes else {
            throw A2345CloudPayloadError.inputTooLarge
        }

        if payload.starts(with: A2345PacketCodec.header) {
            return try validatedFrame(payload)
        }

        guard looksLikeJSON(payload) else {
            throw A2345CloudPayloadError.nonFF09Payload
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
        } catch {
            throw A2345CloudPayloadError.malformedJSON
        }

        var traversal = Traversal()
        try traversal.walk(root, depth: 0, inspectString: false)

        // MQTT envelopes may contain ordinary sibling `data` fields next to the
        // actual device payload. A malformed unrelated candidate must not mask
        // one unambiguous, checksum-valid FF09 frame. Errors only describe why
        // no usable frame was found; two distinct valid frames remain ambiguous.
        guard traversal.frames.count <= 1 else {
            throw A2345CloudPayloadError.ambiguousFrames
        }
        if let frame = traversal.frames.first {
            return [UInt8](frame)
        }
        if let error = traversal.preferredError {
            throw error
        }
        throw A2345CloudPayloadError.frameNotFound
    }

    private static func validatedFrame(_ data: Data) throws -> [UInt8] {
        guard data.count <= A2345PacketCodec.maximumFrameLength else {
            throw A2345CloudPayloadError.candidateTooLarge
        }
        guard data.starts(with: A2345PacketCodec.header) else {
            throw A2345CloudPayloadError.nonFF09Payload
        }
        do {
            _ = try A2345PacketCodec.decode([UInt8](data))
        } catch {
            throw A2345CloudPayloadError.invalidFrame
        }
        return [UInt8](data)
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        for byte in data {
            switch byte {
            case 0x09, 0x0A, 0x0D, 0x20:
                continue
            case 0x5B, 0x7B: // [ or {
                return true
            default:
                return false
            }
        }
        return false
    }

    private struct Traversal {
        var frames: Set<Data> = []
        var errors: Set<A2345CloudPayloadError> = []
        var visitedNodes = 0

        var preferredError: A2345CloudPayloadError? {
            let priority: [A2345CloudPayloadError] = [
                .candidateTooLarge,
                .malformedJSON,
                .invalidBase64,
                .nonFF09Payload,
                .invalidFrame,
            ]
            return priority.first(where: errors.contains)
        }

        mutating func walk(_ value: Any, depth: Int, inspectString: Bool) throws {
            guard depth <= A2345CloudPayloadDecoder.maximumJSONDepth else {
                throw A2345CloudPayloadError.maximumDepthExceeded
            }
            visitedNodes += 1
            guard visitedNodes <= A2345CloudPayloadDecoder.maximumJSONNodes else {
                throw A2345CloudPayloadError.tooManyJSONNodes
            }

            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    let isCandidate = key.caseInsensitiveCompare("data") == .orderedSame
                        || key.caseInsensitiveCompare("payload") == .orderedSame
                    if isCandidate, let string = child as? String {
                        try inspectCandidate(string, depth: depth + 1)
                    } else {
                        try walk(child, depth: depth + 1, inspectString: false)
                    }
                }
                return
            }

            if let array = value as? [Any] {
                for child in array {
                    try walk(child, depth: depth + 1, inspectString: false)
                }
                return
            }

            if inspectString, let string = value as? String {
                try inspectCandidate(string, depth: depth + 1)
            }
        }

        private mutating func inspectCandidate(_ string: String, depth: Int) throws {
            guard depth <= A2345CloudPayloadDecoder.maximumJSONDepth else {
                throw A2345CloudPayloadError.maximumDepthExceeded
            }
            guard string.utf8.count <= A2345CloudPayloadDecoder.maximumInputBytes else {
                errors.insert(.candidateTooLarge)
                return
            }

            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.first == "{" || trimmed.first == "[" {
                let nestedData = Data(trimmed.utf8)
                let nested: Any
                do {
                    nested = try JSONSerialization.jsonObject(
                        with: nestedData,
                        options: [.fragmentsAllowed]
                    )
                } catch {
                    errors.insert(.malformedJSON)
                    return
                }
                try walk(nested, depth: depth, inspectString: true)
                return
            }

            guard string.utf8.count <= A2345CloudPayloadDecoder.maximumBase64Characters else {
                errors.insert(.candidateTooLarge)
                return
            }
            guard let decoded = Data(base64Encoded: string) else {
                errors.insert(.invalidBase64)
                return
            }
            guard decoded.starts(with: A2345PacketCodec.header) else {
                errors.insert(.nonFF09Payload)
                return
            }
            guard decoded.count <= A2345PacketCodec.maximumFrameLength else {
                errors.insert(.candidateTooLarge)
                return
            }
            do {
                _ = try A2345PacketCodec.decode([UInt8](decoded))
                frames.insert(decoded)
            } catch {
                errors.insert(.invalidFrame)
            }
        }
    }
}
