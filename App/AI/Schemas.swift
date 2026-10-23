import Foundation

/// JSON schemas for structured replies.
enum Schemas {
    /// `LiveNotes`, in the snake_case the model writes.
    static let liveNotes: JSONValue = [
        "type": "object",
        "properties": [
            "current_topic": ["type": ["integer", "null"]],
            "topics": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "points": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "text": ["type": "string"],
                                    "kind": [
                                        "type": "string",
                                        "enum": ["point", "decision", "action_item", "open_question"],
                                    ],
                                ],
                                "required": ["text", "kind"],
                                "additionalProperties": false,
                            ],
                        ],
                    ],
                    "required": ["title", "points"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["current_topic", "topics"],
        "additionalProperties": false,
    ]
}
