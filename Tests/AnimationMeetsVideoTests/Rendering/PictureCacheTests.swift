import AppKit
import Testing
@testable import AnimationMeetsVideo

/// Pictures are kept until there are too many or memory runs short, never
/// at random (`PictureCache`).
@MainActor
@Suite struct PictureCacheTests {
    /// A picture `side` pixels square.
    private func picture(_ side: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    @Test func theLeastRecentlyUsedGoesFirstPastTheLimit() {
        // Room for three pictures of 10 × 10.
        let cache = PictureCache(pixelLimit: 300)
        cache.setObject(picture(10), forKey: "a")
        cache.setObject(picture(10), forKey: "b")
        cache.setObject(picture(10), forKey: "c")
        #expect(cache.count == 3 && cache.pixels == 300)
        // Asking for "a" makes "b" the oldest, which a fourth pushes out.
        #expect(cache.object(forKey: "a") != nil)
        cache.setObject(picture(10), forKey: "d")
        #expect(cache.object(forKey: "b") == nil)
        #expect(cache.object(forKey: "a") != nil && cache.object(forKey: "c") != nil && cache.object(forKey: "d") != nil)
        #expect(cache.pixels == 300)
    }

    @Test func aPictureReplacedCountsOnceAndOneTooBigIsKeptAlone() {
        let cache = PictureCache(pixelLimit: 300)
        cache.setObject(picture(10), forKey: "a")
        cache.setObject(picture(10), forKey: "a")
        #expect(cache.count == 1 && cache.pixels == 100)
        cache.setObject(picture(20), forKey: "big")
        #expect(cache.count == 1 && cache.object(forKey: "big") != nil)
    }

    @Test func lowMemoryEmptiesEveryCache() {
        let one = PictureCache(pixelLimit: 1000), two = PictureCache(pixelLimit: 1000)
        // Both hear the system's warning.
        #expect(PictureCache.isWatched(one) && PictureCache.isWatched(two))
        one.setObject(picture(10), forKey: "a")
        two.setObject(picture(10), forKey: "b")
        // Emptied by name: emptying every cache alive would empty those of
        // tests running beside this one.
        PictureCache.emptyAll([one, two])
        #expect(one.count == 0 && two.count == 0 && one.pixels == 0)
    }
}
