import Foundation

/// Where the vendored Kokoro and Misaki code finds its small data files
/// (the Kokoro config and Misaki's US-English dictionaries). They ship
/// inside the app; Xcode copies them to the bundle's Resources folder.
enum KokoroResources {
  static func url(_ name: String, _ ext: String) -> URL? {
    Bundle.main.url(forResource: name, withExtension: ext)
      ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources")
  }
}
