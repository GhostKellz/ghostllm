const std = @import("std");
const config = @import("../config/config.zig");
const logger = @import("../logging/logger.zig");
const http_client = @import("../protocol/http_client.zig");

pub const Provider = enum {
    ollama,
    openai,
    claude,
    google,
    github_copilot,
    
    pub fn fromModel(model: []const u8) Provider {
        // OpenAI models
        if (std.mem.startsWith(u8, model, "gpt-") or 
            std.mem.startsWith(u8, model, "o1-") or
            std.mem.eql(u8, model, "davinci") or
            std.mem.eql(u8, model, "curie")) {
            return .openai;
        }
        
        // Claude models
        if (std.mem.startsWith(u8, model, "claude-") or
            std.mem.startsWith(u8, model, "claude_") or
            std.mem.eql(u8, model, "claude")) {
            return .claude;
        }
        
        // Google models
        if (std.mem.startsWith(u8, model, "gemini-") or
            std.mem.startsWith(u8, model, "bison-") or
            std.mem.startsWith(u8, model, "chat-bison") or
            std.mem.startsWith(u8, model, "text-bison")) {
            return .google;
        }
        
        // GitHub Copilot models
        if (std.mem.startsWith(u8, model, "copilot-") or
            std.mem.eql(u8, model, "github-copilot")) {
            return .github_copilot;
        }
        
        // Default to Ollama for local models
        return .ollama;
    }
    
    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .ollama => "ollama",
            .openai => "openai",
            .claude => "claude",
            .google => "google",
            .github_copilot => "github_copilot",
        };
    }
};

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
    provider: ?Provider = null, // Override auto-detection
};

pub const ProviderConfig = struct {
    openai_api_key: ?[]const u8 = null,
    openai_base_url: []const u8 = "https://api.openai.com/v1",
    
    claude_api_key: ?[]const u8 = null,
    claude_base_url: []const u8 = "https://api.anthropic.com/v1",
    
    google_api_key: ?[]const u8 = null,
    google_base_url: []const u8 = "https://generativelanguage.googleapis.com/v1",
    
    github_token: ?[]const u8 = null,
    github_base_url: []const u8 = "https://api.github.com/copilot",
    
    ollama_host: []const u8 = "127.0.0.1",
    ollama_port: u16 = 11434,
};

pub fn routeRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    const provider = request.provider orelse Provider.fromModel(request.model);
    
    logger.info("Routing request to {s} provider for model: {s}", .{ provider.toString(), request.model });
    
    return switch (provider) {
        .ollama => try handleOllamaRequest(allocator, request),
        .openai => try handleOpenAIRequest(allocator, request),
        .claude => try handleClaudeRequest(allocator, request),
        .google => try handleGoogleRequest(allocator, request),
        .github_copilot => try handleGitHubCopilotRequest(allocator, request),
    };
}

fn handleOllamaRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    const ollama = @import("ollama.zig");
    
    // Convert ChatMessage types
    var ollama_messages = std.ArrayList(ollama.ChatMessage).init(allocator);
    defer ollama_messages.deinit();
    
    for (request.messages) |msg| {
        try ollama_messages.append(ollama.ChatMessage{
            .role = msg.role,
            .content = msg.content,
        });
    }
    
    const ollama_request = ollama.ChatRequest{
        .model = request.model,
        .messages = try ollama_messages.toOwnedSlice(),
        .temperature = request.temperature,
        .max_tokens = request.max_tokens,
        .stream = request.stream,
    };
    defer allocator.free(ollama_request.messages);
    
    return try ollama.handleChatCompletion(allocator, ollama_request);
}

fn handleOpenAIRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    const cfg = config.getConfig();
    
    if (cfg.openai_api_key == null) {
        logger.err("OpenAI API key not configured", .{});
        return try createErrorResponse(allocator, "OpenAI API key not configured");
    }
    
    // Convert to OpenAI format
    const openai_request = try createOpenAIRequest(allocator, request);
    defer allocator.free(openai_request);
    
    // Create HTTP client
    const client = http_client.HttpClient.init(allocator);
    
    // Create headers with authorization
    const headers = [_]http_client.Header{
        .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.openai_api_key.?}) },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    defer allocator.free(headers[0].value);
    
    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{cfg.openai_base_url});
    defer allocator.free(url);
    
    const response = client.requestWithHeaders("POST", url, openai_request, &headers) catch |err| {
        logger.err("Failed to call OpenAI API: {}", .{err});
        return try createErrorResponse(allocator, "OpenAI API request failed");
    };
    
    return response;
}

