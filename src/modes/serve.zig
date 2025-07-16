const std = @import("std");
const config = @import("../config/config.zig");
const logger = @import("../logging/logger.zig");
const http_parser = @import("../protocol/http_parser.zig");
const ollama = @import("../llm/ollama.zig");

pub fn startServer() !void {
    const cfg = config.getConfig();
    const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, cfg.port);
    var server = address.listen(.{}) catch |err| {
        logger.err("Failed to bind to port {}: {}", .{ cfg.port, err });
        return;
    };
    defer server.deinit();
    
    logger.info("GhostLLM v0.2.0 server listening on http://127.0.0.1:{}", .{cfg.port});
    
    while (true) {
        const connection = server.accept() catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        
        handleConnection(connection) catch |err| {
            logger.err("Error handling connection: {}", .{err});
        };
    }
}

fn handleConnection(connection: std.net.Server.Connection) !void {
    defer connection.stream.close();
    
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    logger.debug("New connection established", .{});
    
    var buffer: [8192]u8 = undefined;
    const bytes_read = try connection.stream.read(&buffer);
    
    if (bytes_read == 0) {
        logger.warn("Received empty request", .{});
        return;
    }
    
    const request_data = buffer[0..bytes_read];
    logger.debug("Received {} bytes", .{bytes_read});
    
    // Parse HTTP request
    var request = http_parser.parseHttpRequest(allocator, request_data) catch |err| {
        logger.err("Failed to parse HTTP request: {}", .{err});
        try sendErrorResponse(connection.stream, allocator, 400, "Bad Request");
        return;
    };
    defer request.deinit();
    
    logger.info("{s} {s} - Processing request", .{ request.method.toString(), request.path });
    
    // Route the request
    try routeRequest(connection.stream, allocator, &request);
}

fn routeRequest(writer: anytype, allocator: std.mem.Allocator, request: *http_parser.HttpRequest) !void {
    // Handle CORS preflight requests
    if (request.method == .OPTIONS) {
        try handleCors(writer, allocator);
        return;
    }
    
    // Route based on path
    if (std.mem.eql(u8, request.path, "/health")) {
        try handleHealth(writer, allocator);
    } else if (std.mem.eql(u8, request.path, "/v1/models")) {
        try handleModels(writer, allocator);
    } else if (std.mem.eql(u8, request.path, "/v1/chat/completions")) {
        try handleChatCompletions(writer, allocator, request);
    } else if (std.mem.eql(u8, request.path, "/v1/completions")) {
        try handleCompletions(writer, allocator, request);
    } else {
        try sendErrorResponse(writer, allocator, 404, "Not Found");
    }
}

fn handleCors(writer: anytype, allocator: std.mem.Allocator) !void {
    const response = try http_parser.createJsonResponse(allocator, 200, "");
    defer allocator.free(response);
    _ = try writer.writeAll(response);
}

fn handleHealth(writer: anytype, allocator: std.mem.Allocator) !void {
    logger.debug("Health check requested", .{});
    
    const json_body = "{\"status\": \"healthy\", \"service\": \"GhostLLM v0.2.0\", \"gpu_enabled\": true}";
    const response = try http_parser.createJsonResponse(allocator, 200, json_body);
    defer allocator.free(response);
    
    _ = try writer.writeAll(response);
    logger.debug("Health response sent", .{});
}

fn handleModels(writer: anytype, allocator: std.mem.Allocator) !void {
    logger.debug("Models list requested", .{});
    
    // Get models from Ollama
    const models_response = ollama.getAvailableModels(allocator) catch |err| {
        logger.err("Failed to get models from Ollama: {}", .{err});
        const fallback = "{\"object\": \"list\", \"data\": [{\"id\": \"llama2\", \"object\": \"model\", \"created\": 1677610602, \"owned_by\": \"ollama\"}]}";
        const response = try http_parser.createJsonResponse(allocator, 200, fallback);
        defer allocator.free(response);
        _ = try writer.writeAll(response);
        return;
    };
    defer allocator.free(models_response);
    
    const response = try http_parser.createJsonResponse(allocator, 200, models_response);
    defer allocator.free(response);
    _ = try writer.writeAll(response);
}

