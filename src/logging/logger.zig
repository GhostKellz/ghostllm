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
        
        // Use debug.print to avoid IO API issues
        std.debug.print("{{\"timestamp\":{},\"level\":\"{s}\",\"message\":\"", .{
            timestamp,
            level.toString(),
        });
        std.debug.print(fmt, args);
        std.debug.print("\"}}\n", .{});
    }
    
    fn logPlain(self: *const Logger, level: LogLevel, timestamp: i64, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        
        // Convert timestamp to readable format (simplified)
        const hours = @mod(@divTrunc(timestamp, 3600), 24);
        const minutes = @mod(@divTrunc(timestamp, 60), 60);
        const seconds = @mod(timestamp, 60);
        
        std.debug.print("[{:02}:{:02}:{:02}] [{s}] ", .{ hours, minutes, seconds, level.toString() });
        std.debug.print(fmt, args);
        std.debug.print("\n", .{});
    }
    
    pub fn logRequest(self: *const Logger, method: []const u8, path: []const u8, status: u16, duration_ms: f64) void {
        if (self.json_format) {
            const timestamp = std.time.timestamp();
            std.debug.print("{{\"timestamp\":{},\"level\":\"INFO\",\"type\":\"request\",\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{},\"duration_ms\":{d:.2}}}\n", .{
                timestamp, method, path, status, duration_ms
            });
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
