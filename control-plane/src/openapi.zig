const std = @import("std");

pub const spec_version = "3.1.0";

pub const openapi_json =
    \\{
    \\  "openapi": "3.1.0",
    \\  "info": {
    \\    "title": "Doppio Control Plane API",
    \\    "version": "1.0.0",
    \\    "description": "Double-shot A/B comparisons: Feature Flags and Experimentation Platform API",
    \\    "license": {
    \\      "name": "Apache 2.0",
    \\      "url": "https://www.apache.org/licenses/LICENSE-2.0.html"
    \\    }
    \\  },
    \\  "servers": [
    \\    {
    \\      "url": "/api/v1",
    \\      "description": "Primary API v1"
    \\    }
    \\  ],
    \\  "paths": {
    \\    "/health": {
    \\      "get": {
    \\        "summary": "Health check",
    \\        "operationId": "getHealth",
    \\        "responses": {
    \\          "200": {
    \\            "description": "Service is healthy",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": {
    \\                  "type": "object",
    \\                  "properties": {
    \\                    "status": { "type": "string", "example": "ok" },
    \\                    "version": { "type": "string", "example": "0.1.0" }
    \\                  },
    \\                  "required": ["status", "version"]
    \\                }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/flags": {
    \\      "get": {
    \\        "summary": "List feature flags",
    \\        "description": "Returns the complete flag set. Cursor pagination is not implemented yet; it arrives with durable storage, so clients must not assume a bounded page.",
    \\        "operationId": "listFlags",
    \\        "responses": {
    \\          "200": {
    \\            "description": "List of flags",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": {
    \\                  "type": "object",
    \\                  "properties": {
    \\                    "flags": { "type": "array", "items": { "$ref": "#/components/schemas/Flag" } }
    \\                  },
    \\                  "required": ["flags"]
    \\                }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      },
    \\      "post": {
    \\        "summary": "Create or replace a feature flag",
    \\        "description": "Writes the flag at the given key, replacing any existing value. Idempotency keys are not honoured here; only the exposure ingest path (/collect) deduplicates.",
    \\        "operationId": "createFlag",
    \\        "requestBody": {
    \\          "required": true,
    \\          "content": {
    \\            "application/json": {
    \\              "schema": { "$ref": "#/components/schemas/FlagWrite" }
    \\            }
    \\          }
    \\        },
    \\        "responses": {
    \\          "201": {
    \\            "description": "Flag written",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": {
    \\                  "type": "object",
    \\                  "properties": {
    \\                    "status": { "type": "string", "enum": ["created"] },
    \\                    "key": { "type": "string" }
    \\                  },
    \\                  "required": ["status", "key"]
    \\                }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/flags/{key}": {
    \\      "get": {
    \\        "summary": "Get flag by key",
    \\        "operationId": "getFlag",
    \\        "parameters": [
    \\          { "name": "key", "in": "path", "required": true, "schema": { "type": "string" } }
    \\        ],
    \\        "responses": {
    \\          "200": {
    \\            "description": "Flag details",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": { "$ref": "#/components/schemas/Flag" }
    \\              }
    \\            }
    \\          },
    \\          "404": { "description": "Flag not found" }
    \\        }
    \\      },
    \\      "delete": {
    \\        "summary": "Delete a flag",
    \\        "operationId": "deleteFlag",
    \\        "parameters": [
    \\          { "name": "key", "in": "path", "required": true, "schema": { "type": "string" } }
    \\        ],
    \\        "responses": {
    \\          "204": { "description": "Flag deleted" }
    \\        }
    \\      }
    \\    },
    \\    "/segments": {
    \\      "get": {
    \\        "summary": "List reusable segments",
    \\        "operationId": "listSegments",
    \\        "responses": {
    \\          "200": {
    \\            "description": "List of segments",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": {
    \\                  "type": "array",
    \\                  "items": { "$ref": "#/components/schemas/Segment" }
    \\                }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      },
    \\      "post": {
    \\        "summary": "Create a segment",
    \\        "operationId": "createSegment",
    \\        "requestBody": {
    \\          "required": true,
    \\          "content": {
    \\            "application/json": {
    \\              "schema": { "$ref": "#/components/schemas/Segment" }
    \\            }
    \\          }
    \\        },
    \\        "responses": {
    \\          "201": {
    \\            "description": "Segment created",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": { "$ref": "#/components/schemas/Segment" }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/environments": {
    \\      "get": {
    \\        "summary": "List environments",
    \\        "operationId": "listEnvironments",
    \\        "responses": {
    \\          "200": {
    \\            "description": "List of environments",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": {
    \\                  "type": "array",
    \\                  "items": { "$ref": "#/components/schemas/Environment" }
    \\                }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/eval": {
    \\      "post": {
    \\        "summary": "Evaluate flag decision",
    \\        "operationId": "evaluateFlag",
    \\        "requestBody": {
    \\          "required": true,
    \\          "content": {
    \\            "application/json": {
    \\              "schema": {
    \\                "type": "object",
    \\                "properties": {
    \\                  "flag_key": { "type": "string" },
    \\                  "context": {
    \\                    "type": "object",
    \\                    "properties": {
    \\                      "unit_id": { "type": "string" },
    \\                      "attributes": { "type": "object" }
    \\                    },
    \\                    "required": ["unit_id"]
    \\                  }
    \\                },
    \\                "required": ["flag_key", "context"]
    \\              }
    \\            }
    \\          }
    \\        },
    \\        "responses": {
    \\          "200": {
    \\            "description": "Evaluation result",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": { "$ref": "#/components/schemas/EvaluationResult" }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/audit": {
    \\      "get": {
    \\        "summary": "List immutable audit events",
    \\        "operationId": "listAuditEvents",
    \\        "responses": {
    \\          "200": {
    \\            "description": "Audit event history",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": {
    \\                  "type": "array",
    \\                  "items": { "$ref": "#/components/schemas/AuditEvent" }
    \\                }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/sync/snapshot": {
    \\      "get": {
    \\        "summary": "Full flag snapshot for cold-start clients",
    \\        "operationId": "getSyncSnapshot",
    \\        "description": "Returns the complete flag set and the current change sequence. Prefer /sync/updates/{after_seq} for incremental updates.",
    \\        "responses": {
    \\          "200": {
    \\            "description": "Current flag snapshot",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": { "$ref": "#/components/schemas/SnapshotMessage" }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/sync/updates/{after_seq}": {
    \\      "get": {
    \\        "summary": "Long-poll for flag changes since after_seq",
    \\        "operationId": "getSyncUpdates",
    \\        "description": "Blocks until a change with seq greater than after_seq is recorded, then returns the delta. Returns an ack when no change arrives in time. Clients too stale receive a full snapshot instead.",
    \\        "parameters": [
    \\          { "name": "after_seq", "in": "path", "required": true, "schema": { "type": "integer", "format": "int64" } }
    \\        ],
    \\        "responses": {
    \\          "200": {
    \\            "description": "Delta, snapshot, or ack",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": { "$ref": "#/components/schemas/DeltaMessage" }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/sync/stream": {
    \\      "get": {
    \\        "summary": "Server-sent events stream of flag changes",
    \\        "operationId": "streamSyncUpdates",
    \\        "description": "text/event-stream transport. Emits a delta event per change and a comment heartbeat while idle. Clients fall back to /sync/updates/{after_seq} when unavailable.",
    \\        "responses": {
    \\          "200": {
    \\            "description": "Event stream of snapshot and delta messages",
    \\            "content": {
    \\              "text/event-stream": {
    \\                "schema": { "$ref": "#/components/schemas/DeltaMessage" }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/sync/ws": {
    \\      "get": {
    \\        "summary": "WebSocket transport for flag changes",
    \\        "operationId": "websocketSyncUpdates",
    \\        "description": "Full-duplex RFC 6455 transport. Clients may send hello, ack, heartbeat, and exposure messages and receive snapshot, delta, ack, and pong frames.",
    \\        "responses": {
    \\          "101": { "description": "Switching protocols" }
    \\        }
    \\      }
    \\    },
    \\    "/collect": {
    \\      "post": {
    \\        "summary": "Report flag exposure events",
    \\        "operationId": "collectExposures",
    \\        "description": "Ingests exposure events from client SDKs. An event may carry an idempotency key so retries and duplicate delivery collapse to one recorded event; when the key is omitted the server derives one from the unit, flag, and timestamp.",
    \\        "requestBody": {
    \\          "required": true,
    \\          "content": {
    \\            "application/json": {
    \\              "schema": {
    \\                "type": "object",
    \\                "properties": {
    \\                  "events": {
    \\                    "type": "array",
    \\                    "items": { "$ref": "#/components/schemas/ExposureEventIngest" }
    \\                  }
    \\                },
    \\                "required": ["events"]
    \\              }
    \\            }
    \\          }
    \\        },
    \\        "responses": {
    \\          "200": {
    \\            "description": "Ingest result",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": {
    \\                  "type": "object",
    \\                  "properties": {
    \\                    "accepted": { "type": "integer" },
    \\                    "pending": { "type": "integer" }
    \\                  },
    \\                  "required": ["accepted", "pending"]
    \\                }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/admin/login": {
    \\      "post": {
    \\        "summary": "Exchange an admin token for an admin UI session cookie",
    \\        "operationId": "adminLogin",
    \\        "requestBody": {
    \\          "required": true,
    \\          "content": {
    \\            "application/x-www-form-urlencoded": {
    \\              "schema": {
    \\                "type": "object",
    \\                "properties": {
    \\                  "token": { "type": "string" }
    \\                },
    \\                "required": ["token"]
    \\              }
    \\            }
    \\          }
    \\        },
    \\        "responses": {
    \\          "303": { "description": "Session cookie set, redirect to /admin/flags" }
    \\        }
    \\      }
    \\    },
    \\    "/admin/flags": {
    \\      "get": {
    \\        "summary": "Admin UI: flag list and pending change requests",
    \\        "operationId": "adminFlagsPage",
    \\        "responses": {
    \\          "200": {
    \\            "description": "Server-rendered HTML page",
    \\            "content": { "text/html": { "schema": { "type": "string" } } }
    \\          }
    \\        }
    \\      },
    \\      "post": {
    \\        "summary": "Stage a flag create change request",
    \\        "operationId": "adminStageFlagCreate",
    \\        "requestBody": {
    \\          "required": true,
    \\          "content": {
    \\            "application/x-www-form-urlencoded": {
    \\              "schema": {
    \\                "type": "object",
    \\                "properties": {
    \\                  "key": { "type": "string" },
    \\                  "enabled": { "type": "string", "enum": ["on", "off"] },
    \\                  "rollout_percentage": { "type": "integer" }
    \\                },
    \\                "required": ["key"]
    \\              }
    \\            }
    \\          }
    \\        },
    \\        "responses": {
    \\          "200": {
    \\            "description": "HTML confirmation fragment",
    \\            "content": { "text/html": { "schema": { "type": "string" } } }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/admin/flags/{key}/edit": {
    \\      "get": {
    \\        "summary": "Admin UI: flag edit form",
    \\        "operationId": "adminFlagEditPage",
    \\        "parameters": [
    \\          { "name": "key", "in": "path", "required": true, "schema": { "type": "string" } }
    \\        ],
    \\        "responses": {
    \\          "200": {
    \\            "description": "Server-rendered HTML form",
    \\            "content": { "text/html": { "schema": { "type": "string" } } }
    \\          }
    \\        }
    \\      },
    \\      "post": {
    \\        "summary": "Stage a flag update or delete change request",
    \\        "operationId": "adminStageFlagUpdate",
    \\        "parameters": [
    \\          { "name": "key", "in": "path", "required": true, "schema": { "type": "string" } }
    \\        ],
    \\        "responses": {
    \\          "200": {
    \\            "description": "HTML confirmation fragment",
    \\            "content": { "text/html": { "schema": { "type": "string" } } }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/admin/change-requests": {
    \\      "get": {
    \\        "summary": "Admin UI: change request queue",
    \\        "operationId": "adminChangeRequestsPage",
    \\        "responses": {
    \\          "200": {
    \\            "description": "Server-rendered HTML page",
    \\            "content": { "text/html": { "schema": { "type": "string" } } }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/admin/change-requests/{id}/approve": {
    \\      "post": {
    \\        "summary": "Approve a change request and apply it to the store",
    \\        "operationId": "adminApproveChange",
    \\        "parameters": [
    \\          { "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }
    \\        ],
    \\        "responses": {
    \\          "200": {
    \\            "description": "HTML row fragment for the closed change request",
    \\            "content": { "text/html": { "schema": { "type": "string" } } }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/admin/segments/console": {
    \\      "post": {
    \\        "summary": "Evaluate a CEL expression against a unit id",
    \\        "operationId": "adminSegmentConsole",
    \\        "requestBody": {
    \\          "required": true,
    \\          "content": {
    \\            "application/x-www-form-urlencoded": {
    \\              "schema": {
    \\                "type": "object",
    \\                "properties": {
    \\                  "expression": { "type": "string" },
    \\                  "unit_id": { "type": "string" }
    \\                },
    \\                "required": ["expression"]
    \\              }
    \\            }
    \\          }
    \\        },
    \\        "responses": {
    \\          "200": {
    \\            "description": "HTML result fragment",
    \\            "content": { "text/html": { "schema": { "type": "string" } } }
    \\          }
    \\        }
    \\      }
    \\    }
    \\  },
    \\  "components": {
    \\    "schemas": {
    \\      "Flag": {
    \\        "type": "object",
    \\        "properties": {
    \\          "key": { "type": "string" },
    \\          "enabled": { "type": "boolean" },
    \\          "rollout_percentage": { "type": "integer", "minimum": 0, "maximum": 100 },
    \\          "version": { "type": "integer" }
    \\        },
    \\        "required": ["key", "enabled", "rollout_percentage", "version"]
    \\      },
    \\      "FlagWrite": {
    \\        "type": "object",
    \\        "properties": {
    \\          "key": { "type": "string" },
    \\          "enabled": { "type": "boolean" },
    \\          "rollout_percentage": { "type": "integer", "minimum": 0, "maximum": 100 }
    \\        },
    \\        "required": ["key", "enabled", "rollout_percentage"]
    \\      },
    \\      "Segment": {
    \\        "type": "object",
    \\        "properties": {
    \\          "key": { "type": "string" },
    \\          "expression": { "type": "string" }
    \\        },
    \\        "required": ["key", "expression"]
    \\      },
    \\      "Environment": {
    \\        "type": "object",
    \\        "properties": {
    \\          "name": { "type": "string" },
    \\          "order": { "type": "integer" }
    \\        },
    \\        "required": ["name"]
    \\      },
    \\      "EvaluationResult": {
    \\        "type": "object",
    \\        "properties": {
    \\          "flag_key": { "type": "string" },
    \\          "enabled": { "type": "boolean" },
    \\          "bucket": { "type": "integer" },
    \\          "reason": { "type": "string" },
    \\          "variation": { "type": "string" }
    \\        },
    \\        "required": ["flag_key", "enabled", "bucket", "reason"]
    \\      },
    \\      "AuditEvent": {
    \\        "type": "object",
    \\        "properties": {
    \\          "id": { "type": "string" },
    \\          "action": { "type": "string" },
    \\          "target": { "type": "string" },
    \\          "actor": { "type": "string" },
    \\          "timestamp": { "type": "integer" }
    \\        },
    \\        "required": ["id", "action", "target", "actor", "timestamp"]
    \\      },
    \\      "SnapshotMessage": {
    \\        "type": "object",
    \\        "properties": {
    \\          "type": { "type": "string", "enum": ["snapshot"] },
    \\          "seq": { "type": "integer", "format": "int64" },
    \\          "flags": { "type": "array", "items": { "$ref": "#/components/schemas/Flag" } }
    \\        },
    \\        "required": ["type", "seq", "flags"]
    \\      },
    \\      "DeltaMessage": {
    \\        "type": "object",
    \\        "properties": {
    \\          "type": { "type": "string", "enum": ["delta", "ack"] },
    \\          "seq": { "type": "integer", "format": "int64" },
    \\          "changes": {
    \\            "type": "array",
    \\            "items": {
    \\              "type": "object",
    \\              "properties": {
    \\                "key": { "type": "string" },
    \\                "deleted": { "type": "boolean" },
    \\                "enabled": { "type": "boolean" },
    \\                "rollout_percentage": { "type": "integer", "minimum": 0, "maximum": 100 },
    \\                "seq": { "type": "integer", "format": "int64" }
    \\              },
    \\              "required": ["key", "deleted", "enabled", "rollout_percentage", "seq"]
    \\            }
    \\          }
    \\        },
    \\        "required": ["type", "seq"]
    \\      },
    \\      "ExposureEventIngest": {
    \\        "type": "object",
    \\        "properties": {
    \\          "flag_key": { "type": "string" },
    \\          "user_id": { "type": "string" },
    \\          "enabled": { "type": "boolean" },
    \\          "variation": { "type": "string" },
    \\          "bucket": { "type": "integer" },
    \\          "timestamp": { "type": "integer", "format": "int64" },
    \\          "reason": { "type": "string" },
    \\          "idempotency_key": { "type": "string" }
    \\        },
    \\        "required": ["flag_key", "timestamp"]
    \\      }
    \\    },
    \\    "securitySchemes": {
    \\      "BearerAuth": {
    \\        "type": "http",
    \\        "scheme": "bearer",
    \\        "bearerFormat": "JWT"
    \\      },
    \\      "ApiKeyAuth": {
    \\        "type": "apiKey",
    \\        "in": "header",
    \\        "name": "X-Doppio-Key"
    \\      }
    \\    }
    \\  },
    \\  "security": [
    \\    { "BearerAuth": [] },
    \\    { "ApiKeyAuth": [] }
    \\  ]
    \\}
;

pub fn getSpecJson() []const u8 {
    return openapi_json;
}

test "comptime openapi specification is valid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), openapi_json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const root = parsed.value.object;
    const version_val = root.get("openapi").?.string;
    try std.testing.expectEqualStrings("3.1.0", version_val);
}
