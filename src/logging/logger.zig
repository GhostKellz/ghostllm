const std = @import("std");

pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    
    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
    
    pub fn fromString(level_str: []const u8) LogLevel {
        if (std.mem.eql(u8, level_str, "debug")) return .debug;
        if (std.mem.eql(u8, level_str, "info")) return .info;
        if (std.mem.eql(u8, level_str, "warn")) return .warn;
        if (std.mem.eql(u8, level_str, "error")) return .err;
        return .info; // default
    }
};

pub const Logger = struct {
    level: LogLevel,
    json_format: bool,
    
    pub fn init(level: LogLevel, json_format: bool) Logger {
        return Logger{
            .level = level,
            .json_format = json_format,
        };
    }
    
    pub fn debug(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }
    
    pub fn info(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }
    
    pub fn warn(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }
    
    pub fn err(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }
    
    pub fn log(self: *const Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) return;
        
        const timestamp = std.time.timestamp();
        
        if (self.json_format) {
            self.logJson(level, timestamp, fmt, args);
        } else {
            self.logPlain(level, timestamp, fmt, args);
        }
    }
    
    fn logJson(self: *const Logger, level: LogLevel, timestamp: i64, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        const stdout = std.io.getStdOut().writer();
        
        // Format the message
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        
        const message = std.fmt.allocPrint(allocator, fmt, args) catch "Failed to format message";
        
        stdout.print("{{\"timestamp\":{},\"level\":\"{s}\",\"message\":\"{s}\"}}\n", .{
            timestamp,
            level.toString(),
            message,
        }) catch {};
    }
    
    fn logPlain(self: *const Logger, level: LogLevel, timestamp: i64, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        const stdout = std.io.getStdOut().writer();
        
        // Convert timestamp to readable format (simplified)
        const hours = @mod(@divTrunc(timestamp, 3600), 24);
        const minutes = @mod(@divTrunc(timestamp, 60), 60);
        const seconds = @mod(timestamp, 60);
        
        stdout.print("[{:02}:{:02}:{:02}] [{s}] ", .{ hours, minutes, seconds, level.toString() }) catch {};
        stdout.print(fmt, args) catch {};
        stdout.print("\n", .{}) catch {};
    }
    
    pub fn logRequest(self: *const Logger, method: []const u8, path: []const u8, status: u16, duration_ms: f64) void {
        if (self.json_format) {
            const timestamp = std.time.timestamp();
            const stdout = std.io.getStdOut().writer();
            stdout.print("{{\"timestamp\":{},\"level\":\"INFO\",\"type\":\"request\",\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{},\"duration_ms\":{d:.2}}}\n", .{
                timestamp, method, path, status, duration_ms
            }) catch {};
        } else {
            self.info("{s} {s} -> {} ({d:.2}ms)", .{ method, path, status, duration_ms });
        }
    }
};

// Global logger instance
var global_logger: Logger = Logger.init(.info, false);

pub fn init(level: LogLevel, json_format: bool) void {
    global_logger = Logger.init(level, json_format);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    global_logger.debug(fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    global_logger.info(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    global_logger.warn(fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    global_logger.err(fmt, args);
}

pub fn logRequest(method: []const u8, path: []const u8, status: u16, duration_ms: f64) void {
    global_logger.logRequest(method, path, status, duration_ms);
}
