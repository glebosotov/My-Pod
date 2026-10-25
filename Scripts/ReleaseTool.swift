// Release-only tooling. libarchive validates archive members without extracting them.
import Foundation
import Dispatch
import CryptoKit
import Darwin
import CArchive

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
let fm = FileManager.default
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}
func run(_ arguments: [String]) throws -> Data {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.standardOutput = pipe
    // waitUntilExit polls a run loop; a termination signal avoids per-command latency.
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    finished.wait()
    try require(process.terminationStatus == 0, "Command failed: \(arguments)")
    return data
}
func command(_ arguments: [String]) throws -> String {
    String(decoding: try run(arguments), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func readJSON<T: Decodable>(_ path: URL, as: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: path))
}
func writeJSON<T: Encodable>(_ value: T, to path: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(10)
    try data.write(to: path, options: .atomic)
}
func directory(_ path: URL) throws { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
func copy(_ from: URL, _ to: URL) throws { try fm.copyItem(at: from, to: to) }
func regex(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}
struct Library: Codable {
    let name, version: String
    let licenses: [String]
    let homepage: String
}
struct Source: Decodable {
    let name, version, src: String
    let outputs: [String]
    let licenses: [String]
    let homepage: String
    var library: Library { Library(name: name, version: version, licenses: licenses, homepage: homepage) }
}
struct Manifest: Codable {
    let version, system, sourceRevision, correspondingSources: String
    let libraries: [Library]
}

final class Archive {
    let handle: OpaquePointer
    init(_ url: URL) throws {
        guard let handle = archive_read_new() else { throw Failure("Cannot allocate archive reader") }
        archive_read_support_filter_all(handle)
        archive_read_support_format_all(handle)
        if archive_read_open_filename(handle, url.path, 10240) != ARCHIVE_OK {
            let message = archive_error_string(handle).map { String(cString: $0) } ?? "Unknown error"
            archive_read_free(handle)
            throw Failure("Cannot open archive: \(message)")
        }
        self.handle = handle
    }
    deinit { archive_read_free(handle) }
    func each(_ body: (String, UInt32) throws -> Void) throws {
        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(handle, &entry)
            if status == ARCHIVE_EOF { return }
            try require(status == ARCHIVE_OK, "Invalid archive header")
            guard let entry = entry, let path = archive_entry_pathname(entry) else {
                throw Failure("Missing archive pathname")
            }
            // Hard links have a regular-file type but must not enter binary bundles.
            let type = archive_entry_hardlink(entry) == nil ? archive_entry_filetype(entry) : 0
            try body(String(cString: path), UInt32(type))
        }
    }
    func data() throws -> Data {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = archive_read_data(handle, &buffer, buffer.count)
            try require(count >= 0, "Cannot read archive data")
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
let regular: UInt32 = 0o100000, folder: UInt32 = 0o040000
func noticeName(_ name: String) -> Bool { regex("(?i)COPYING|LICEN[CS]E|COPYRIGHT|NOTICE|^README", name) }
func copyNotices(_ source: URL, _ target: URL) throws {
    try directory(target)
    var count = 0
    func save(_ name: String, _ data: Data) throws {
        let destination = target.appendingPathComponent(name.replacingOccurrences(of: "/", with: "__"))
        try require(!fm.fileExists(atPath: destination.path), "Colliding license notice: \(name)")
        try data.write(to: destination)
        count += 1
    }
    if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        guard let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw Failure("Cannot enumerate \(source.path)")
        }
        for case let file as URL in files {
            let name = String(file.path.dropFirst(source.path.count + 1))
            let isFile = try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            if name.split(separator: "/").count <= 3 && noticeName(file.lastPathComponent) && isFile {
                try save(name, Data(contentsOf: file))
            }
        }
    } else {
        let archive = try Archive(source)
        try archive.each { name, type in
            if type == regular && name.split(separator: "/").count <= 4
                && noticeName((name as NSString).lastPathComponent) {
                try save(name, archive.data())
            }
        }
    }
    try require(count > 0, "No license notices found in \(source.path)")
}
let systemPaths = ["/usr/lib/", "/System/Library/"]
func systemPath(_ path: String) -> Bool { systemPaths.contains { path.hasPrefix($0) } }
func dependencies(_ file: URL) throws -> [String] {
    let identity = try command(["otool", "-D", file.path]).components(separatedBy: "\n").dropFirst().first?
        .trimmingCharacters(in: .whitespaces)
    return try command(["otool", "-L", file.path]).components(separatedBy: "\n").dropFirst().map {
        $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " (compatibility")[0]
    }.filter { $0 != identity }
}
func rpaths(_ file: URL) throws -> [String] {
    let lines = try command(["otool", "-l", file.path]).components(separatedBy: "\n")
    return lines.indices.compactMap { i in
        guard lines[i].trimmingCharacters(in: .whitespaces) == "cmd LC_RPATH", i + 2 < lines.count else { return nil }
        return lines[i + 2].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^path ", with: "", options: .regularExpression)
            .components(separatedBy: " (offset")[0]
    }
}
func scrubReferences(_ file: URL) throws {
    var bytes = [UInt8](try Data(contentsOf: file))
    let prefix = Array("/nix/store/".utf8)
    // Same fixed-width substitution as remove-references-to; never resize Mach-O data.
    if bytes.count >= prefix.count + 33 {
        for i in 0...(bytes.count - prefix.count - 33) where bytes[i] == 47 {
            let start = i + prefix.count
            if bytes[i..<start].elementsEqual(prefix) && bytes[start + 32] == 45
                && bytes[start..<start + 32].allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) {
                bytes.replaceSubrange(start..<start + 32, with: repeatElement(UInt8(101), count: 32))
            }
        }
    }
    try Data(bytes).write(to: file)
}
func bundle(_ args: [String: String]) throws {
    func url(_ key: String) -> URL { URL(fileURLWithPath: args[key]!) }
    let output = url("output"), source = url("source")
    try require(!fm.fileExists(atPath: output.path), "Output already exists")
    try directory(output.appendingPathComponent("bin"))
    try directory(output.appendingPathComponent("lib"))
    let notices = output.appendingPathComponent("share/licenses")
    try directory(notices)
    try copy(source.appendingPathComponent("LICENSE"), notices.appendingPathComponent("My-Pod.txt"))
    try copy(source.appendingPathComponent("core/libgpod/COPYING"), notices.appendingPathComponent("libgpod-LGPL-2.1.txt"))
    let packages: [Source] = try readJSON(url("sources"))
    let executable = url("package").appendingPathComponent("bin/mypod").resolvingSymlinksInPath()
    var queue = [executable], destinations = [executable: output.appendingPathComponent("bin/mypod")]
    var names = [String: URL](), used = [String: Source](), mappings = [URL: [(String, String)]]()
    var index = 0
    while index < queue.count {
        let original = queue[index]; index += 1
        let destination = destinations[original]!
        try copy(original, destination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        mappings[destination] = []
        for dependency in try dependencies(original) {
            if systemPath(dependency) { continue }
            try require(!dependency.hasPrefix("@"), "Unresolved dependency: \(dependency)")
            let name = (dependency as NSString).lastPathComponent
            if ["libiconv.2.dylib", "libcharset.1.dylib"].contains(name) {
                let native = "/usr/lib/" + name
                guard let handle = dlopen(native, RTLD_LAZY) else { throw Failure("Cannot load \(native)") }
                defer { dlclose(handle) }
                for symbol in name.contains("iconv") ? ["iconv", "iconv_open", "iconv_close"] : ["locale_charset"] {
                    try require(dlsym(handle, symbol) != nil, "Missing platform symbol: \(symbol)")
                }
                mappings[destination]!.append((dependency, native))
                continue
            }
            let library = URL(fileURLWithPath: dependency).resolvingSymlinksInPath()
            let owners = packages.filter { p in p.outputs.contains { library.path.hasPrefix($0 + "/") } }
            try require(owners.count == 1, "Dependency needs a source/license entry: \(library.path)")
            used[owners[0].name] = owners[0]
            if destinations[library] == nil {
                try require(names[library.lastPathComponent] == nil || names[library.lastPathComponent] == library,
                            "Conflicting library names: \(library.lastPathComponent)")
                names[library.lastPathComponent] = library
                destinations[library] = output.appendingPathComponent("lib/" + library.lastPathComponent)
                queue.append(library)
            }
            let relative = (destination.deletingLastPathComponent().lastPathComponent == "bin" ? "../lib/" : "") + library.lastPathComponent
            mappings[destination]!.append((dependency, "@loader_path/" + relative))
        }
    }
    for original in queue {
        let destination = destinations[original]!
        if destination.deletingLastPathComponent().lastPathComponent == "lib" {
            _ = try run(["install_name_tool", "-id", "@loader_path/" + destination.lastPathComponent, destination.path])
        }
        for (before, after) in mappings[destination]! {
            _ = try run(["install_name_tool", "-change", before, after, destination.path])
        }
        for path in try rpaths(destination) where !systemPath(path) {
            _ = try run(["install_name_tool", "-delete_rpath", path, destination.path])
        }
        try scrubReferences(destination)
        _ = try run(["codesign", "--force", "--sign", "-", destination.path])
        for dependency in try dependencies(destination) {
            try require(systemPath(dependency) || dependency.hasPrefix("@loader_path/"), "Non-relocatable load command: \(dependency)")
        }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destination.path)
    }
    let libraries = used.values.sorted { $0.name < $1.name }
    for package in libraries {
        try copyNotices(URL(fileURLWithPath: package.src), notices.appendingPathComponent(package.name))
    }
    try writeJSON(Manifest(version: args["version"]!, system: args["system"]!, sourceRevision: args["revision"]!,
                           correspondingSources: "mypod-\(args["version"]!)-sources.tar.gz", libraries: libraries.map(\.library)),
                  to: output.appendingPathComponent("bundle.json"))
    print("Bundled \(destinations.count) Mach-O files")
}
func digest(_ file: URL) throws -> [UInt8] {
    let stream = try FileHandle(forReadingFrom: file)
    defer { try? stream.close() }
    var hash = SHA256()
    while let chunk = try stream.read(upToCount: 65536), !chunk.isEmpty { hash.update(data: chunk) }
    return Array(hash.finalize())
}
struct Asset: Encodable {
    let file, hash, url: String
    let bytes: Int
    var unpackedHash: String?
}
func asset(_ file: URL, version: String, unpack: Bool = false) throws -> Asset {
    var result = Asset(file: file.lastPathComponent, hash: "sha256-" + Data(try digest(file)).base64EncodedString(),
                       url: "https://github.com/glebosotov/My-Pod/releases/download/v\(version)/\(file.lastPathComponent)",
                       bytes: try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
    if unpack {
        struct Prefetch: Decodable { let hash: String }
        let info = try JSONDecoder().decode(Prefetch.self, from: run(["nix", "store", "prefetch-file", "--json", "--name", "source", "--unpack", file.absoluteURL.absoluteString]))
        result.unpackedHash = info.hash
    }
    return result
}
func pin(_ args: [String: String]) throws {
    let revision = args["revision"]!
    try require(regex("^[0-9a-f]{40}\\z", revision), "Expected the full CI source commit")
    let root = URL(fileURLWithPath: args["artifacts"]!), output = URL(fileURLWithPath: args["output"]!)
    var bundles = [String: Asset](), manifests = [Manifest]()
    var checked = [String: Set<String>]()
    for system in ["aarch64-darwin", "x86_64-darwin"] {
        let directory = root.appendingPathComponent("mypod-" + system)
        try require(try String(contentsOf: directory.appendingPathComponent("SOURCE_REVISION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == revision,
                    "\(system): wrong source revision")
        var sums = Set<String>()
        for line in try String(contentsOf: directory.appendingPathComponent("SHA256SUMS"), encoding: .utf8).split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            try require(parts.count == 2 && regex("^[0-9a-f]{64}\\z", parts[0]), "Invalid checksum line")
            let name = parts[1]
            try require(!name.contains("/") && name != "." && name != "..", "Unsafe checksum path")
            let actual = try digest(directory.appendingPathComponent(name)).map { String(format: "%02x", $0) }.joined()
            try require(actual == parts[0] && sums.insert(name).inserted, "Invalid or duplicate checksum: \(name)")
        }
        checked[system] = sums
        let archives = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-\(system).tar.gz") }
        try require(archives.count == 1, "\(system): expected one binary archive")
        let file = archives[0]
        try require(sums.contains(file.lastPathComponent), "Missing binary checksum")
        let archive = try Archive(file)
        var names = Set<String>(), found = [Manifest](), manifestNames = [String]()
        try archive.each { name, type in
            let parts = name.split(separator: "/")
            try require(!name.hasPrefix("/") && !parts.contains("..") && !parts.contains(".") && !parts.isEmpty
                        && (type == regular || type == folder) && names.insert(name).inserted,
                        "Unsafe or duplicate binary archive member: \(name)")
            if name.hasSuffix("/bundle.json") {
                try require(type == regular, "Manifest is not a regular file")
                found.append(try JSONDecoder().decode(Manifest.self, from: archive.data()))
                manifestNames.append(name)
            }
        }
        try require(found.count == 1, "Expected exactly one bundle manifest")
        let info = found[0]
        try require(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\\z", info.version), "Invalid release version")
        let prefix = "mypod-\(info.version)-\(system)"
        try require(names.allSatisfy { $0.split(separator: "/").first == Substring(prefix) }
                    && manifestNames[0] == prefix + "/bundle.json" && file.lastPathComponent == prefix + ".tar.gz", "Archive/version mismatch")
        try require(info.sourceRevision == revision && info.system == system, "Bundle provenance mismatch")
        manifests.append(info)
        bundles[system] = try asset(file, version: info.version, unpack: true)
    }
    let version = manifests[0].version
    try require(manifests.allSatisfy { $0.version == version }, "Architectures have different versions")
    let sources = root.appendingPathComponent("mypod-aarch64-darwin/mypod-\(version)-sources.tar.gz")
    try require(checked["aarch64-darwin"]!.contains(sources.lastPathComponent), "Missing source checksum")
    try require(manifests.allSatisfy { $0.correspondingSources == sources.lastPathComponent }, "Wrong corresponding-source archive")
    let archive = try Archive(sources)
    var names = Set<String>()
    try archive.each { name, _ in names.insert(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
    let prefix = "mypod-\(version)-sources"
    try require(names.contains(prefix + "/mypod/core/libgpod/COPYING"), "Missing vendored libgpod source/license")
    for library in manifests.flatMap(\.libraries) {
        try require(names.contains(prefix + "/third-party/\(library.name)-\(library.version)"), "Missing corresponding source: \(library.name)")
    }
    struct Release: Encodable {
        let version, sourceRevision: String
        let bundles: [String: Asset]
        let sources: Asset
    }
    try writeJSON(Release(version: version, sourceRevision: revision, bundles: bundles, sources: asset(sources, version: version)), to: output)
    print("Validated both architectures; wrote \(output.path)")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let action = arguments.first, ["bundle", "pin"].contains(action) else {
        throw Failure("Usage: mypod-release-tool bundle --package PATH --source PATH --sources JSON --output PATH --version VERSION --system SYSTEM --revision SHA | pin --artifacts PATH --revision SHA [--output nix/releases.json]")
    }
    let keys = action == "bundle" ? ["package", "source", "sources", "output", "version", "system", "revision"] : ["artifacts", "revision", "output"]
    var options = [String: String]()
    var i = 1
    while i < arguments.count {
        try require(arguments[i].hasPrefix("--") && i + 1 < arguments.count, "Expected --option value")
        let key = String(arguments[i].dropFirst(2))
        try require(keys.contains(key) && options[key] == nil, "Unknown or duplicate option: \(key)")
        options[key] = arguments[i + 1]; i += 2
    }
    if action == "pin" && options["output"] == nil { options["output"] = "nix/releases.json" }
    try require(keys.allSatisfy { options[$0] != nil }, "Missing required options: \(keys)")
    if action == "bundle" { try bundle(options) } else { try pin(options) }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
