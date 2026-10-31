import SwiftUI

// How the words move, in one place: the full stage (`LyricsStage`: Stage, Classic, Full-bleed, Carousel, Chillax, the panel) and the three-line reel at the
// foot of Poster and Turntable (`NPLyricTriplet`) both read their easing, their fall-off and their timing from here, so they move the same way. All of it is
// plain arithmetic: the views place rows with it and the tests hold it to its numbers.

enum LyricsMotion {
    /// How long a line takes to ease into its place.
    static let duration = 0.42
    /// After this long without wheel or trackpad input the words follow the song again.
    static let resumeAfter: TimeInterval = 3
    /// Where the line being sung rests, as a share of the height.
    static let focus: CGFloat = 0.38

    /// A gentle ease-out with a soft landing; with Reduce Motion, a short fade instead of any travel.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.25, 0.85, 0.3, 1, duration: duration)
    }

    /// Brightness of a line `relative` places from the one being sung (0 = being sung; negative = already sung; positive = still to come).
    static func opacity(relative: Int) -> Double {
        let d = Double(abs(relative))
        if relative == 0 { return 1 }
        return relative < 0 ? max(0.16, 0.5 - 0.09 * d) : max(0.24, 0.6 - 0.09 * d)
    }

    /// Blur radius by distance: sharp where it is sung, softer the further away.
    static func blur(relative: Int) -> Double { relative == 0 ? 0 : min(5, 0.9 + 0.9 * Double(abs(relative))) }

    /// Size by distance: the line being sung is full size, the others a little smaller (all the same with Reduce Motion).
    static func scale(relative: Int, reduceMotion: Bool) -> CGFloat { relative == 0 || reduceMotion ? 1 : 0.94 }

    /// Top of a row `relative` places from the active one, for rows of the same height: the active row at `focusY`.
    static func rowTop(relative: Int, rowHeight: CGFloat, focusY: CGFloat) -> CGFloat { focusY + CGFloat(relative) * rowHeight }

    /// The offset that puts row `index` at the focus when every row is `rowHeight` tall.
    static func scrollOffset(index: Int, rowHeight: CGFloat, focusY: CGFloat) -> CGFloat { CGFloat(index) * rowHeight - focusY }

    /// For lyrics without times: the paragraph to show by how far the song has played (0…1).
    static func plainLine(progress: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(count - 1, Int((max(0, min(1, progress)) * Double(count)).rounded(.down))))
    }
}

/// Whether the words follow the song or the listener has taken over with the wheel or trackpad: following again after `LyricsMotion.resumeAfter`
/// seconds without input. The clock is passed in, so it can be tested without waiting.
struct LyricsFollow: Equatable {
    private(set) var lastInput: TimeInterval?

    mutating func userScrolled(at now: TimeInterval) { lastInput = now }
    mutating func resume() { lastInput = nil }
    func isFollowing(at now: TimeInterval) -> Bool { guard let t = lastInput else { return true }; return now - t >= LyricsMotion.resumeAfter }
}
