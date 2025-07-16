const std = @import("std");
const config = @import("../config/config.zig");
const http_client = @import("../protocol/http_client.zig");
const logger = @import("../logging/logger.zig");

pub const OpenAIMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const OpenAIRequest = struct {
    model: []const u8,
    messages: []OpenAIMessage,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    stream: ?bool = null,
    top_p: ?f32 = null,
    frequency_penalty: ?f32 = null,
    presence_penalty: ?f32 = null,
};

pub const OpenAIChoice = struct {
    index: u32,
    message: OpenAIMessage,
    finish_reason: []const u8,
};

pub const OpenAIUsage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

pub const OpenAIResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []OpenAIChoice,
    usage: OpenAIUsage,
};

pub fn handleChatCompletion(allocator: std.mem.Allocator, request: OpenAIRequest) ![]const u8 {
    const cfg = config.getConfig();
    
    // Check if we have an OpenAI API key configured
    if (std.mem.eql(u8, cfg.openai_api_key, "")) {
        logger.warn("OpenAI API key not configured, request will fail", .{});
        return error.NoAPIKey;
    }
    
    // Create OpenAI request JSON
    const openai_request = try createOpenAIRequest(allocator, request);
    defer allocator.free(openai_request);
    
    logger.debug("Making OpenAI request with model: {s}", .{request.model});
    
    // Make HTTP request to OpenAI
    const client = http_client.HttpClient.init(allocator);
    
    const headers = [_]http_client.Header{
        .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.openai_api_key}) },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "User-Agent", .value = "GhostLLM/0.2.1" },
    };
    defer allocator.free(headers[0].value);
    
    const openai_response = client.requestWithHeaders("POST", "https://api.openai.com/v1/chat/completions", openai_request, &headers) catch |err| {
        logger.err("Failed to connect to OpenAI API: {}", .{err});
        return error.OpenAIRequestFailed;
    };
    defer allocator.free(openai_response);
    
    logger.debug("OpenAI response received: {} bytes", .{openai_response.len});
    
    // Return the response directly (it's already in OpenAI format)
    return try allocator.dupe(u8, openai_response);
}

pub fn getAvailableModels(allocator: std.mem.Allocator) ![]const u8 {
    const cfg = config.getConfig();
    
    if (std.mem.eql(u8, cfg.openai_api_key, "")) {
        // Return a basic model list if no API key
        return try allocator.dupe(u8,
            \\{"object": "list", "data": [{"id": "gpt-3.5-turbo", "object": "model", "created": 1677610602, "owned_by": "openai"}, {"id": "gpt-4", "object": "model", "created": 1687882411, "owned_by": "openai"}]}
        );
    }
    
    const client = http_client.HttpClient.init(allocator);
    
    const headers = [_]http_client.Header{
        .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.openai_api_key}) },
        .{ .name = "User-Agent", .value = "GhostLLM/0.2.1" },
    };
    defer allocator.free(headers[0].value);
    
    const models_response = client.requestWithHeaders("GET", "https://api.openai.com/v1/models", null, &headers) catch |err| {
        logger.err("Failed to get models from OpenAI: {}", .{err});
        // Return fallback models
        return try allocator.dupe(u8,
            \\{"object": "list", "data": [{"id": "gpt-3.5-turbo", "object": "model", "created": 1677610602, "owned_by": "openai"}, {"id": "gpt-4", "object": "model", "created": 1687882411, "owned_by": "openai"}]}
        );
    };
    defer allocator.free(models_response);
    
    return try allocator.dupe(u8, models_response);
}

fn createOpenAIRequest(allocator: std.mem.Allocator, request: OpenAIRequest) ![]const u8 {
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
    
    var request_json = std.ArrayList(u8).init(allocator);
    defer request_json.deinit();
    
    try request_json.writer().print("{{\"model\": \"{s}\", \"messages\": {s}", .{ request.model, messages_json.items });
    
    if (request.temperature) |temp| {
        try request_json.writer().print(", \"temperature\": {d}", .{temp});
    }
    
    if (request.max_tokens) |tokens| {
        try request_json.writer().print(", \"max_tokens\": {}", .{tokens});
    }
    
    if (request.stream) |stream| {
        try request_json.writer().print(", \"stream\": {}", .{stream});
    }
    
    if (request.top_p) |top_p| {
        try request_json.writer().print(", \"top_p\": {d}", .{top_p});
    }
    
    if (request.frequency_penalty) |freq| {
        try request_json.writer().print(", \"frequency_penalty\": {d}", .{freq});
    }
    
    if (request.presence_penalty) |pres| {
        try request_json.writer().print(", \"presence_penalty\": {d}", .{pres});
    }
    
    try request_json.appendSlice("}");
    
    return try allocator.dupe(u8, request_json.items);
}
