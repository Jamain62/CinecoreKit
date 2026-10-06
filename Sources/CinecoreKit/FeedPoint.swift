import Foundation

/// Where a seek should start feeding. Audio past the last sample stays past
/// the end, so playback does not jump back to the first audio frame.
public enum FeedPoint {
    public static func video(_ samples: [SampleRec], from start: Double) -> Int {
        var index = 0
        for (i, sample) in samples.enumerated() where sample.key && sample.pts <= start + 0.0008 {
            index = i
        }
        return index
    }

    public static func audio(_ samples: [SampleRec], from start: Double) -> Int {
        for (i, sample) in samples.enumerated() where sample.pts + sample.duration >= start - 0.0008 {
            return i
        }
        return samples.count
    }
}

/// Cursor policy for one read. A thrown read leaves the cursor where it is.
public enum SamplePull {
    case enqueued(Int, Data)
    case retry(Int)
    case finished

    public static func take(cursor: Int, count: Int, read: () throws -> Data) -> SamplePull {
        if cursor >= count { return .finished }
        do {
            return .enqueued(cursor + 1, try read())
        } catch {
            return .retry(cursor)
        }
    }
}
