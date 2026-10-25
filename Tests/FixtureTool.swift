// Local fixtures and CLI assertions; no network or physical-device access.
import Foundation

struct Failure: Error { let message: String }
func check(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
func ffmpeg(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ffmpeg", "-v", "error"] + arguments
    try process.run(); process.waitUntilExit()
    try check(process.terminationStatus == 0, "ffmpeg failed")
}
func bytes(_ text: String) -> Data { Data(text.utf8) }
func integer(_ value: Int, syncsafe: Bool = false) -> Data {
    let shift = syncsafe ? 7 : 8, mask = syncsafe ? 127 : 255
    return Data((0..<4).reversed().map { UInt8((value >> ($0 * shift)) & mask) })
}
func number(_ data: Data, syncsafe: Bool = false) -> Int {
    data.reduce(0) { ($0 << (syncsafe ? 7 : 8)) | Int($1) }
}
func frame(_ name: String, _ value: Data) -> Data {
    bytes(name) + integer(value.count, syncsafe: true) + Data([0, 0]) + value
}
func tagMP3(_ path: URL) throws {
    let data = try Data(contentsOf: path)
    try check(data.prefix(5) == Data([73, 68, 51, 4, 0]), "Expected ffmpeg ID3v2.4 fixture")
    let end = 10 + number(data[6..<10], syncsafe: true)
    try check(end <= data.count && data[5] == 0, "Unsupported ID3 fixture header")
    var frames = Data(), offset = 10
    let replaced = ["COMM", "USLT", "TSOT", "TSOP", "TSOA"]
    while offset + 10 <= end && data[offset] != 0 {
        let name = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = number(data[offset + 4..<offset + 8], syncsafe: true)
        try check(offset + 10 + size <= end, "Invalid fixture frame")
        if !replaced.contains(name) { frames.append(data[offset..<offset + 10 + size]) }
        offset += 10 + size
    }
    frames += frame("COMM", Data([3]) + bytes("eng") + Data([0]) + bytes("Test Comment"))
    frames += frame("USLT", Data([3]) + bytes("eng") + Data([0]) + bytes("Test lyrics"))
    for (name, text) in [("TSOT", "Title Sort"), ("TSOP", "Artist Sort"), ("TSOA", "Album Sort")] {
        frames += frame(name, Data([3]) + bytes(text))
    }
    try (Data([73, 68, 51, 4, 0, 0]) + integer(frames.count, syncsafe: true) + frames + data[end...]).write(to: path)
}
func atom(_ name: String, _ value: Data) -> Data { integer(value.count + 8) + bytes(name) + value }
func tagMP4(_ path: URL) throws {
    let replacements = [("sonm", "Title Sort"), ("soar", "Artist Sort"), ("soal", "Album Sort"),
                        ("soaa", "Album Artist Sort"), ("soco", "Composer Sort")]
    let names = replacements.map(\.0) + ["tmpo"]
    var appended = Data()
    for (name, text) in replacements {
        appended += atom(name, atom("data", integer(1) + integer(0) + bytes(text)))
    }
    appended += atom("tmpo", atom("data", integer(21) + integer(0) + Data([0, 123])))
    var patched = false
    func rewrite(_ input: Data, _ path: [String]) throws -> Data {
        let data = Data(input)
        var output = Data(), offset = 0
        while offset < data.count {
            try check(offset + 8 <= data.count, "Truncated MP4 fixture")
            let size = number(data[offset..<offset + 4])
            try check(size >= 8 && offset + size <= data.count, "Unsupported MP4 fixture box")
            let name = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            let payload = Data(data[offset + 8..<offset + size])
            if path.isEmpty {
                if !names.contains(name) { output.append(data[offset..<offset + size]) }
            } else if name == path[0] {
                // ffmpeg writes moov after mdat, so resizing metadata cannot move audio offsets.
                if name == "moov" { try check(offset + size == data.count, "Expected trailing moov") }
                let header = name == "meta" ? 4 : 0
                try check(payload.count >= header, "Truncated metadata header")
                output += atom(name, payload.prefix(header) + (try rewrite(Data(payload.dropFirst(header)), Array(path.dropFirst()))))
            } else { output.append(data[offset..<offset + size]) }
            offset += size
        }
        if path.isEmpty { output += appended; patched = true }
        return output
    }
    let result = try rewrite(Data(contentsOf: path), ["moov", "udta", "meta", "ilst"])
    try check(patched, "Missing MP4 metadata container")
    try result.write(to: path)
}
func generate(_ root: URL) throws {
    for (suffix, disc, codec) in [("mp3", 1, "libmp3lame"), ("m4a", 2, "aac"), ("flac", 3, "flac"), ("m4a", 4, "aac")] {
        let path = root.appendingPathComponent("Folder Artist/Folder Album \(disc)/09 - Wrong Title.\(suffix)")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metadata = ["title": "Tagged Title 日本語 Ü", "artist": "Tagged Artist", "album": "Tagged Album",
                        "album_artist": "Various Artists", "genre": "Rock", "date": "2024-02-01", "track": "3/12",
                        "disc": "\(disc)/3", "composer": "Test Composer", "compilation": "1", "sort_name": "Title Sort",
                        "sort_artist": "Artist Sort", "sort_album": "Album Sort", "sort_album_artist": "Album Artist Sort",
                        "sort_composer": "Composer Sort", "lyrics": "Test lyrics", "grouping": "Test Group",
                        "comment": "Test Comment", "bpm": "123"]
        var arguments = ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", codec]
        for key in metadata.keys.sorted() { arguments += ["-metadata", "\(key)=\(metadata[key]!)"] }
        try ffmpeg(arguments + [path.path])
        if suffix == "mp3" { try tagMP3(path) }
        if suffix == "m4a" { try tagMP4(path) }
    }
    let fallback = root.appendingPathComponent("Folder Artist/Fallback Album/07 - Fallback.mp3")
    try FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=220:duration=1", "-c:a", "libmp3lame", fallback.path])
    try ffmpeg(["-f", "lavfi", "-i", "color=red:s=16x16", "-frames:v", "1", root.appendingPathComponent("test-cover.png").path])
    try ffmpeg(["-f", "lavfi", "-i", "color=blue:s=32x32", "-frames:v", "1", root.appendingPathComponent("Folder Artist/Folder Album 2/cover.jpg").path])
}
func json(_ path: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else {
        throw Failure(message: "Expected JSON object")
    }
    return object
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "generate" where args.count == 2: try generate(URL(fileURLWithPath: args[1]))
    case "verify-sync" where args.count == 4:
        let result = try json(args[1]), plan = try json(args[2])
        try check(result["added"] as? Int == 5 && result["tracks"] as? Int == 5, "Expected five tracks")
        for key in ["add", "remove", "metadataUpdates"] {
            try check((plan[key] as? [Any])?.isEmpty == true, "Sync is not idempotent: \(key)")
        }
        let artwork = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: args[3]).appendingPathComponent("iPod_Control/Artwork"), includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "ithmb" }
        try check(!artwork.isEmpty, "No artwork rendered")
        for file in artwork { try check(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize! > 0, "Empty artwork") }
    case "verify-eject" where args.count == 2:
        try check(try json(args[1])["ejected"] as? Bool == true, "Volume was not ejected")
    default: throw Failure(message: "Usage: fixture-tool generate ROOT | verify-sync SYNC PLAN DEVICE | verify-eject RESULT")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
}