fn handleChatCompletions(writer: anytype, allocator: std.mem.Allocator, request: *http_parser.HttpRequest) !void {
    logger.debug("Chat completion requested", .{});
    
    if (request.body.len == 0) {
        try sendErrorResponse(writer, allocator, 400, "Request body required");
        return;
    }
    
    // Parse the request body as JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, request.body, .{}) catch |err| {
        logger.err("Failed to parse JSON request: {}", .{err});
        try sendErrorResponse(writer, allocator, 400, "Invalid JSON");
        return;
    };
    defer parsed.deinit();
    
    // Extract the model and messages
    const root = parsed.value;
    const model = if (root.object.get("model")) |m| m.string else "llama2";
    const messages_json = root.object.get("messages") orelse {
        try sendErrorResponse(writer, allocator, 400, "Messages field required");
        return;
    };
    
    // Convert JSON messages to ChatMessage structs
    var messages = std.ArrayList(ollama.ChatMessage).init(allocator);
    defer messages.deinit();
    
    for (messages_json.array.items) |msg| {
        const role = msg.object.get("role").?.string;
        const content = msg.object.get("content").?.string;
        try messages.append(ollama.ChatMessage{
            .role = role,
            .content = content,
        });
    }
    
    // Create chat request
    const chat_request = ollama.ChatRequest{
        .model = model,
        .messages = messages.items,
        .temperature = if (root.object.get("temperature")) |t| @as(f32, @floatCast(t.float)) else null,
        .max_tokens = if (root.object.get("max_tokens")) |t| @as(u32, @intCast(t.integer)) else null,
        .stream = if (root.object.get("stream")) |s| s.bool else false,
    };
    
    // Handle the chat completion
    const completion_response = ollama.handleChatCompletion(allocator, chat_request) catch |err| {
        logger.err("Failed to handle chat completion: {}", .{err});
        try sendErrorResponse(writer, allocator, 500, "Internal server error");
        return;
    };
    defer allocator.free(completion_response);
    
    const response = try http_parser.createJsonResponse(allocator, 200, completion_response);
    defer allocator.free(response);
    _ = try writer.writeAll(response);
}

fn handleCompletions(writer: anytype, allocator: std.mem.Allocator, request: *http_parser.HttpRequest) !void {
    logger.debug("Text completion requested", .{});
    
    if (request.body.len == 0) {
        try sendErrorResponse(writer, allocator, 400, "Request body required");
        return;
    }
    
    // Parse the request body
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, request.body, .{}) catch |err| {
        logger.err("Failed to parse JSON request: {}", .{err});
        try sendErrorResponse(writer, allocator, 400, "Invalid JSON");
        return;
    };
    defer parsed.deinit();
    
    const root = parsed.value;
    const model = if (root.object.get("model")) |m| m.string else "llama2";
    const prompt = root.object.get("prompt").?.string;
    
    const completion_request = ollama.CompletionRequest{
        .model = model,
        .prompt = prompt,
        .temperature = if (root.object.get("temperature")) |t| @as(f32, @floatCast(t.float)) else null,
        .max_tokens = if (root.object.get("max_tokens")) |t| @as(u32, @intCast(t.integer)) else null,
        .stream = if (root.object.get("stream")) |s| s.bool else false,
    };
    
    const completion_response = ollama.handleCompletion(allocator, completion_request) catch |err| {
        logger.err("Failed to handle completion: {}", .{err});
        try sendErrorResponse(writer, allocator, 500, "Internal server error");
        return;
    };
    defer allocator.free(completion_response);
    
    const response = try http_parser.createJsonResponse(allocator, 200, completion_response);
    defer allocator.free(response);
    _ = try writer.writeAll(response);
}

fn sendErrorResponse(writer: anytype, allocator: std.mem.Allocator, status_code: u16, message: []const u8) !void {
    const error_json = try std.fmt.allocPrint(allocator, 
        \\{{"error": {{"message": "{s}", "code": {}}}}}
    , .{ message, status_code });
    defer allocator.free(error_json);
    
    const response = try http_parser.createJsonResponse(allocator, status_code, error_json);
    defer allocator.free(response);
    _ = try writer.writeAll(response);
}