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
    private var pictures: [NSString: NSImage] = [:]
    /// Keys from the least recently used to the most.
    private var order: [NSString] = []
    private(set) var pixels = 0

    init(pixelLimit: Int) {
        self.pixelLimit = pixelLimit
        Self.live.add(self)
        Self.watchMemory()
    }

    var count: Int { pictures.count }

    /// The picture kept under `key`, which is then the most recently used.
    func object(forKey key: NSString) -> NSImage? {
        guard let picture = pictures[key] else { return nil }
        touch(key)
        return picture
    }

    /// Keeps `picture` under `key`, letting the least recently used go
    /// while the pictures together are past the limit. One bigger than the
    /// limit by itself is still kept, alone.
    func setObject(_ picture: NSImage, forKey key: NSString) {
        if let old = pictures[key] { pixels -= Self.pixels(of: old) }
        pictures[key] = picture
        pixels += Self.pixels(of: picture)
        touch(key)
        while pixels > pixelLimit, order.count > 1 {
            let oldest = order.removeFirst()
            if let gone = pictures.removeValue(forKey: oldest) { pixels -= Self.pixels(of: gone) }
        }
    }

    func removeAllObjects() {
        pictures = [:]
        order = []
        pixels = 0
    }

    private func touch(_ key: NSString) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
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