fn handleClaudeRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    const cfg = config.getConfig();
    
    if (cfg.claude_api_key == null) {
        logger.err("Claude API key not configured", .{});
        return try createErrorResponse(allocator, "Claude API key not configured");
    }
    
    // Convert to Claude format
    const claude_request = try createClaudeRequest(allocator, request);
    defer allocator.free(claude_request);
    
    const client = http_client.HttpClient.init(allocator);
    
    // Claude requires specific headers
    const headers = [_]http_client.Header{
        .{ .name = "x-api-key", .value = cfg.claude_api_key.? },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };
    
    const url = try std.fmt.allocPrint(allocator, "{s}/messages", .{cfg.claude_base_url});
    defer allocator.free(url);
    
    const response = client.requestWithHeaders("POST", url, claude_request, &headers) catch |err| {
        logger.err("Failed to call Claude API: {}", .{err});
        return try createErrorResponse(allocator, "Claude API request failed");
    };
    
    // Convert Claude response to OpenAI format
    return try convertClaudeToOpenAI(allocator, response, request.model);
}

fn handleGoogleRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    const cfg = config.getConfig();
    
    if (cfg.google_api_key == null) {
        logger.err("Google AI API key not configured", .{});
        return try createErrorResponse(allocator, "Google AI API key not configured");
    }
    
    // Convert to Google format
    const google_request = try createGoogleRequest(allocator, request);
    defer allocator.free(google_request);
    
    const client = http_client.HttpClient.init(allocator);
    
    const headers = [_]http_client.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    
    // Google uses API key in URL
    const url = try std.fmt.allocPrint(allocator, "{s}/models/{s}:generateContent?key={s}", 
        .{ cfg.google_base_url, request.model, cfg.google_api_key.? });
    defer allocator.free(url);
    
    const response = client.requestWithHeaders("POST", url, google_request, &headers) catch |err| {
        logger.err("Failed to call Google AI API: {}", .{err});
        return try createErrorResponse(allocator, "Google AI API request failed");
    };
    
    // Convert Google response to OpenAI format
    return try convertGoogleToOpenAI(allocator, response, request.model);
}

fn handleGitHubCopilotRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    const cfg = config.getConfig();
    
    if (cfg.github_token == null) {
        logger.err("GitHub token not configured", .{});
        return try createErrorResponse(allocator, "GitHub token not configured");
    }
    
    // Convert to GitHub Copilot format
    const github_request = try createGitHubRequest(allocator, request);
    defer allocator.free(github_request);
    
    const client = http_client.HttpClient.init(allocator);
    
    const headers = [_]http_client.Header{
        .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "token {s}", .{cfg.github_token.?}) },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
    };
    defer allocator.free(headers[0].value);
    
    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{cfg.github_base_url});
    defer allocator.free(url);
    
    const response = client.requestWithHeaders("POST", url, github_request, &headers) catch |err| {
        logger.err("Failed to call GitHub Copilot API: {}", .{err});
        return try createErrorResponse(allocator, "GitHub Copilot API request failed");
    };
    
    return response;
}

// Request format converters
fn createOpenAIRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
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
    
    return try std.fmt.allocPrint(allocator,
        \\{{"model": "{s}", "messages": {s}, "temperature": {?}, "max_tokens": {?}, "stream": {?}}}
    , .{ request.model, messages_json.items, request.temperature, request.max_tokens, request.stream });
}

fn createClaudeRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    // Claude uses a different format - system message separate, user/assistant alternating
    var messages_json = std.ArrayList(u8).init(allocator);
    defer messages_json.deinit();
    
    try messages_json.appendSlice("[");
    var first = true;
    for (request.messages) |msg| {
        if (std.mem.eql(u8, msg.role, "system")) continue; // Handle separately
        
        if (!first) try messages_json.appendSlice(",");
        first = false;
        
        const msg_json = try std.fmt.allocPrint(allocator,
            \\{{"role": "{s}", "content": "{s}"}}
        , .{ msg.role, msg.content });
        defer allocator.free(msg_json);
        try messages_json.appendSlice(msg_json);
    }
    try messages_json.appendSlice("]");
    
    const max_tokens = request.max_tokens orelse 4096;
    
    return try std.fmt.allocPrint(allocator,
        \\{{"model": "{s}", "messages": {s}, "max_tokens": {}}}
    , .{ request.model, messages_json.items, max_tokens });
}

fn createGoogleRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    // Google uses "contents" with "parts"
    var contents_json = std.ArrayList(u8).init(allocator);
    defer contents_json.deinit();
    
    try contents_json.appendSlice("[");
    for (request.messages, 0..) |msg, i| {
        if (i > 0) try contents_json.appendSlice(",");
        
        const role = if (std.mem.eql(u8, msg.role, "assistant")) "model" else "user";
        const content_json = try std.fmt.allocPrint(allocator,
            \\{{"role": "{s}", "parts": [{{"text": "{s}"}}]}}
        , .{ role, msg.content });
        defer allocator.free(content_json);
        try contents_json.appendSlice(content_json);
    }
    try contents_json.appendSlice("]");
    
    return try std.fmt.allocPrint(allocator,
        \\{{"contents": {s}}}
    , .{contents_json.items});
}

