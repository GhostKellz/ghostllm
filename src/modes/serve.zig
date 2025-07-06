const std = @import("std");
const config = @import("../config/config.zig");

pub fn startServer() !void {
    const cfg = config.getConfig();
    const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, cfg.port);
    var server = address.listen(.{}) catch |err| {
        std.debug.print("Failed to bind to port {}: {}\n", .{ cfg.port, err });
        return;
    };
    defer server.deinit();
    
    std.debug.print("GhostLLM HTTP server listening on http://127.0.0.1:{}\n", .{cfg.port});
    
    while (true) {
        const connection = server.accept() catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        
        handleConnection(connection) catch |err| {
            std.debug.print("Error handling connection: {}\n", .{err});
        };
    }
}

fn handleConnection(connection: std.net.Server.Connection) !void {
    defer connection.stream.close();
    
    var buffer: [8192]u8 = undefined;
    const bytes_read = try connection.stream.readAll(&buffer);
    
    const request_data = buffer[0..bytes_read];
    std.debug.print("Received request: {s}\n", .{request_data[0..@min(100, request_data.len)]});
    
    // Simple routing based on path detection
    if (std.mem.indexOf(u8, request_data, "GET /health")) |_| {
        try handleHealth(connection.stream);
    } else if (std.mem.indexOf(u8, request_data, "POST /v1/chat/completions")) |_| {
        try handleChatCompletions(connection.stream);
    } else if (std.mem.indexOf(u8, request_data, "GET /v1/models")) |_| {
        try handleModels(connection.stream);
    } else if (std.mem.indexOf(u8, request_data, "POST /v1/completions")) |_| {
        try handleCompletions(connection.stream);
    } else {
        try sendErrorResponse(connection.stream, 404, "Not Found");
    }
}

fn handleHealth(writer: anytype) !void {
    const response =
        \\HTTP/1.1 200 OK
        \\Content-Type: application/json
        \\Content-Length: 47
        \\
        \\{"status": "healthy", "service": "GhostLLM v0.1.0"}
    ;
    
    _ = try writer.writeAll(response);
}

fn handleChatCompletions(writer: anytype) !void {
    const response =
        \\HTTP/1.1 200 OK
        \\Content-Type: application/json
        \\Content-Length: 150
        \\
        \\{"id": "chatcmpl-123", "object": "chat.completion", "created": 1677652288, "model": "gpt-3.5-turbo", "choices": [{"message": {"role": "assistant", "content": "Hello! How can I help you today?"}, "finish_reason": "stop", "index": 0}]}
    ;
    
    _ = try writer.writeAll(response);
}

fn handleModels(writer: anytype) !void {
    const response =
        \\HTTP/1.1 200 OK
        \\Content-Type: application/json
        \\Content-Length: 85
        \\
        \\{"object": "list", "data": [{"id": "llama2", "object": "model", "created": 1677610602, "owned_by": "ollama"}]}
    ;
    
    _ = try writer.writeAll(response);
}

fn handleCompletions(writer: anytype) !void {
    const response =
        \\HTTP/1.1 200 OK
        \\Content-Type: application/json
        \\Content-Length: 140
        \\
        \\{"id": "cmpl-123", "object": "text_completion", "created": 1677652288, "model": "text-davinci-003", "choices": [{"text": " response", "finish_reason": "stop", "index": 0}]}
    ;
    
    _ = try writer.writeAll(response);
}

fn sendErrorResponse(writer: anytype, status_code: u16, message: []const u8) !void {
    const response = try std.fmt.allocPrint(std.heap.page_allocator,
        \\HTTP/1.1 {d} {s}
        \\Content-Type: application/json
        \\Content-Length: {d}
        \\
        \\{{"error": "{s}"}}
    , .{ status_code, message, message.len + 12, message });
    defer std.heap.page_allocator.free(response);
    
    _ = try writer.writeAll(response);
}