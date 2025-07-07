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
    
    std.debug.print("GhostLLM v0.2.0 server listening on http://127.0.0.1:{}\n", .{cfg.port});
    
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
    
    std.debug.print("handleConnection: Starting\n", .{});
    
    var buffer: [8192]u8 = undefined;
    const bytes_read = try connection.stream.read(&buffer);
    
    const request_data = buffer[0..bytes_read];
    std.debug.print("Received request: {s}\n", .{request_data[0..@min(200, request_data.len)]});
    
    // Simple routing based on path detection
    if (std.mem.indexOf(u8, request_data, "GET /health")) |_| {
        handleHealth(connection.stream) catch |err| {
            std.debug.print("Error in handleHealth: {}\n", .{err});
            return;
        };
    } else if (std.mem.indexOf(u8, request_data, "POST /v1/chat/completions")) |_| {
        handleChatCompletions(connection.stream) catch |err| {
            std.debug.print("Error in handleChatCompletions: {}\n", .{err});
            return;
        };
    } else if (std.mem.indexOf(u8, request_data, "GET /v1/models")) |_| {
        handleModels(connection.stream) catch |err| {
            std.debug.print("Error in handleModels: {}\n", .{err});
            return;
        };
    } else if (std.mem.indexOf(u8, request_data, "POST /v1/completions")) |_| {
        handleCompletions(connection.stream) catch |err| {
            std.debug.print("Error in handleCompletions: {}\n", .{err});
            return;
        };
    } else {
        sendErrorResponse(connection.stream, 404, "Not Found") catch |err| {
            std.debug.print("Error in sendErrorResponse: {}\n", .{err});
            return;
        };
    }
    
    std.debug.print("handleConnection: Request handled successfully\n", .{});
}

fn handleHealth(writer: anytype) !void {
    std.debug.print("handleHealth: Starting\n", .{});
    
    const json_body = "{\"status\": \"healthy\", \"service\": \"GhostLLM v0.2.0\", \"gpu_enabled\": true}";
    
    // Write status line
    _ = try writer.writeAll("HTTP/1.1 200 OK\r\n");
    _ = try writer.writeAll("Content-Type: application/json\r\n");
    _ = try writer.writeAll("Content-Length: 72\r\n");
    _ = try writer.writeAll("Connection: close\r\n");
    _ = try writer.writeAll("\r\n");
    _ = try writer.writeAll(json_body);
    
    std.debug.print("handleHealth: Response written\n", .{});
}

fn handleChatCompletions(writer: anytype) !void {
    const json_body = "{\"id\": \"chatcmpl-123\", \"object\": \"chat.completion\", \"created\": 1677652288, \"model\": \"llama2\", \"choices\": [{\"message\": {\"role\": \"assistant\", \"content\": \"Hello! How can I help you today?\"}, \"finish_reason\": \"stop\", \"index\": 0}]}";
    
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 227\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    
    _ = try writer.writeAll(response);
    _ = try writer.writeAll(json_body);
}

fn handleModels(writer: anytype) !void {
    const json_body = "{\"object\": \"list\", \"data\": [{\"id\": \"llama2\", \"object\": \"model\", \"created\": 1677610602, \"owned_by\": \"ollama\"}]}";
    
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 110\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    
    _ = try writer.writeAll(response);
    _ = try writer.writeAll(json_body);
}

fn handleCompletions(writer: anytype) !void {
    const json_body = "{\"id\": \"cmpl-123\", \"object\": \"text_completion\", \"created\": 1677652288, \"model\": \"text-davinci-003\", \"choices\": [{\"text\": \" response\", \"finish_reason\": \"stop\", \"index\": 0}]}";
    
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 172\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    
    _ = try writer.writeAll(response);
    _ = try writer.writeAll(json_body);
}

fn sendErrorResponse(writer: anytype, status_code: u16, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const error_body = try std.fmt.allocPrint(allocator, 
        \\{{"error": "{s}"}}
    , .{message});
    
    const response = try std.fmt.allocPrint(allocator,
        "HTTP/1.1 {d} {s}\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "{s}"
    , .{ status_code, getStatusText(status_code), error_body.len, error_body });
    
    _ = try writer.writeAll(response);
}

fn getStatusText(status_code: u16) []const u8 {
    return switch (status_code) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        else => "Unknown",
    };
}