import Accelerate
import CoreML
import Foundation
import ImageIO
import SQLite3
import Vision

/// Every photo as an Apple MobileCLIP vector, so photos are found by how
/// they look (26 ms a photo, Neural Engine). Model downloaded once; without
/// it search works as before. Stored in `photo.db`.
actor PhotoVectors {

    static let shared = PhotoVectors()

    private let folder = AppFolders.caches.appendingPathComponent("MobileCLIP")
    private let location = AppFolders.support.appendingPathComponent("photo.db")

    private static let packages = ["mobileclip_s2_image", "mobileclip_s2_text"]
    private static let packageFiles = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
                                       "Data/com.apple.CoreML/weights/weight.bin"]
    private static let tokenizerFiles = ["clip-vocab.json", "clip-merges.txt"]
    /// Pinned commits (the tokenizer came from GitHub's moving `main`) and
    /// each file's SHA-256, checked by FileDownload before it's kept.
    private static let modelRevision = "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"
    private static let tokenizerRevision = "48faa0fea4b08d74188b3841771aca6ff2c92852"
    private static let sha256: [String: String] = [
        "mobileclip_s2_image.mlpackage/Manifest.json": "6a1a3f93b8dca6c237dbb5dc7b19bb3c987042d14860288304986c099d8796b6",
        "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/model.mlmodel": "2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b",
        "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin": "6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00",
        "mobileclip_s2_text.mlpackage/Manifest.json": "ea6a189d82fee2ee36eadb99022cda66a7f6b50a4bf9cc1d9541c7ea3b4242a0",
        "mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/model.mlmodel": "b8651b6d030bae419a9548b41c8fae11f96b59cfa21b6e532a4c4434522b4b80",
        "mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin": "8e8d5454f104b6cbb58d98bf11e038ff1f1943599efea111260a832f094cd0ce",
        "clip-vocab.json": "7aeb221a2a93047170070379743b49204c13d6993d9947323cd94b75c1f657ba",
        "clip-merges.txt": "7e0847f6fced8bd28a736dcaeab20e64ac19010771700197ba479a0a8e517d4f",
    ]

    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var database: OpaquePointer?
    private var downloading = false

    /// Vectors held in memory for searching; dropped after a quiet spell.
    private var matrix: [Float] = []
    private var paths: [String] = []
    private var loaded = false
    private var releaseTask: Task<Void, Never>?
    private static let width = 512

    // MARK: - Model

    var isDownloaded: Bool {
        let manager = FileManager.default
        return Self.packages.allSatisfy { package in
            Self.packageFiles.allSatisfy { manager.fileExists(atPath: folder.appendingPathComponent("\(package).mlpackage/\($0)").path) }
        } && Self.tokenizerFiles.allSatisfy { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Downloads what's missing (each file once; an interrupted download
    /// resumes with the files not yet there). True when everything is here.
    func download() async -> Bool {
        if isDownloaded { return true }
        guard !downloading else { return false }
        downloading = true
        defer { downloading = false }
        ActivityLog.write(.search, "photo model: downloading MobileCLIP S2 (~200 MB)")
        var files: [(url: String, to: URL, sha256: String?)] = []
        for package in Self.packages {
            for file in Self.packageFiles {
                let path = "\(package).mlpackage/\(file)"
                files.append(("https://huggingface.co/apple/coreml-mobileclip/resolve/\(Self.modelRevision)/\(path)",
                              folder.appendingPathComponent(path), Self.sha256[path]))
            }
        }
        for file in Self.tokenizerFiles {
            files.append(("https://raw.githubusercontent.com/apple/ml-mobileclip/\(Self.tokenizerRevision)/ios_app/MobileCLIPExplore/Resources/\(file)",
                          folder.appendingPathComponent(file), Self.sha256[file]))
        }
        do {
            for file in files where !FileManager.default.fileExists(atPath: file.to.path) {
                try FileManager.default.createDirectory(at: file.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let url = URL(string: file.url) else { continue }
                try await FileDownload(destination: file.to, sha256: file.sha256) { _, _ in }.run(from: url)
            }
        } catch {
            ActivityLog.write(.error, "photo model download failed: \(error.localizedDescription)")
            return false
        }
        ActivityLog.write(.search, "photo model: downloaded")
        return isDownloaded
    }

    /// Compiles (once, kept beside the packages) and loads both encoders.
    private func loadModels() -> Bool {
        if imageModel != nil, textModel != nil, tokenizer != nil { return true }
        guard isDownloaded else { return false }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            var models: [MLModel] = []
            for package in Self.packages {
                let compiled = folder.appendingPathComponent("\(package).mlmodelc")
                if !FileManager.default.fileExists(atPath: compiled.path) {
                    let temporary = try MLModel.compileModel(at: folder.appendingPathComponent("\(package).mlpackage"))
                    try? FileManager.default.removeItem(at: compiled)
                    try FileManager.default.moveItem(at: temporary, to: compiled)
                }
                models.append(try MLModel(contentsOf: compiled, configuration: config))
            }
            imageModel = models[0]
            textModel = models[1]
            tokenizer = try CLIPTokenizer(folder: folder)
            return true
        } catch {
            ActivityLog.write(.error, "photo model didn't load: \(error.localizedDescription)")
            return false
        }
    }

    /// Lets the models go (memory pressure, or the backlog finished).
    func unloadModels() {
        imageModel = nil
        textModel = nil
    }

    // MARK: - Database

    private func open() -> Bool {
        if database != nil { return true }
        try? FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(location.path, &database) == SQLITE_OK else { database = nil; return false }
        SQLite.exec(database, "PRAGMA journal_mode = WAL")
        // An empty vector means "read, can't be embedded" (unreadable image).
        SQLite.exec(database, "CREATE TABLE IF NOT EXISTS photos (path TEXT PRIMARY KEY, mtime REAL NOT NULL, vec BLOB)")
        SQLite.excludeFromBackup(location)
        return true
    }

    /// Paths whose vector is current, keyed by path → mtime.
    private func held() -> [String: Double] {
        guard open() else { return [:] }
        var out: [String: Double] = [:]
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT path, mtime FROM photos", -1, &statement, nil) == SQLITE_OK else { return [:] }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = SQLite.string(statement, 0) { out[path] = sqlite3_column_double(statement, 1) }
        }
        return out
    }

    func forget(path: String) {
        guard open() else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "DELETE FROM photos WHERE path = ?", -1, &statement, nil) == SQLITE_OK else { return }
        SQLite.bind(statement, 1, path)
        sqlite3_step(statement)
        loaded = false
    }

    // MARK: - Backlog

    /// Photos without a current vector, in the order to embed them.
    func pending(from pictures: [(path: String, modified: Double)]) -> [(path: String, modified: Double)] {
        let current = held()
        return pictures.filter { picture in
            guard let stamp = current[picture.path] else { return true }
            return abs(stamp - picture.modified) >= 1
        }
    }

    /// Embeds one photo and stores it. False if the model isn't there.
    func embed(path: String, modified: Double) -> Bool {
        guard loadModels(), open(), let imageModel else { return false }
        let vector = imageVector(URL(fileURLWithPath: path), model: imageModel) ?? []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO photos (path, mtime, vec) VALUES (?, ?, ?)",
                                 -1, &statement, nil) == SQLITE_OK else { return false }
        SQLite.bind(statement, 1, path)
        sqlite3_bind_double(statement, 2, modified)
        vector.withUnsafeBytes { SQLite.bind(statement, 3, blob: $0) }
        sqlite3_step(statement)
        loaded = false
        return true
    }

    /// Icons and thumbnails under this size (long side) get no vector: to
    /// MobileCLIP a 116-px line icon looks like line art of anything — UI
    /// icons were the top "headphones" matches. Same floor as captions.
    private static let smallest = 200

    private static func isTooSmall(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return true }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height) < smallest
    }

    /// Once: empties the vectors of images under `smallest`, made before the
    /// floor existed. Reads only image headers.
    func dropSmall() {
        let key = "photoVectorsSmallDropped"
        guard !UserDefaults.standard.bool(forKey: key), open() else { return }
        var dropped = 0
        for path in held().keys {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  Self.isTooSmall(source) else { continue }
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(database, "UPDATE photos SET vec = x'' WHERE path = ?", -1, &statement, nil) == SQLITE_OK {
                SQLite.bind(statement, 1, path)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            dropped += 1
        }
        loaded = false
        UserDefaults.standard.set(true, forKey: key)
        ActivityLog.write(.search, "photo vectors: dropped \(dropped) images under \(Self.smallest) px")
    }

    private func imageVector(_ url: URL, model: MLModel) -> [Float]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), !Self.isTooSmall(source),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
              ] as CFDictionary) else { return nil }
        return imageVector(image, model: model)
    }

    private func imageVector(_ image: CGImage, model: MLModel) -> [Float]? {
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let value = try? MLFeatureValue(cgImage: image, constraint: constraint,
                                              options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]),
              let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value])),
              let array = output.featureValue(for: "final_emb_1")?.multiArrayValue else { return nil }
        return Self.normalised(array)
    }

    private static func normalised(_ array: MLMultiArray) -> [Float] {
        var vector = (0 ..< array.count).map { Float(truncating: array[$0]) }
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if length > 0 { vector = vector.map { $0 / length } }
        return vector
    }

    // MARK: - Search

    /// Photos closest to the text, best first (cosine, −1…1). Empty when the
    /// model or the vectors aren't there.
    func search(_ text: String, limit: Int = 60) -> [(url: URL, similarity: Float)] {
        guard loadModels(), let textModel, let tokenizer, open() else { return [] }
        let ids = tokenizer.encode(text)
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32)
        else { return [] }
        for (index, id) in ids.enumerated() { input[index] = NSNumber(value: id) }
        guard let output = try? textModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text": input])),
              let array = output.featureValue(for: "final_emb_1")?.multiArrayValue else { return [] }
        return rank(Self.normalised(array), limit: limit)
    }

    /// Photos that look most like `image` (a picture on screen), best first.
    func similar(to image: CGImage, limit: Int = 12) -> [(url: URL, similarity: Float)] {
        guard loadModels(), let imageModel, open(), let query = imageVector(image, model: imageModel) else { return [] }
        return rank(query, limit: limit)
    }

    private func rank(_ query: [Float], limit: Int) -> [(url: URL, similarity: Float)] {
        loadMatrix()
        // A matrix shorter than its paths (a partial load) would be read past its end.
        guard !paths.isEmpty, matrix.count >= paths.count * Self.width, query.count >= Self.width else { return [] }
        var scores = [Float](repeating: 0, count: paths.count)
        // One matrix × vector: every photo's similarity at once.
        matrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                for row in 0 ..< paths.count {
                    var dot: Float = 0
                    vDSP_dotpr(m.baseAddress! + row * Self.width, 1, q.baseAddress!, 1, &dot, vDSP_Length(Self.width))
                    scores[row] = dot
                }
            }
        }
        scheduleRelease()
        return scores.indices.sorted { scores[$0] > scores[$1] }.prefix(limit)
            .map { (URL(fileURLWithPath: paths[$0]), scores[$0]) }
    }

    private func loadMatrix() {
        guard !loaded else { return }
        matrix = []
        paths = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT path, vec FROM photos WHERE length(vec) = \(Self.width * 4)",
                                 -1, &statement, nil) == SQLITE_OK else { return }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = SQLite.string(statement, 0), let blob = sqlite3_column_blob(statement, 1) else { continue }
            paths.append(path)
            matrix.append(contentsOf: UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: Self.width))
        }
        loaded = true
    }

    /// ~50 MB of vectors for 26k photos: not kept between searches.
    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled else { return }
            self.matrix = []
            self.paths = []
            self.loaded = false
        }
    }

    /// For `why.sh` and the log: photos with a vector (an empty one = too small or unreadable).
    func count() -> Int {
        guard open() else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT count(*) FROM photos WHERE length(vec) > 0", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
