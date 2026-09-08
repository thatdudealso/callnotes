import Foundation

/// Kind of notes JSON to validate.
public enum NotesSchemaKind: Sendable {
    /// Instant hang-up notes: non-empty `title` and `summary` only.
    case instant
    /// Full deep-notes object stored as JSONB.
    case deep
}

/// Validates model output against the CallNotes JSON schema before persistence.
public struct NotesSchemaValidator: Sendable {
    /// Constrained-decoding schema sent as Ollama `format`. Metadata keys like
    /// `$schema` are omitted because they confuse some local models.
    public static let formatSchemaJSON = """
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["title", "summary", "decisions", "action_items", "follow_ups", "open_questions", "entities"],
          "properties": {
            "title": {"type": "string"},
            "summary": {"type": "string"},
            "decisions": {"type": "array", "items": {"type": "string"}},
            "action_items": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["text"],
                "properties": {
                  "owner": {"type": ["string", "null"]},
                  "text": {"type": "string", "minLength": 1},
                  "due": {"type": ["string", "null"]}
                }
              }
            },
            "follow_ups": {"type": "array", "items": {"type": "string"}},
            "open_questions": {"type": "array", "items": {"type": "string"}},
            "entities": {
              "type": "object",
              "additionalProperties": false,
              "required": ["people", "companies", "amounts", "dates"],
              "properties": {
                "people": {"type": "array", "items": {"type": "string"}},
                "companies": {"type": "array", "items": {"type": "string"}},
                "amounts": {"type": "array", "items": {"type": "string"}},
                "dates": {"type": "array", "items": {"type": "string"}}
              }
            }
          }
        }
        """

    public init() {}

    public func validate(_ raw: String, kind: NotesSchemaKind) throws -> CallNotes {
        let data = try Self.extractJSONObject(from: raw)
        let object = try jsonObject(from: data)
        switch kind {
        case .instant:
            try validateInstant(object)
        case .deep:
            try validateDeep(object)
        }
        do {
            return try JSONDecoder().decode(CallNotes.self, from: data)
        } catch {
            throw NotesGenerationError.schemaInvalid(error.localizedDescription)
        }
    }

    public static func extractJSONObject(from raw: String) throws -> Data {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text.removeSubrange(...newline)
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text.removeSubrange(fence.lowerBound...)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            start < end
        else {
            throw NotesGenerationError.schemaInvalid("no JSON object in model output")
        }
        return Data(String(text[start...end]).utf8)
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw NotesGenerationError.schemaInvalid("malformed JSON")
        }
        guard let object = parsed as? [String: Any] else {
            throw NotesGenerationError.schemaInvalid("top-level value is not an object")
        }
        return object
    }

    private func validateInstant(_ object: [String: Any]) throws {
        try requireOnlyKeys(object, allowed: ["title", "summary"])
        try requireNonEmptyString(object, key: "title")
        try requireNonEmptyString(object, key: "summary")
    }

    private func validateDeep(_ object: [String: Any]) throws {
        try requireOnlyKeys(
            object,
            allowed: ["title", "summary", "decisions", "action_items", "follow_ups", "open_questions", "entities"]
        )
        try requireNonEmptyString(object, key: "title")
        try requireNonEmptyString(object, key: "summary")
        try requireStringArray(object, key: "decisions")
        try requireStringArray(object, key: "follow_ups")
        try requireStringArray(object, key: "open_questions")
        try requireActionItems(object)
        try requireEntities(object)
    }

    private func requireNonEmptyString(_ object: [String: Any], key: String) throws {
        guard let value = object[key] as? String else {
            throw NotesGenerationError.schemaInvalid("missing string \(key)")
        }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NotesGenerationError.schemaInvalid("\(key) is empty")
        }
    }

    private func requireStringArray(_ object: [String: Any], key: String) throws {
        guard let value = object[key] as? [Any] else {
            throw NotesGenerationError.schemaInvalid("missing array \(key)")
        }
        guard value.allSatisfy({ $0 is String }) else {
            throw NotesGenerationError.schemaInvalid("\(key) must be an array of strings")
        }
    }

    private func requireActionItems(_ object: [String: Any]) throws {
        guard let items = object["action_items"] as? [Any] else {
            throw NotesGenerationError.schemaInvalid("missing array action_items")
        }
        for item in items {
            guard let row = item as? [String: Any] else {
                throw NotesGenerationError.schemaInvalid("action_items entries must be objects")
            }
            try requireOnlyKeys(row, allowed: ["owner", "text", "due"])
            guard let text = row["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw NotesGenerationError.schemaInvalid("action_items[].text is required")
            }
            if let owner = row["owner"], !(owner is String || owner is NSNull) {
                throw NotesGenerationError.schemaInvalid("action_items[].owner must be a string or null")
            }
            if let due = row["due"], !(due is String || due is NSNull) {
                throw NotesGenerationError.schemaInvalid("action_items[].due must be a string or null")
            }
        }
    }

    private func requireEntities(_ object: [String: Any]) throws {
        guard let entities = object["entities"] as? [String: Any] else {
            throw NotesGenerationError.schemaInvalid("missing object entities")
        }
        try requireOnlyKeys(entities, allowed: ["people", "companies", "amounts", "dates"])
        for key in ["people", "companies", "amounts", "dates"] {
            try requireStringArray(entities, key: key)
        }
    }

    private func requireOnlyKeys(_ object: [String: Any], allowed: Set<String>) throws {
        let extra = Set(object.keys).subtracting(allowed)
        guard extra.isEmpty else {
            throw NotesGenerationError.schemaInvalid("unexpected properties: \(extra.sorted().joined(separator: ", "))")
        }
    }
}
