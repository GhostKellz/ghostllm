const std = @import("std");
const config = @import("../config/config.zig");

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []ChatMessage,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    stream: ?bool = null,
};

pub const CompletionRequest = struct {
    model: []const u8,
    prompt: []const u8,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    stream: ?bool = null,
};

pub const ChatResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []Choice,
    usage: Usage,
};

pub const Choice = struct {
    index: u32,
    message: ChatMessage,
    finish_reason: []const u8,
};

pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

pub fn handleChatCompletion(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    _ = config.getConfig();
    
    // Convert to Ollama format
    const ollama_request = try createOllamaRequest(allocator, request);
    defer allocator.free(ollama_request);
    
    // Make request to Ollama
    const ollama_response = try makeOllamaRequest(allocator, "/api/chat", ollama_request);
    defer allocator.free(ollama_response);
    
    // Convert response to OpenAI format
    return try convertOllamaToOpenAI(allocator, ollama_response, request.model, "chat.completion");
}

pub fn handleCompletion(allocator: std.mem.Allocator, request: CompletionRequest) ![]const u8 {
    _ = config.getConfig();
    
    const ollama_request = try createOllamaCompletionRequest(allocator, request);
    defer allocator.free(ollama_request);
    
    const ollama_response = try makeOllamaRequest(allocator, "/api/generate", ollama_request);
    defer allocator.free(ollama_response);
    
    return try convertOllamaToOpenAI(allocator, ollama_response, request.model, "text_completion");
}

pub fn getAvailableModels(allocator: std.mem.Allocator) ![]const u8 {
    const ollama_response = try makeOllamaRequest(allocator, "/api/tags", "{}");
    defer allocator.free(ollama_response);
    
    // Parse Ollama models response and convert to OpenAI format
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, ollama_response, .{}) catch {
        return try allocator.dupe(u8,
            \\{"object": "list", "data": [{"id": "llama2", "object": "model", "created": 1677610602, "owned_by": "ollama"}]}
        );
    };
    defer parsed.deinit();
    
    var models_array = std.ArrayList(std.json.Value).init(allocator);
    defer models_array.deinit();
    
    if (parsed.value.object.get("models")) |models| {
        if (models.array) |model_list| {
            for (model_list.items) |model| {
                if (model.object.get("name")) |_| {
                    const model_obj = std.json.Value{ .object = std.StringHashMap(std.json.Value).init(allocator) };
                    // Note: This is simplified - in real implementation we'd properly construct the model object
                    try models_array.append(model_obj);
                }
            }
        }
    }
    
    return try allocator.dupe(u8,
        \\{"object": "list", "data": [{"id": "llama2", "object": "model", "created": 1677610602, "owned_by": "ollama"}]}
    );
}

fn createOllamaRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    var messages_json = std.ArrayList(u8).init(allocator);
    defer messages_json.deinit();
    
    try messages_json.appendSlice("[");
    for (request.messages, 0..) |msg, i| {
        if (i > 0) try messages_json.appendSlice(",");
        const msg_json = try std.fmt.allocPrint(allocator,
            \\{{"role": "{s}", "content": "{s}"}}
        , .{ msg.role, msg.content });
        defer allocator.free(msg_json);
        try messages_json.appendSlice(msg_json);
    }
    try messages_json.appendSlice("]");
    
    const temperature = request.temperature orelse 0.7;
    
    return try std.fmt.allocPrint(allocator,
        \\{{"model": "{s}", "messages": {s}, "stream": false, "options": {{"temperature": {}}}}}
    , .{ request.model, messages_json.items, temperature });
}

fn createOllamaCompletionRequest(allocator: std.mem.Allocator, request: CompletionRequest) ![]const u8 {
    const temperature = request.temperature orelse 0.7;
    
    return try std.fmt.allocPrint(allocator,
        \\{{"model": "{s}", "prompt": "{s}", "stream": false, "options": {{"temperature": {}}}}}
    , .{ request.model, request.prompt, temperature });
}

fn makeOllamaRequest(allocator: std.mem.Allocator, endpoint: []const u8, _: []const u8) ![]const u8 {
    _ = config.getConfig();
    
    // For now, return a mock response since we don't have HTTP client implemented
    // In a real implementation, this would make an HTTP request to Ollama
    
    if (std.mem.eql(u8, endpoint, "/api/tags")) {
        return try allocator.dupe(u8,
            \\{"models": [{"name": "llama2", "modified_at": "2023-08-04T19:22:45.085406Z", "size": 3826793677}]}
        );
    }
    
    if (std.mem.eql(u8, endpoint, "/api/chat")) {
        return try allocator.dupe(u8,
            \\{"model": "llama2", "created_at": "2023-08-04T19:22:45.499127Z", "message": {"role": "assistant", "content": "Hello! How can I help you today?"}, "done": true}
        );
    }
    
    if (std.mem.eql(u8, endpoint, "/api/generate")) {
        return try allocator.dupe(u8,
            \\{"model": "llama2", "created_at": "2023-08-04T19:22:45.499127Z", "response": "This is a generated response.", "done": true}
        );
    }
    
    return try allocator.dupe(u8, "{}");
}

fn convertOllamaToOpenAI(allocator: std.mem.Allocator, ollama_response: []const u8, model: []const u8, object_type: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, ollama_response, .{}) catch {
        return try allocator.dupe(u8,
            \\{"error": "Failed to parse Ollama response"}
        );
    };
    defer parsed.deinit();
    
    const timestamp = std.time.timestamp();
    const id = try std.fmt.allocPrint(allocator, "chatcmpl-{}", .{timestamp});
    defer allocator.free(id);
    
    if (std.mem.eql(u8, object_type, "chat.completion")) {
        if (parsed.value.object.get("message")) |message| {
            if (message.object.get("content")) |content| {
                return try std.fmt.allocPrint(allocator,
                    \\{{"id": "{s}", "object": "chat.completion", "created": {}, "model": "{s}", "choices": [{{"index": 0, "message": {{"role": "assistant", "content": "{s}"}}, "finish_reason": "stop"}}], "usage": {{"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}}}}
                , .{ id, timestamp, model, content.string });
            }
        }
    } else if (std.mem.eql(u8, object_type, "text_completion")) {
        if (parsed.value.object.get("response")) |response| {
            return try std.fmt.allocPrint(allocator,
                \\{{"id": "{s}", "object": "text_completion", "created": {}, "model": "{s}", "choices": [{{"index": 0, "text": "{s}", "finish_reason": "stop"}}], "usage": {{"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}}}}
            , .{ id, timestamp, model, response.string });
        }
    }
    
    return try allocator.dupe(u8,
        \\{"error": "Failed to convert Ollama response"}
    );
}