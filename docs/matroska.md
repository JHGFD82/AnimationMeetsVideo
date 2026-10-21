# Matroska (MKV) media

Status: **implemented**: MKV files (and other Matroska files, such as
`.mka` sound and `.webm`, when their codecs are usable) import like any
other media. FLAC files need nothing: AVFoundation reads them already.

AVFoundation can't open Matroska files, and everything in the app that
reads media (the browser, the viewer, waveforms, analysis, compositions,
export) goes through `AVURLAsset`. Copying an MKV's frames into a
QuickTime movie would make it readable, but would double the space the
footage takes, which the shared principles in [README.md](README.md) rule
out. Instead the app makes a **reference movie**: a QuickTime movie holding
only the index of the file's frames, whose samples point at the frames'
bytes where they already sit in the MKV.

## How it works

1. `MatroskaIndex.read` walks the file's EBML elements and, without
   decoding anything, notes each track's codec and settings and, for each
   frame, its byte offset, size, time and whether it is a keyframe. It
   reads SimpleBlocks and BlockGroups, Xiph, EBML and fixed lacing, and
   clusters of unknown size (live recordings). Frame headers sit every few
   tens of kilobytes, so the file is read straight through in 16 MB pieces
   (`MatroskaBytes`) rather than memory-mapped: a map faults its pages in
   one at a time, and took 13.6 s for a 16.6 GB file the read takes 3.4 s
   for.
2. `MatroskaReferenceMovie.write` turns each frame into a sample buffer
   with no data, only the MKV's URL and the frame's offset
   (`kCMSampleBufferAttachmentKey_SampleReferenceURL` and
   `…SampleReferenceByteOffset`), and appends them to an `AVMutableMovie`
   track, which adds references instead of copying. `writeHeader` then
   writes a movie of only the header.

Matroska stores H.264 and HEVC frames in the same length-prefixed form as
QuickTime, and keeps the decoder configuration (`avcC`, `hvcC`) as the
track's private data, so the bytes need no change. The movie refers to the
MKV by absolute URL; a moved file needs a new movie, which is cheap.

Tracks used: the first H.264 or HEVC video track and the first AAC, FLAC
or PCM sound track. Tracks with content encodings (compression,
encryption, header stripping) can't be referenced and are skipped; a file
with nothing usable is refused with `MatroskaError.unsupported`.

### Timing

- **Decode times.** Matroska stores only when frames are shown. Frames are
  stored in decode order, so the n-th decode time is the n-th earliest show
  time, moved back by the most any frame was reordered.
- **Frame rates.** Matroska keeps times in milliseconds, which can't say
  1/29.97 s. When a track's default frame duration is a common rate's
  (within 2 ns, since 30 and 29.97 are only 0.1% apart), times are snapped
  to that rate's frames, counted from the first frame, in a timescale of the
  rate times 1000 so a track that starts between frames keeps its start.
  Other tracks keep the file's millisecond times (variable frame rate).
- **Sound** is timed by counting samples from the first block (1024 per
  AAC packet, each FLAC frame's header for FLAC), not by the blocks'
  rounded times.
- **AAC priming.** Core Media drops 2112 samples from the start of AAC
  media whatever the file says, but ffmpeg's encoder primes by 1024 (and
  says so in CodecDelay), and mkvmerge keeps the priming as sound and
  starts the video later instead. The first audible sample belongs at the
  first block's time after CodecDelay is dropped, so the track is moved by
  what Core Media skipped minus the file's own priming. Without this, sound
  from ffmpeg was 22.6 ms early.

## What the spike showed

Measured on files from ffmpeg (H.264 with B-frames and FLAC; 10-bit HEVC
with B-frames and AAC) and mkvmerge, and in the tests on fixtures made
from Apple's own encoders:

- The reference movie works for `AVPlayer`, exact-frame
  `AVAssetImageGenerator`, `AVAssetReader` and `AVMutableComposition`
  export: everything the app does with media.
- Decoded frames are identical to the source's, at the right times.
- Sound and picture line up to within the file's millisecond times, for
  ffmpeg's and mkvmerge's ways of handling AAC priming and for FLAC.
- An hour of 29.97 fps video with FLAC sound (108,000 frames and 37,800 packets)
  scans in under half a second and writes a 2 MB movie in about as long;
  exact-frame seeks anywhere take under 0.1 s.

## In the project

- **Import.** `MediaImporter.importClip` tells Matroska files by their
  first bytes, not their name, and reads them through their reference
  movie, made first. Import…, dragging from the Finder, replacing a file and
  opening a project all go through it. A file with nothing usable (VP9,
  Vorbis) is refused with the reason.
- **The clip keeps the MKV.** Its URL, `FileStamp`, reference data,
  replacement and copying into `Media/` are all of the MKV; only opening it
  goes elsewhere. `MediaFile` gives everything that reads footage (the
  track cache compositions are built from, the players (the browser's
  skimming among them), waveforms,
  spectra, beats, scene scores, reference capture and thumbnails) the
  reference movie in its place.
- **Where movies live.** In the package's `Cache/References/`, named by a
  hash of the MKV's path, size and modification date, so a moved or changed
  file gets a new one. A file that changes while the project is open gets
  its new movie the next time it is opened, since the old one points at
  bytes that have moved. A project not yet saved keeps them in a temporary
  folder; saving makes them in the package, as it does for files copied
  into `Media/` on save. Opening a project remakes missing movies and
  deletes those no asset uses.

## Not yet done

- **More codecs.** Opus (`dOps`, with its pre-skip as CodecDelay) and AC-3
  are decodable by Core Audio; Vorbis and VP9/AV1 aren't, and are refused.
- **Color.** Carrying the track's Colour element (primaries, transfer,
  matrix, range, HDR metadata) into the format description; until then an
  MKV's color comes from its H.264 or HEVC stream's own signaling.
- **More than one track of a kind.** Only the first usable video track and
  the first usable sound track are used.
