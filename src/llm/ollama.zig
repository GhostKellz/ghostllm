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
    // Convert to Ollama format
    const ollama_request = try createOllamaRequest(allocator, request);
    defer allocator.free(ollama_request);
    
    // Make HTTP request to Ollama
    const ollama_response = try makeOllamaRequest(allocator, "/api/chat", ollama_request);
    defer allocator.free(ollama_response);
    
    // Convert Ollama response to OpenAI format
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
    
    // For now, return a simplified response - in real implementation we'd parse Ollama's response
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

fn makeOllamaRequest(allocator: std.mem.Allocator, endpoint: []const u8, body: []const u8) ![]const u8 {
    const cfg = config.getConfig();
    
    // Use the HTTP client to make actual requests to Ollama
    const http_client = @import("../protocol/http_client.zig");
    const client = http_client.HttpClient.init(allocator);
    
    const ollama_url = try std.fmt.allocPrint(allocator, "http://{s}:{}{s}", .{ cfg.ollama_host, cfg.ollama_port, endpoint });
    defer allocator.free(ollama_url);
    
    std.debug.print("Making Ollama request to: {s}\n", .{ollama_url});
    std.debug.print("Request body: {s}\n", .{body});
    
    const response = client.post(ollama_url, body) catch |err| {
        std.debug.print("Failed to connect to Ollama at {s}: {}\n", .{ollama_url, err});
        
        // Return appropriate fallback based on endpoint
        if (std.mem.eql(u8, endpoint, "/api/tags")) {
            return try allocator.dupe(u8,
                \\{"models": [{"name": "llama2", "modified_at": "2023-08-04T19:22:45.085406Z", "size": 3826793677}]}
            );
        }
        
        if (std.mem.indexOf(u8, endpoint, "/api/chat") != null) {
            return try allocator.dupe(u8,
                \\{"model": "llama2", "created_at": "2023-08-04T19:22:45.499127Z", "message": {"role": "assistant", "content": "Hello! Ollama is not available, this is a fallback response."}, "done": true}
            );
        }
        
        if (std.mem.indexOf(u8, endpoint, "/api/generate") != null) {
            return try allocator.dupe(u8,
                \\{"model": "llama2", "created_at": "2023-08-04T19:22:45.499127Z", "response": "This is a fallback response from GhostLLM.", "done": true}
            );
        }
        
        return try allocator.dupe(u8, "{}");
    };
    
    std.debug.print("Ollama response: {s}\n", .{response});
    return response;
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