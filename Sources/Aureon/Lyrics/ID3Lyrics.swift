import Foundation

// Lyrics inside an ID3v2 tag: USLT (text) and SYLT (text with a time for each piece). `ID3v2.parse` hands both frames here.

enum ID3Lyrics {
    /// The text of a USLT frame: encoding, language (3 bytes), a description ending in its terminator, then the lyrics.
    static func unsynchronised(_ frame: Data) -> String? {
        guard frame.count > 5, let enc = frame.first else { return nil }
        guard let d = descriptionEnd(frame, from: 4, encoding: enc) else { return nil }
        let text = ID3v2.decodeText(frame.subdata(in: (frame.startIndex + d)..<frame.endIndex), encoding: enc)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}").union(.whitespacesAndNewlines))
        return text.isEmpty ? nil : text
    }

    /// A SYLT frame as LRC text. Times in milliseconds only: a frame counting MPEG frames cannot be placed without the stream's frame
    /// rate, so it is left out rather than shown out of step.
    static func synchronised(_ frame: Data) -> String? {
        guard frame.count > 7, let enc = frame.first else { return nil }
        let format = frame[frame.startIndex + 4], kind = frame[frame.startIndex + 5]
        guard format == 2, kind == 1 || kind == 0 else { return nil }                 // timestamps in milliseconds; content type lyrics (or other)
        guard var p = descriptionEnd(frame, from: 6, encoding: enc) else { return nil }
        let wide = enc == 1 || enc == 2
        var pieces: [(time: Double, text: String)] = []
        while p < frame.count {
            // text up to its terminator, then a 4-byte big-endian time
            var q = p
            if wide { while q + 1 < frame.count, !(frame[frame.startIndex + q] == 0 && frame[frame.startIndex + q + 1] == 0) { q += 2 } }
            else { while q < frame.count, frame[frame.startIndex + q] != 0 { q += 1 } }
            guard q < frame.count else { break }
            let text = ID3v2.decodeText(frame.subdata(in: (frame.startIndex + p)..<(frame.startIndex + q)), encoding: enc)
            q += wide ? 2 : 1
            guard q + 4 <= frame.count else { break }
            var ms = 0
            for k in 0..<4 { ms = ms << 8 | Int(frame[frame.startIndex + q + k]) }
            pieces.append((Double(ms) / 1000, text))
            p = q + 4
        }
        return lrc(from: pieces)
    }

    /// Pieces of text with times → LRC. A piece with a line break in it ends the line; with no breaks at all, each piece is a line.
    static func lrc(from pieces: [(time: Double, text: String)]) -> String? {
        guard !pieces.isEmpty else { return nil }
        let hasBreaks = pieces.contains { $0.text.contains("\n") || $0.text.contains("\r") }
        var lines: [(time: Double, words: [LyricWord])] = []
        if hasBreaks {
            var current: (time: Double, words: [LyricWord])?
            for piece in pieces {
                let parts = piece.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
                for (k, part) in parts.enumerated() {
                    if k > 0, let c = current { lines.append(c); current = nil }               // a break before this part
                    if part.isEmpty { continue }
                    if current == nil { current = (piece.time, []) }
                    current!.words.append(LyricWord(start: piece.time, text: part))
                }
            }
            if let c = current { lines.append(c) }
        } else {
            lines = pieces.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0.time, [LyricWord(start: $0.time, text: $0.text)]) }
        }
        let built = lines.enumerated().map { i, l in
            // words only when a line was assembled from several timed pieces
            LyricLine(id: i, time: l.time, text: l.words.map(\.text).joined().trimmingCharacters(in: .whitespaces), words: l.words.count > 1 ? l.words : [])
        }
        let lyrics = Lyrics(lines: built.filter { !$0.text.isEmpty }, synced: true, origin: .embedded, source: "file tags")
        return lyrics.lines.count >= 1 ? lyrics.lrc() : nil
    }

    /// Where the text after the content descriptor starts.
    private static func descriptionEnd(_ f: Data, from: Int, encoding: UInt8) -> Int? {
        var i = from
        if encoding == 1 || encoding == 2 {
            while i + 1 < f.count { if f[f.startIndex + i] == 0 && f[f.startIndex + i + 1] == 0 { return i + 2 }; i += 2 }
        } else {
            while i < f.count { if f[f.startIndex + i] == 0 { return i + 1 }; i += 1 }
        }
        return nil
    }
}