fn createGitHubRequest(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    // GitHub Copilot uses OpenAI-compatible format
    return try createOpenAIRequest(allocator, request);
}

// Response converters
fn convertClaudeToOpenAI(allocator: std.mem.Allocator, claude_response: []const u8, model: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, claude_response, .{}) catch {
        return try createErrorResponse(allocator, "Failed to parse Claude response");
    };
    defer parsed.deinit();
    
    const timestamp = std.time.timestamp();
    const id = try std.fmt.allocPrint(allocator, "chatcmpl-{}", .{timestamp});
    defer allocator.free(id);
    
    if (parsed.value.object.get("content")) |content_array| {
        if (content_array.array.items.len > 0) {
            const first_content = content_array.array.items[0];
            if (first_content.object.get("text")) |text| {
                return try std.fmt.allocPrint(allocator,
                    \\{{"id": "{s}", "object": "chat.completion", "created": {}, "model": "{s}", "choices": [{{"index": 0, "message": {{"role": "assistant", "content": "{s}"}}, "finish_reason": "stop"}}], "usage": {{"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}}}}
                , .{ id, timestamp, model, text.string });
            }
        }
    }
    
    return try createErrorResponse(allocator, "Invalid Claude response format");
}

fn convertGoogleToOpenAI(allocator: std.mem.Allocator, google_response: []const u8, model: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, google_response, .{}) catch {
        return try createErrorResponse(allocator, "Failed to parse Google response");
    };
    defer parsed.deinit();
    
    const timestamp = std.time.timestamp();
    const id = try std.fmt.allocPrint(allocator, "chatcmpl-{}", .{timestamp});
    defer allocator.free(id);
    
    if (parsed.value.object.get("candidates")) |candidates| {
        if (candidates.array.items.len > 0) {
            const first_candidate = candidates.array.items[0];
            if (first_candidate.object.get("content")) |content| {
                if (content.object.get("parts")) |parts| {
                    if (parts.array.items.len > 0) {
                        const first_part = parts.array.items[0];
                        if (first_part.object.get("text")) |text| {
                            return try std.fmt.allocPrint(allocator,
                                \\{{"id": "{s}", "object": "chat.completion", "created": {}, "model": "{s}", "choices": [{{"index": 0, "message": {{"role": "assistant", "content": "{s}"}}, "finish_reason": "stop"}}], "usage": {{"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}}}}
                            , .{ id, timestamp, model, text.string });
                        }
                    }
                }
            }
        }
    }
    
    return try createErrorResponse(allocator, "Invalid Google response format");
}

fn createErrorResponse(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"error": {{"message": "{s}", "type": "invalid_request_error"}}}}
    , .{message});
}

// Get available models from all providers
pub fn getAllAvailableModels(allocator: std.mem.Allocator) ![]const u8 {
    var models = std.ArrayList(u8).init(allocator);
    defer models.deinit();
    
    try models.appendSlice("{\"object\": \"list\", \"data\": [");
    
    // OpenAI models
    const openai_models = [_][]const u8{
        "gpt-4", "gpt-4-turbo", "gpt-3.5-turbo", "gpt-3.5-turbo-16k"
    };
    
    // Claude models
    const claude_models = [_][]const u8{
        "claude-3-opus", "claude-3-sonnet", "claude-3-haiku", "claude-2"
    };
    
    // Google models
    const google_models = [_][]const u8{
        "gemini-pro", "gemini-pro-vision", "text-bison-001", "chat-bison-001"
    };
    
    var first = true;
    
    // Add all models
    for (openai_models) |model| {
        if (!first) try models.appendSlice(",");
        first = false;
        const model_json = try std.fmt.allocPrint(allocator,
            \\{{"id": "{s}", "object": "model", "created": 1677610602, "owned_by": "openai"}}
        , .{model});
        defer allocator.free(model_json);
        try models.appendSlice(model_json);
    }
    
    for (claude_models) |model| {
        if (!first) try models.appendSlice(",");
        const model_json = try std.fmt.allocPrint(allocator,
            \\{{"id": "{s}", "object": "model", "created": 1677610602, "owned_by": "anthropic"}}
        , .{model});
        defer allocator.free(model_json);
        try models.appendSlice(model_json);
    }
    
    for (google_models) |model| {
        if (!first) try models.appendSlice(",");
        const model_json = try std.fmt.allocPrint(allocator,
            \\{{"id": "{s}", "object": "model", "created": 1677610602, "owned_by": "google"}}
        , .{model});
        defer allocator.free(model_json);
        try models.appendSlice(model_json);
    }
    
    try models.appendSlice("]}");
    
    return try allocator.dupe(u8, models.items);
}
