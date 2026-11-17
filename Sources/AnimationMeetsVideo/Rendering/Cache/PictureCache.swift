import AppKit
import Dispatch

/// Pictures kept to be shown again at once, up to `pixelLimit` pixels in
/// all, the least recently used going first past it; and all of them when
/// the system warns that memory is low.
///
/// In place of `NSCache`, which may throw any entry away at any moment of
/// its own choosing: on a busy Mac it dropped a timeline preview's
/// pictures within a second of making them, so the browser's filmstrips
/// drew them again, and a test of the cache failed at random. Here a
/// picture is kept until there are too many or memory runs short.
@MainActor
final class PictureCache {
    let pixelLimit: Int
    private var pictures: [NSString: Entry] = [:]
    /// Each use of a picture, oldest first, from `head` on; a use is stale
    /// once its picture has been used again since (its stamp no longer the
    /// entry's), and is skipped. So using a picture costs the same however
    /// many are kept, as a thumbnail strip asking for hundreds needs.
    private var uses: [(key: NSString, stamp: Int)] = []
    private var head = 0
    private var clock = 0
    private(set) var pixels = 0

    private struct Entry {
        var picture: NSImage
        var pixels: Int
        var stamp: Int
    }

    init(pixelLimit: Int) {
        self.pixelLimit = pixelLimit
        Self.live.add(self)
        Self.watchMemory()
    }

    var count: Int { pictures.count }

    /// The picture kept under `key`, which is then the most recently used.
    func object(forKey key: NSString) -> NSImage? {
        guard pictures[key] != nil else { return nil }
        touch(key)
        return pictures[key]?.picture
    }

    /// Keeps `picture` under `key`, letting the least recently used go
    /// while the pictures together are past the limit. One bigger than the
    /// limit by itself is still kept, alone.
    func setObject(_ picture: NSImage, forKey key: NSString) {
        if let old = pictures[key] { pixels -= old.pixels }
        let size = Self.pixels(of: picture)
        pictures[key] = Entry(picture: picture, pixels: size, stamp: 0)
        pixels += size
        touch(key)
        while pixels > pixelLimit, pictures.count > 1, head < uses.count {
            let use = uses[head]
            head += 1
            // The oldest use that is still its picture's last. The picture
            // just kept is used last of all, so it is reached only once it
            // is alone, which ends the loop.
            guard let entry = pictures[use.key], entry.stamp == use.stamp else { continue }
            pictures[use.key] = nil
            pixels -= entry.pixels
        }
        compact()
    }

    func removeAllObjects() {
        pictures = [:]
        uses = []
        head = 0
        pixels = 0
    }

    private func touch(_ key: NSString) {
        clock += 1
        pictures[key]?.stamp = clock
        uses.append((key, clock))
        compact()
    }

    /// Drops the uses already passed and those gone stale, once they
    /// outnumber the pictures kept several times over.
    private func compact() {
        guard uses.count - head > 64, uses.count - head > pictures.count * 4 else { return }
        uses = uses[head...].filter { pictures[$0.key]?.stamp == $0.stamp }
        head = 0
    }

    private static func pixels(of picture: NSImage) -> Int {
        if let rep = picture.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh
        }
        return max(1, Int(picture.size.width * picture.size.height))
    }

    // MARK: Memory

    /// Every cache alive, which a warning that memory is low empties.
    private static let live = NSHashTable<PictureCache>.weakObjects()
    private static var memoryWatch: DispatchSourceMemoryPressure?

    private static func watchMemory() {
        guard memoryWatch == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { emptyAll() }
        }
        source.resume()
        memoryWatch = source
    }

    /// What a warning that memory is low does: every cache (or those
    /// given) let go of its pictures, to be made again as they are shown.
    static func emptyAll(_ caches: [PictureCache]? = nil) {
        for cache in caches ?? live.allObjects { cache.removeAllObjects() }
    }

    /// Whether a warning that memory is low reaches `cache`.
    static func isWatched(_ cache: PictureCache) -> Bool {
        memoryWatch != nil && live.contains(cache)
    }
}
