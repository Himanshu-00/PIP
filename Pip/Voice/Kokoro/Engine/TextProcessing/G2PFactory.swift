//
//  KokoroSwift (vendored into DynamicNotch; eSpeak support removed)
//
import Foundation

public enum G2P {
  case misaki
}

final class G2PFactory {
  private init() {}

  static func createG2PProcessor(engine: G2P) throws -> G2PProcessor {
    switch engine {
    case .misaki:
      return MisakiG2PProcessor()
    }
  }
}
