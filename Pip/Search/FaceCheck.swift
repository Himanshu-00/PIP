#if DEBUG
import CoreImage
import Foundation
import ImageIO
import SQLite3
import Vision

/// DEBUG measurement (`Docs/tasks/photos-of-me.md`): can Vision's feature
/// print tell the owner's face from others? Owner's photos from
/// `me-photos.txt`, leave-one-out, precision and recall.
enum FaceCheck {

    private static let support = AppFolders.support
    private static let output = AppFolders.logs.appendingPathComponent("face-check")
    private static let context = CIContext()

    private struct Face {
        let path: String
        let print: VNFeaturePrintObservation
    }

    static func run() {
        let marked = (try? String(contentsOf: support.appendingPathComponent("me-photos.txt"), encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty } ?? []
        guard marked.count >= 2 else {
            ActivityLog.write(.search, "face check: need 2+ paths in me-photos.txt (have \(marked.count))")
            return
        }
        try? FileManager.default.removeItem(at: output)
        for folder in ["me", "not-me"] {
            try? FileManager.default.createDirectory(at: output.appendingPathComponent(folder), withIntermediateDirectories: true)
        }

        var mine: [Face] = []
        for (number, path) in marked.enumerated() {
            guard let face = face(in: path, saveAs: "me/\(number + 1).jpg") else {
                ActivityLog.write(.search, "face check: no face in \((path as NSString).lastPathComponent)")
                continue
            }
            mine.append(face)
        }

        let skip = Set(((try? String(contentsOf: output.deletingLastPathComponent()
            .appendingPathComponent("face-check-is-me.txt"), encoding: .utf8)) ?? "")
            .split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) })
        var others: [Face] = []
        var number = 0
        for path in randomPhotos(excluding: Set(marked)) where others.count < 50 {
            guard let face = face(in: path, saveAs: "not-me/\(number + 1).jpg") else { continue }
            number += 1
            if !skip.contains(number) { others.append(face) }
        }
        guard mine.count >= 2, !others.isEmpty else {
            ActivityLog.write(.search, "face check: \(mine.count) of my faces, \(others.count) others — not enough")
            return
        }

        // Distance to the nearest marked face (lower = more alike).
        func nearest(_ face: Face, among references: [Face]) -> Float {
            references.compactMap { reference -> Float? in
                guard reference.path != face.path else { return nil }
                var distance: Float = 0
                return (try? face.print.computeDistance(&distance, to: reference.print)) != nil ? distance : nil
            }.min() ?? .infinity
        }
        let scores = mine.map { (nearest($0, among: mine), true) } + others.map { (nearest($0, among: mine), false) }

        // Every threshold: "me" when distance ≤ t.
        var best: (t: Float, p: Double, r: Double, f: Double) = (0, 0, 0, 0)
        var bestAt90: (t: Float, p: Double, r: Double)?
        for t in Set(scores.map(\.0)).sorted() {
            let yes = scores.filter { $0.0 <= t }
            let hits = yes.filter(\.1).count
            let precision = Double(hits) / Double(yes.count)
            let recall = Double(hits) / Double(mine.count)
            let f = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
            if f > best.f { best = (t, precision, recall, f) }
            if precision >= 0.9, recall > (bestAt90?.r ?? -1) { bestAt90 = (t, precision, recall) }
        }
        let list = { (s: [(Float, Bool)]) in s.map { String(format: "%.2f", $0.0) }.joined(separator: " ") }
        ActivityLog.write(.search, "face check: mine \(list(scores.filter(\.1).sorted { $0.0 < $1.0 }))")
        ActivityLog.write(.search, "face check: others \(list(Array(scores.filter { !$0.1 }.sorted { $0.0 < $1.0 }.prefix(12)))) …")
        ActivityLog.write(.search, String(format: "face check: %ld of my faces, %ld others (%ld left out); best F1 at %.2f: precision %.0f%%, recall %.0f%%",
                                          mine.count, others.count, skip.count, best.t, best.p * 100, best.r * 100)
                          + (bestAt90.map { String(format: "; precision ≥ 90%% at %.2f: recall %.0f%%", $0.t, $0.r * 100) } ?? "; precision never reaches 90%"))
    }

    /// Photo paths from `photo.db` in a fixed pseudo-random order.
    private static func randomPhotos(excluding marked: Set<String>) -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(support.appendingPathComponent("photo.db").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT path FROM photos WHERE length(vec) > 0 ORDER BY path", -1, &statement, nil) == SQLITE_OK else { return [] }
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = SQLite.string(statement, 0), !marked.contains(path) { paths.append(path) }
        }
        var state: UInt64 = 2026_11_01
        return paths.map { path -> (UInt64, String) in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (state, path)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The largest face in a photo: cropped with a 25% margin, eyes level,
    /// 160 px, saved for checking, then feature-printed.
    private static func face(in path: String, saveAs name: String) -> Face? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        guard let observation = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        let box = VNImageRectForNormalizedRect(observation.boundingBox, image.width, image.height)
        guard min(box.width, box.height) >= 40 else { return nil }

        // Level the eyes: rotate about the face's centre.
        let centre = CGPoint(x: box.midX, y: box.midY)
        var angle: CGFloat = 0
        if let left = observation.landmarks?.leftEye?.pointsInImage(imageSize: size),
           let right = observation.landmarks?.rightEye?.pointsInImage(imageSize: size),
           !left.isEmpty, !right.isEmpty {
            let mid = { (points: [CGPoint]) in
                CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                        y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
            }
            let eyes = [mid(left), mid(right)].sorted { $0.x < $1.x }
            angle = atan2(eyes[1].y - eyes[0].y, eyes[1].x - eyes[0].x)
        }
        let side = max(box.width, box.height) * 1.5
        let crop = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: -centre.x, y: -centre.y)
                .concatenating(CGAffineTransform(rotationAngle: -angle))
                .concatenating(CGAffineTransform(scaleX: 160 / side, y: 160 / side))
                .concatenating(CGAffineTransform(translationX: 80, y: 80)))
        guard let aligned = context.createCGImage(crop, from: CGRect(x: 0, y: 0, width: 160, height: 160)) else { return nil }

        if let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,
                                                             "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, aligned, nil)
            CGImageDestinationFinalize(destination)
        }
        let printRequest = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: aligned).perform([printRequest])
        guard let print = printRequest.results?.first else { return nil }
        return Face(path: path, print: print)
    }
}
#endif
