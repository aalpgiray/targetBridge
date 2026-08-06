import Foundation

/// Turns the WindowServer's dirty rectangles into tile-aligned regions worth
/// encoding — or decides the frame is too damaged to be worth it.
///
/// This is the whole character of damage-aware DPCM, and the thresholds below
/// are the judgement. Too eager and per-rect overhead dominates on a busy
/// screen; too lazy and the win never arrives. They are constants here rather
/// than scattered through the send path so they can be argued about, measured
/// and changed in one place.
///
/// Nothing here touches the codec. A rect is encoded by handing the encoder
/// `(base + y*stride + x*4, stride, w, h)` — verified lossless against the
/// reference encoder — so this file only decides WHICH rectangles.
enum TBDamageRects {
    /// Tiles are 8x8 and a blob's own geometry is in tiles, so every edge must
    /// land on the grid. Snapping outward never loses a changed pixel; it only
    /// sends up to 7 rows or columns of unchanged ones.
    static let tile = 8

    /// Past this fraction of the frame, a whole frame is cheaper than the sum of
    /// its parts: each rect repeats a 32-byte packet header, a TBD2 header, a
    /// group table and its alignment padding, and each is a separate encode
    /// submission and a separate socket write.
    ///
    /// 0.5 is a starting point, not a measured optimum. The honest way to tune
    /// it is to log the damaged-area distribution during real use and find where
    /// rect overhead crosses the saving — until that exists, this is a guess and
    /// should be described as one.
    static let wholeFrameAbove = 0.5

    /// More rects than this and they are merged into their bounding box. Each
    /// costs a submission, a completion and a write, and the in-flight budget is
    /// counted in packets — which is exactly what stopped N=8 from working.
    static let maxRects = 8

    struct Rect: Equatable {
        var x: Int, y: Int, w: Int, h: Int
        var area: Int { w * h }

        /// Grown outward to the tile grid and clamped to the frame. Growing
        /// rather than shrinking matters: a shrunk rect would leave changed
        /// pixels unsent, and on a lossless link that stale strip never gets
        /// corrected until the next keyframe.
        func snapped(toTile t: Int, frameW: Int, frameH: Int) -> Rect {
            let x0 = max(0, (x / t) * t)
            let y0 = max(0, (y / t) * t)
            let x1 = min(frameW, ((x + w + t - 1) / t) * t)
            let y1 = min(frameH, ((y + h + t - 1) / t) * t)
            return Rect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
        }

        func union(_ o: Rect) -> Rect {
            let x0 = min(x, o.x), y0 = min(y, o.y)
            let x1 = max(x + w, o.x + o.w), y1 = max(y + h, o.y + o.h)
            return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        }

        func intersects(_ o: Rect) -> Bool {
            x < o.x + o.w && o.x < x + w && y < o.y + o.h && o.y < y + h
        }
    }

    enum Plan: Equatable {
        /// Send these regions; they cover everything that changed.
        case rects([Rect])
        /// Too much changed, or too little is known — send the whole frame.
        case wholeFrame
    }

    /// Decide what to send for one frame.
    ///
    /// `dirty` are the WindowServer's rects in pixels. An empty list means
    /// nothing changed, which is NOT the same as "send nothing": the caller
    /// still owns the decision to skip, because a frame with no damage may still
    /// need to go out as a keyframe.
    static func plan(dirty: [Rect], frameW: Int, frameH: Int) -> Plan {
        guard frameW > 0, frameH > 0, !dirty.isEmpty else { return .wholeFrame }

        var rects = dirty
            .map { $0.snapped(toTile: tile, frameW: frameW, frameH: frameH) }
            .filter { $0.w > 0 && $0.h > 0 }
        guard !rects.isEmpty else { return .wholeFrame }

        // Merge anything overlapping. Two rects that overlap would encode the
        // shared pixels twice and, worse, the second write would land on top of
        // the first — harmless when both are from the same frame, but wasteful
        // and hard to reason about.
        var merged = true
        while merged, rects.count > 1 {
            merged = false
            outer: for i in 0..<rects.count {
                for j in (i + 1)..<rects.count where rects[i].intersects(rects[j]) {
                    let u = rects[i].union(rects[j])
                    rects.remove(at: j)
                    rects[i] = u
                    merged = true
                    break outer
                }
            }
        }

        // Too many: collapse to the bounding box rather than pay per-rect costs.
        // Deliberately blunt — a smarter clustering could keep more of the
        // saving, and is only worth writing once the simple version is measured.
        if rects.count > maxRects {
            let box = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            rects = [box]
        }

        // There is deliberately NO minimum-size rule.
        //
        // The first version dropped rects below a pixel threshold, which lost
        // real damage — a stale patch no counter can see. The second absorbed
        // them into the nearest survivor, which was correct but turned a
        // 640x480 window plus a 200x24 label into a bounding box covering 15% of
        // the frame instead of 2%.
        //
        // Both were solving a problem that does not exist: a small rect costs
        // one small packet, while growing a bounding box costs megapixels, and
        // `maxRects` already bounds how many packets a frame can produce. Doing
        // nothing is smaller, faster and safer than either attempt.

        let damaged = rects.reduce(0) { $0 + $1.area }
        if Double(damaged) >= Double(frameW * frameH) * wholeFrameAbove {
            return .wholeFrame
        }
        return .rects(rects)
    }
}
