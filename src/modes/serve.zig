const std = @import("std");
const config = @import("../config/config.zig");
const logger = @import("../logging/logger.zig");
const http_parser = @import("../protocol/http_parser.zig");
const ollama = @import("../llm/ollama.zig");
const providers = @import("../llm/providers.zig");
const zeke = @import("../llm/zeke.zig");

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
    } else if (std.mem.startsWith(u8, request.path, "/v1/zeke/")) {
        try handleZekeEndpoints(writer, allocator, request);
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
    
    // Get models from all providers
    const models_response = providers.getAllAvailableModels(allocator) catch |err| {
        logger.err("Failed to get models: {}", .{err});
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
    var messages = std.ArrayList(providers.ChatMessage).init(allocator);
    defer messages.deinit();
    
    for (messages_json.array.items) |msg| {
        const role = msg.object.get("role").?.string;
        const content = msg.object.get("content").?.string;
        try messages.append(providers.ChatMessage{
            .role = role,
            .content = content,
        });
    }
    
    // Create chat request for the provider router
    const chat_request = providers.ChatRequest{
        .model = model,
        .messages = messages.items,
        .temperature = if (root.object.get("temperature")) |t| @as(f32, @floatCast(t.float)) else null,
        .max_tokens = if (root.object.get("max_tokens")) |t| @as(u32, @intCast(t.integer)) else null,
        .stream = if (root.object.get("stream")) |s| s.bool else false,
    };
    
    // Route to appropriate provider
    const completion_response = providers.routeRequest(allocator, chat_request) catch |err| {
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

/// Handle Zeke-specific AI development endpoints
fn handleZekeEndpoints(writer: anytype, allocator: std.mem.Allocator, request: *http_parser.HttpRequest) !void {
    const path = request.path;
    
    if (std.mem.eql(u8, path, "/v1/zeke/code/complete")) {
        if (request.method != .POST) {
            try sendErrorResponse(writer, allocator, 405, "Method Not Allowed");
            return;
        }
        
        if (request.body.len == 0) {
            try sendErrorResponse(writer, allocator, 400, "Request body required");
            return;
        }
        
        // Parse JSON request body
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, request.body, .{}) catch |err| {
            logger.err("Failed to parse JSON request: {}", .{err});
            try sendErrorResponse(writer, allocator, 400, "Invalid JSON");
            return;
        };
        defer parsed.deinit();
        
        const root = parsed.value;
        const zeke_request = zeke.ZekeRequest{
            .code = if (root.object.get("code")) |c| c.string else null,
            .context = if (root.object.get("context")) |c| c.string else null,
            .language = if (root.object.get("language")) |l| l.string else null,
            .task = if (root.object.get("task")) |t| t.string else "complete",
            .model = if (root.object.get("model")) |m| m.string else null,
        };
        
        const response_data = try zeke.handleCodeCompletion(allocator, zeke_request);
        defer allocator.free(response_data);
        
        const response = try http_parser.createJsonResponse(allocator, 200, response_data);
        defer allocator.free(response);
        _ = try writer.writeAll(response);
        
    } else if (std.mem.eql(u8, path, "/v1/zeke/code/analyze")) {
        if (request.method != .POST) {
            try sendErrorResponse(writer, allocator, 405, "Method Not Allowed");
            return;
        }
        
        if (request.body.len == 0) {
            try sendErrorResponse(writer, allocator, 400, "Request body required");
            return;
        }
        
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, request.body, .{}) catch |err| {
            logger.err("Failed to parse JSON request: {}", .{err});
            try sendErrorResponse(writer, allocator, 400, "Invalid JSON");
            return;
        };
        defer parsed.deinit();
        
        const root = parsed.value;
        const zeke_request = zeke.ZekeRequest{
            .code = if (root.object.get("code")) |c| c.string else null,
            .context = if (root.object.get("context")) |c| c.string else null,
            .language = if (root.object.get("language")) |l| l.string else null,
            .task = if (root.object.get("task")) |t| t.string else "analyze",
            .model = if (root.object.get("model")) |m| m.string else null,
        };
        
        const response_data = try zeke.handleCodeAnalysis(allocator, zeke_request);
        defer allocator.free(response_data);
        
        const response = try http_parser.createJsonResponse(allocator, 200, response_data);
        defer allocator.free(response);
        _ = try writer.writeAll(response);
        
    } else if (std.mem.eql(u8, path, "/v1/zeke/code/explain")) {
        if (request.method != .POST) {
            try sendErrorResponse(writer, allocator, 405, "Method Not Allowed");
            return;
        }
        
        if (request.body.len == 0) {
            try sendErrorResponse(writer, allocator, 400, "Request body required");
            return;
        }
        
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, request.body, .{}) catch |err| {
            logger.err("Failed to parse JSON request: {}", .{err});
            try sendErrorResponse(writer, allocator, 400, "Invalid JSON");
            return;
        };
        defer parsed.deinit();
        
        const root = parsed.value;
        const zeke_request = zeke.ZekeRequest{
            .code = if (root.object.get("code")) |c| c.string else null,
            .context = if (root.object.get("context")) |c| c.string else null,
            .language = if (root.object.get("language")) |l| l.string else null,
            .task = if (root.object.get("task")) |t| t.string else "explain",
            .model = if (root.object.get("model")) |m| m.string else null,
        };
        
        const response_data = try zeke.handleCodeExplanation(allocator, zeke_request);
        defer allocator.free(response_data);
        
        const response = try http_parser.createJsonResponse(allocator, 200, response_data);
        defer allocator.free(response);
        _ = try writer.writeAll(response);
        
    } else if (std.mem.eql(u8, path, "/v1/zeke/code/refactor")) {
        if (request.method != .POST) {
            try sendErrorResponse(writer, allocator, 405, "Method Not Allowed");
            return;
        }
        
        if (request.body.len == 0) {
            try sendErrorResponse(writer, allocator, 400, "Request body required");
            return;
        }
        
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, request.body, .{}) catch |err| {
            logger.err("Failed to parse JSON request: {}", .{err});
            try sendErrorResponse(writer, allocator, 400, "Invalid JSON");
            return;
        };
        defer parsed.deinit();
        
        const root = parsed.value;
        const zeke_request = zeke.ZekeRequest{
            .code = if (root.object.get("code")) |c| c.string else null,
            .context = if (root.object.get("context")) |c| c.string else null,
            .language = if (root.object.get("language")) |l| l.string else null,
            .task = if (root.object.get("task")) |t| t.string else "refactor",
            .model = if (root.object.get("model")) |m| m.string else null,
        };
        
        const response_data = try zeke.handleCodeRefactoring(allocator, zeke_request);
        defer allocator.free(response_data);
        
        const response = try http_parser.createJsonResponse(allocator, 200, response_data);
        defer allocator.free(response);
        _ = try writer.writeAll(response);
        
    } else if (std.mem.eql(u8, path, "/v1/zeke/code/test")) {
        if (request.method != .POST) {
            try sendErrorResponse(writer, allocator, 405, "Method Not Allowed");
            return;
        }
        
        if (request.body.len == 0) {
            try sendErrorResponse(writer, allocator, 400, "Request body required");
            return;
        }
        
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, request.body, .{}) catch |err| {
            logger.err("Failed to parse JSON request: {}", .{err});
            try sendErrorResponse(writer, allocator, 400, "Invalid JSON");
            return;
        };
        defer parsed.deinit();
        
        const root = parsed.value;
        const zeke_request = zeke.ZekeRequest{
            .code = if (root.object.get("code")) |c| c.string else null,
            .context = if (root.object.get("context")) |c| c.string else null,
            .language = if (root.object.get("language")) |l| l.string else null,
            .task = if (root.object.get("task")) |t| t.string else "test",
            .model = if (root.object.get("model")) |m| m.string else null,
        };
        
        const response_data = try zeke.handleTestGeneration(allocator, zeke_request);
        defer allocator.free(response_data);
        
        const response = try http_parser.createJsonResponse(allocator, 200, response_data);
        defer allocator.free(response);
        _ = try writer.writeAll(response);
        
    } else if (std.mem.eql(u8, path, "/v1/zeke/terminal/assist")) {
        if (request.method != .POST) {
            try sendErrorResponse(writer, allocator, 405, "Method Not Allowed");
            return;
        }
        
        if (request.body.len == 0) {
            try sendErrorResponse(writer, allocator, 400, "Request body required");
            return;
        }
        
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, request.body, .{}) catch |err| {
            logger.err("Failed to parse JSON request: {}", .{err});
            try sendErrorResponse(writer, allocator, 400, "Invalid JSON");
            return;
        };
        defer parsed.deinit();
        
        const root = parsed.value;
        const zeke_request = zeke.ZekeRequest{
            .code = if (root.object.get("command")) |c| c.string else null,
            .context = if (root.object.get("context")) |c| c.string else null,
            .language = if (root.object.get("shell")) |l| l.string else null,
            .task = if (root.object.get("task")) |t| t.string else "terminal",
            .model = if (root.object.get("model")) |m| m.string else null,
        };
        
        const response_data = try zeke.handleTerminalAssistance(allocator, zeke_request);
        defer allocator.free(response_data);
        
        const response = try http_parser.createJsonResponse(allocator, 200, response_data);
        defer allocator.free(response);
        _ = try writer.writeAll(response);
        
    } else if (std.mem.eql(u8, path, "/v1/zeke/project/analyze")) {
        if (request.method != .POST) {
            try sendErrorResponse(writer, allocator, 405, "Method Not Allowed");
            return;
        }
        
        if (request.body.len == 0) {
            try sendErrorResponse(writer, allocator, 400, "Request body required");
            return;
        }
        
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, request.body, .{}) catch |err| {
            logger.err("Failed to parse JSON request: {}", .{err});
            try sendErrorResponse(writer, allocator, 400, "Invalid JSON");
            return;
        };
        defer parsed.deinit();
        
        const root = parsed.value;
        const zeke_request = zeke.ZekeRequest{
            .code = if (root.object.get("project_path")) |c| c.string else null,
            .context = if (root.object.get("context")) |c| c.string else null,
            .language = if (root.object.get("language")) |l| l.string else null,
            .task = if (root.object.get("task")) |t| t.string else "project_analyze",
            .model = if (root.object.get("model")) |m| m.string else null,
        };
        
        const response_data = try zeke.handleProjectAnalysis(allocator, zeke_request);
        defer allocator.free(response_data);
        
        const response = try http_parser.createJsonResponse(allocator, 200, response_data);
        defer allocator.free(response);
        _ = try writer.writeAll(response);
        
    } else {
        try sendErrorResponse(writer, allocator, 404, "Zeke endpoint not found");
    }
}