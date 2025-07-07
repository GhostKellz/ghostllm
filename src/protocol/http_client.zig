const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return HttpClient{
            .allocator = allocator,
        };
    }
    
    pub fn get(self: HttpClient, url: []const u8) ![]const u8 {
        return self.requestWithHeaders("GET", url, null, &[_]Header{});
    }
    
    pub fn post(self: HttpClient, url: []const u8, body: ?[]const u8) ![]const u8 {
        return self.requestWithHeaders("POST", url, body, &[_]Header{
            .{ .name = "Content-Type", .value = "application/json" },
        });
    }
    
    pub fn requestWithHeaders(self: HttpClient, method: []const u8, url: []const u8, body: ?[]const u8, headers: []const Header) ![]const u8 {
        // Parse URL to extract host, port, and path
        const parsed = try parseUrl(self.allocator, url);
        defer self.allocator.free(parsed.host);
        defer self.allocator.free(parsed.path);
        
        // Create connection
        const address = std.net.Address.resolveIp(parsed.host, parsed.port) catch |err| {
            std.debug.print("Failed to resolve {s}:{}: {}\n", .{ parsed.host, parsed.port, err });
            return err;
        };
        
        const stream = std.net.tcpConnectToAddress(address) catch |err| {
            std.debug.print("Failed to connect to {s}:{}: {}\n", .{ parsed.host, parsed.port, err });
            return err;
        };
        defer stream.close();
        
        // Build HTTP request with headers
        const content_length = if (body) |b| b.len else 0;
        var request_data = std.ArrayList(u8).init(self.allocator);
        defer request_data.deinit();
        
        try request_data.writer().print("{s} {s} HTTP/1.1\r\n", .{ method, parsed.path });
        try request_data.writer().print("Host: {s}\r\n", .{parsed.host});
        try request_data.writer().print("User-Agent: GhostLLM/0.2.0\r\n", .{});
        try request_data.writer().print("Content-Length: {}\r\n", .{content_length});
        try request_data.writer().print("Connection: close\r\n", .{});
        
        // Add custom headers
        for (headers) |header| {
            try request_data.writer().print("{s}: {s}\r\n", .{ header.name, header.value });
        }
        
        try request_data.writer().print("\r\n", .{});
        if (body) |b| {
            try request_data.appendSlice(b);
        }
        
        // Send request
        _ = try stream.writeAll(request_data.items);
        
        // Read response
        var response_buffer: [16384]u8 = undefined;
        const bytes_read = try stream.readAll(&response_buffer);
        const response_data = response_buffer[0..bytes_read];
        
        // Parse HTTP response to extract body
        const body_start = std.mem.indexOf(u8, response_data, "\r\n\r\n");
        if (body_start) |start| {
            const response_body = response_data[start + 4..];
            return try self.allocator.dupe(u8, response_body);
        }
        
        return try self.allocator.dupe(u8, response_data);
    }
};

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(allocator: std.mem.Allocator, url: []const u8) !ParsedUrl {
    // Simple URL parsing - assumes http://host:port/path format
    var remaining = url;
    
    // Skip protocol
    if (std.mem.startsWith(u8, remaining, "http://")) {
        remaining = remaining[7..];
    } else if (std.mem.startsWith(u8, remaining, "https://")) {
        remaining = remaining[8..];
    }
    
    // Find path separator
    const path_start = std.mem.indexOf(u8, remaining, "/") orelse remaining.len;
    const host_port = remaining[0..path_start];
    const path = if (path_start < remaining.len) 
        try allocator.dupe(u8, remaining[path_start..])
    else 
        try allocator.dupe(u8, "/");
    
    // Split host and port
    if (std.mem.indexOf(u8, host_port, ":")) |colon_pos| {
        const host = try allocator.dupe(u8, host_port[0..colon_pos]);
        const port_str = host_port[colon_pos + 1..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch 80;
        
        return ParsedUrl{
            .host = host,
            .port = port,
            .path = path,
        };
    } else {
        const host = try allocator.dupe(u8, host_port);
        return ParsedUrl{
            .host = host,
            .port = 80,
            .path = path,
        };
    }
}

// Helper function for making requests to Ollama
pub fn makeOllamaRequest(allocator: std.mem.Allocator, endpoint: []const u8, body: []const u8) ![]const u8 {
    const client = HttpClient.init(allocator);
    
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:11434{s}", .{endpoint});
    defer allocator.free(url);
    
    return try client.post(url, body);
}