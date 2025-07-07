const std = @import("std");

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    
    pub fn fromString(method_str: []const u8) !HttpMethod {
        if (std.mem.eql(u8, method_str, "GET")) return .GET;
        if (std.mem.eql(u8, method_str, "POST")) return .POST;
        if (std.mem.eql(u8, method_str, "PUT")) return .PUT;
        if (std.mem.eql(u8, method_str, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, method_str, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, method_str, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, method_str, "OPTIONS")) return .OPTIONS;
        return error.UnknownMethod;
    }
    
    pub fn toString(self: HttpMethod) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }
};

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    version: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    
    pub fn init(allocator: std.mem.Allocator) HttpRequest {
        return HttpRequest{
            .method = .GET,
            .path = "/",
            .version = "HTTP/1.1",
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = "",
        };
    }
    
    pub fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
    }
    
    pub fn getHeader(self: *const HttpRequest, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }
    
    pub fn getContentType(self: *const HttpRequest) ?[]const u8 {
        return self.getHeader("content-type") orelse self.getHeader("Content-Type");
    }
    
    pub fn getContentLength(self: *const HttpRequest) ?usize {
        if (self.getHeader("content-length") orelse self.getHeader("Content-Length")) |length_str| {
            return std.fmt.parseInt(usize, length_str, 10) catch null;
        }
        return null;
    }
};

pub const HttpResponse = struct {
    status_code: u16,
    status_text: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, status_code: u16, body: []const u8) HttpResponse {
        const status_text = getStatusText(status_code);
        const response = HttpResponse{
            .status_code = status_code,
            .status_text = status_text,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = body,
        };
        
        return response;
    }
    
    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
    }
    
    pub fn setHeader(self: *HttpResponse, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }
    
    pub fn setContentType(self: *HttpResponse, content_type: []const u8) !void {
        try self.setHeader("Content-Type", content_type);
    }
    
    pub fn setCORS(self: *HttpResponse) !void {
        try self.setHeader("Access-Control-Allow-Origin", "*");
        try self.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        try self.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
    }
    
    pub fn toBytes(self: *const HttpResponse, allocator: std.mem.Allocator) ![]const u8 {
        var response_data = std.ArrayList(u8).init(allocator);
        defer response_data.deinit();
        
        // Status line
        try response_data.writer().print("HTTP/1.1 {} {s}\r\n", .{ self.status_code, self.status_text });
        
        // Default headers
        try response_data.writer().print("Content-Length: {}\r\n", .{self.body.len});
        try response_data.writer().print("Server: GhostLLM/0.2.0\r\n", .{});
        
        // Custom headers
        var iterator = self.headers.iterator();
        while (iterator.next()) |entry| {
            try response_data.writer().print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        
        // Empty line and body
        try response_data.writer().print("\r\n", .{});
        try response_data.appendSlice(self.body);
        
        return try allocator.dupe(u8, response_data.items);
    }
};

pub fn parseHttpRequest(allocator: std.mem.Allocator, raw_data: []const u8) !HttpRequest {
    var request = HttpRequest.init(allocator);
    
    // Split into lines
    var lines = std.mem.splitSequence(u8, raw_data, "\r\n");
    
    // Parse request line
    if (lines.next()) |request_line| {
        var parts = std.mem.splitScalar(u8, request_line, ' ');
        
        if (parts.next()) |method_str| {
            request.method = HttpMethod.fromString(method_str) catch .GET;
        }
        
        if (parts.next()) |path| {
            request.path = path;
        }
        
        if (parts.next()) |version| {
            request.version = version;
        }
    }
    
    // Parse headers
    while (lines.next()) |line| {
        if (line.len == 0) break; // Empty line indicates end of headers
        
        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
            const header_name = std.mem.trim(u8, line[0..colon_pos], " \t");
            const header_value = std.mem.trim(u8, line[colon_pos + 1..], " \t");
            try request.headers.put(header_name, header_value);
        }
    }
    
    // Parse body (rest of the data)
    const headers_end = std.mem.indexOf(u8, raw_data, "\r\n\r\n");
    if (headers_end) |end| {
        request.body = raw_data[end + 4..];
    } else {
        request.body = "";
    }
    
    return request;
}

fn getStatusText(status_code: u16) []const u8 {
    return switch (status_code) {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}
