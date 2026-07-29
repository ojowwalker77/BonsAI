import Foundation

/// The durable board envelope stored in `Dump.cardsData`.
///
/// Version 0 was an unwrapped `[CardState]`. Version 1 adds an explicit format version and keeps
/// card records that this build does not understand as opaque JSON. That lets an older BonsAI edit
/// the cards it knows without deleting elements introduced by a newer build.
struct BoardPayload {
  static let currentFormatVersion = 1

  struct OpaqueCard: Equatable {
    let originalIndex: Int
    let data: Data
  }

  let cards: [CardState]
  let opaqueCards: [OpaqueCard]
  let isLegacy: Bool

  var hasMeaningfulContent: Bool {
    cards.contains(where: \.hasMeaningfulContent) || !opaqueCards.isEmpty
  }

  static func decode(_ data: Data) throws -> BoardPayload {
    let root: Any
    do {
      root = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw BoardPayloadError.invalidJSON(error.localizedDescription)
    }

    let cardObjects: [Any]
    let isLegacy: Bool
    if let legacyCards = root as? [Any] {
      cardObjects = legacyCards
      isLegacy = true
    } else if let envelope = root as? [String: Any] {
      guard let formatVersion = envelope["formatVersion"] as? Int else {
        throw BoardPayloadError.missingFormatVersion
      }
      guard formatVersion == currentFormatVersion else {
        throw BoardPayloadError.unsupportedFormatVersion(formatVersion)
      }
      guard let encodedCards = envelope["cards"] as? [Any] else {
        throw BoardPayloadError.invalidCards
      }
      cardObjects = encodedCards
      isLegacy = false
    } else {
      throw BoardPayloadError.invalidRoot
    }

    var cards: [CardState] = []
    var opaqueCards: [OpaqueCard] = []
    for (index, object) in cardObjects.enumerated() {
      let encoded = try encodedJSONObject(object)
      guard let dictionary = object as? [String: Any],
            hasRecognizedKind(dictionary),
            let card = try? JSONDecoder().decode(CardState.self, from: encoded) else {
        opaqueCards.append(OpaqueCard(originalIndex: index, data: encoded))
        continue
      }
      cards.append(card)
    }

    return BoardPayload(cards: cards, opaqueCards: opaqueCards, isLegacy: isLegacy)
  }

  static func encode(cards: [CardState], preserving opaqueCards: [OpaqueCard] = []) throws -> Data {
    var objects = try cards.map { card -> Any in
      let data = try JSONEncoder().encode(card)
      return try JSONSerialization.jsonObject(with: data)
    }

    for opaque in opaqueCards.sorted(by: { $0.originalIndex < $1.originalIndex }) {
      let object = try JSONSerialization.jsonObject(with: opaque.data, options: [.fragmentsAllowed])
      objects.insert(object, at: min(opaque.originalIndex, objects.count))
    }

    let envelope: [String: Any] = [
      "formatVersion": currentFormatVersion,
      "cards": objects,
    ]
    return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
  }

  private static func hasRecognizedKind(_ dictionary: [String: Any]) -> Bool {
    guard let value = dictionary["kind"], !(value is NSNull) else { return true }
    guard let rawKind = value as? String else { return false }
    return CanvasElementKind(rawValue: rawKind) != nil
  }

  private static func encodedJSONObject(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
  }
}

enum BoardPayloadError: LocalizedError {
  case invalidJSON(String)
  case invalidRoot
  case missingFormatVersion
  case unsupportedFormatVersion(Int)
  case invalidCards

  var errorDescription: String? {
    switch self {
    case .invalidJSON(let diagnostic):
      "The saved board is not valid JSON: \(diagnostic)"
    case .invalidRoot:
      "The saved board has an unsupported root value."
    case .missingFormatVersion:
      "The saved board envelope has no format version."
    case .unsupportedFormatVersion(let version):
      "This board uses format version \(version), but this BonsAI build supports version \(BoardPayload.currentFormatVersion)."
    case .invalidCards:
      "The saved board envelope has no readable cards array."
    }
  }
}
