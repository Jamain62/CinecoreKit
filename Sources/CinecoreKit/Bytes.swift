import Foundation

struct Box {
    var type: String
    var start: Int
    var end: Int
}

enum Bytes {
    static func u8(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o < d.count else { return 0 }
        return Int(d[o])
    }

    static func u16(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 1 < d.count else { return 0 }
        return (Int(d[o]) << 8) | Int(d[o + 1])
    }

    static func u32(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 3 < d.count else { return 0 }
        return (Int(d[o]) << 24) | (Int(d[o + 1]) << 16) | (Int(d[o + 2]) << 8) | Int(d[o + 3])
    }

    static func i32(_ d: Data, _ o: Int) -> Int {
        let v = u32(d, o)
        return v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
    }

    static func u64(_ d: Data, _ o: Int) -> Int {
        let hi = u32(d, o)
        let lo = u32(d, o + 4)
        return hi * 4_294_967_296 + lo
    }

    static func le32(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 3 < d.count else { return 0 }
        return Int(d[o]) | (Int(d[o + 1]) << 8) | (Int(d[o + 2]) << 16) | (Int(d[o + 3]) << 24)
    }

    static func fourcc(_ d: Data, _ o: Int) -> String {
        guard o >= 0, o + 3 < d.count else { return "" }
        return String(bytes: [d[o], d[o + 1], d[o + 2], d[o + 3]], encoding: .ascii) ?? ""
    }

    static func ascii(_ d: Data, _ o: Int, _ n: Int) -> String {
        var s = ""
        let end = min(d.count, o + n)
        var i = max(0, o)
        while i < end {
            let c = d[i]
            if c == 0 { break }
            if c >= 32 && c < 127, let scalar = UnicodeScalar(UInt32(c)) {
                s.append(Character(scalar))
            }
            i += 1
        }
        return s
    }

    static func slice(_ d: Data, _ start: Int, _ end: Int) -> Data {
        let lo = max(0, min(start, d.count))
        let hi = max(lo, min(end, d.count))
        return d.subdata(in: lo ..< hi)
    }

    static func concat(_ parts: [Data]) -> Data {
        var out = Data()
        for part in parts { out.append(part) }
        return out
    }

    static func boxes(_ data: Data, _ start: Int, _ end: Int) -> [Box] {
        var out: [Box] = []
        var o = start
        let limit = min(end, data.count)
        while o + 8 <= limit {
            let size32 = u32(data, o)
            let type = fourcc(data, o + 4)
            var header = 8
            var total = size32
            if size32 == 1 {
                if o + 16 > limit { break }
                total = u64(data, o + 8)
                header = 16
            } else if size32 == 0 {
                total = limit - o
            }
            if total < header { break }
            let boxEnd = min(limit, o + total)
            out.append(Box(type: type, start: o + header, end: boxEnd))
            if o + total <= o || o + total > limit { break }
            o += total
        }
        return out
    }
}

struct BitReader {
    let data: Data
    let offset: Int
    let limit: Int
    private var bit = 0

    init(_ data: Data, _ offset: Int = 0, _ limit: Int? = nil) {
        self.data = data
        self.offset = offset
        self.limit = limit ?? data.count
    }

    var remaining: Int { max(0, (limit - offset) * 8 - bit) }

    mutating func read(_ n: Int) -> Int {
        var v = 0
        for _ in 0 ..< n {
            let p = bit
            bit += 1
            let index = offset + (p >> 3)
            let byte = index >= 0 && index < limit && index < data.count ? Int(data[index]) : 0
            v = (v << 1) | ((byte >> (7 - (p & 7))) & 1)
        }
        return v
    }

    mutating func ue() -> Int {
        var zeros = 0
        while remaining > 0 && read(1) == 0 && zeros < 32 { zeros += 1 }
        if zeros == 0 { return 0 }
        return ((1 << zeros) | read(zeros)) - 1
    }

    mutating func se() -> Int {
        let n = ue()
        return n % 2 == 1 ? (n + 1) >> 1 : -(n >> 1)
    }
}

func ebspToRbsp(_ data: Data) -> Data {
    var out = Data()
    out.reserveCapacity(data.count)
    var i = 0
    while i < data.count {
        if i + 2 < data.count && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 3 {
            out.append(0)
            out.append(0)
            i += 3
            continue
        }
        out.append(data[i])
        i += 1
    }
    return out
}
