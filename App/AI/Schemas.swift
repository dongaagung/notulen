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

    private static let nullableString: JSONValue = ["type": ["string", "null"]]

    /// `Minutes`, in the snake_case the model writes. Nullable fields use the
    /// same `["type", "null"]` form as `liveNotes`.
    static let minutes: JSONValue = [
        "type": "object",
        "properties": [
            "title_suggestion": ["type": "string"],
            "summary": ["type": "string"],
            "decisions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "text": ["type": "string"],
                        "at": ["type": "number"],
                    ],
                    "required": ["id", "text", "at"],
                    "additionalProperties": false,
                ],
            ],
            "action_items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "task": ["type": "string"],
                        "owner": [
                            "type": ["object", "null"],
                            "properties": [
                                "speaker": nullableString,
                                "name": nullableString,
                            ],
                            "required": ["speaker", "name"],
                            "additionalProperties": false,
                        ],
                        "due": nullableString,
                        "at": ["type": "number"],
                    ],
                    "required": ["id", "task", "owner", "due", "at"],
                    "additionalProperties": false,
                ],
            ],
            "open_questions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "question": ["type": "string"],
                        "context": nullableString,
                        "at": ["type": "number"],
                    ],
                    "required": ["id", "question", "context", "at"],
                    "additionalProperties": false,
                ],
            ],
            "topics": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "start": ["type": "number"],
                        "end": ["type": "number"],
                        "points": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["title", "start", "end", "points"],
                    "additionalProperties": false,
                ],
            ],
            "speaker_name_hints": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "speaker": ["type": "string"],
                        "name": ["type": "string"],
                        "evidence": ["type": "string"],
                    ],
                    "required": ["speaker", "name", "evidence"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": [
            "title_suggestion", "summary", "decisions", "action_items", "open_questions", "topics",
            "speaker_name_hints",
        ],
        "additionalProperties": false,
    ]
}
