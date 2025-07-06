const std = @import("std");

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return HttpClient{
            .allocator = allocator,
        };
    }
    
    pub fn get(self: HttpClient, url: []const u8) ![]const u8 {
        return self.request("GET", url, null);
    }
    
    pub fn post(self: HttpClient, url: []const u8, body: ?[]const u8) ![]const u8 {
        return self.request("POST", url, body);
    }
    
    pub fn request(self: HttpClient, method: []const u8, url: []const u8, body: ?[]const u8) ![]const u8 {
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
        
        // Build HTTP request
        const content_length = if (body) |b| b.len else 0;
        const request_data = try std.fmt.allocPrint(self.allocator,
            "{s} {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "User-Agent: GhostLLM/0.1.0\r\n" ++
            "Content-Length: {}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{s}",
            .{ method, parsed.path, parsed.host, content_length, body orelse "" }
        );
        defer self.allocator.free(request_data);
        
        // Send request
        _ = try stream.writeAll(request_data);
        
        // Read response
        var response_buffer: [8192]u8 = undefined;
        const bytes_read = try stream.readAll(&response_buffer);
        
        return try self.allocator.dupe(u8, response_buffer[0..bytes_read]);
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