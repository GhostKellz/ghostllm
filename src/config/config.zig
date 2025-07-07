const std = @import("std");
const logger = @import("../logging/logger.zig");

pub const Config = struct {
    port: u16 = 8080,
    ollama_host: []const u8 = "127.0.0.1",
    ollama_port: u16 = 11434,
    log_level: LogLevel = .info,
    log_json: bool = false,
    max_connections: u32 = 100,
    request_timeout: u32 = 30,
    gpu_enabled: bool = false,
    metrics_enabled: bool = true,
    cors_enabled: bool = true,
    auth_enabled: bool = false,
    api_key: ?[]const u8 = null,
};

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
    
    pub fn toLoggerLevel(self: LogLevel) logger.LogLevel {
        return switch (self) {
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err => .err,
        };
    }
};

var global_config: Config = .{};

pub fn getConfig() Config {
    return global_config;
}

pub fn setConfig(config: Config) void {
    global_config = config;
}

pub fn loadFromEnv() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    if (std.process.getEnvVarOwned(allocator, "GHOSTLLM_PORT")) |port_str| {
        defer allocator.free(port_str);
        global_config.port = std.fmt.parseInt(u16, port_str, 10) catch global_config.port;
    } else |_| {}
    
    if (std.process.getEnvVarOwned(allocator, "GHOSTLLM_OLLAMA_HOST")) |host| {
        defer allocator.free(host);
        // Note: In real implementation, we'd need to handle string allocation properly
        global_config.ollama_host = "127.0.0.1"; // Simplified for now
    } else |_| {}
    
    if (std.process.getEnvVarOwned(allocator, "GHOSTLLM_OLLAMA_PORT")) |port_str| {
        defer allocator.free(port_str);
        global_config.ollama_port = std.fmt.parseInt(u16, port_str, 10) catch global_config.ollama_port;
    } else |_| {}
    
    if (std.process.getEnvVarOwned(allocator, "GHOSTLLM_GPU_ENABLED")) |gpu_str| {
        defer allocator.free(gpu_str);
        global_config.gpu_enabled = std.mem.eql(u8, gpu_str, "true") or std.mem.eql(u8, gpu_str, "1");
    } else |_| {}
    
    if (std.process.getEnvVarOwned(allocator, "GHOSTLLM_LOG_LEVEL")) |level_str| {
        defer allocator.free(level_str);
        global_config.log_level = parseLogLevel(level_str);
    } else |_| {}
    
    if (std.process.getEnvVarOwned(allocator, "GHOSTLLM_LOG_JSON")) |json_str| {
        defer allocator.free(json_str);
        global_config.log_json = std.mem.eql(u8, json_str, "true");
    } else |_| {}
    
    if (std.process.getEnvVarOwned(allocator, "GHOSTLLM_API_KEY")) |api_key| {
        defer allocator.free(api_key);
        // TODO: Store API key securely
        global_config.auth_enabled = api_key.len > 0;
    } else |_| {}
    
    // Initialize logger with config
    logger.init(global_config.log_level.toLoggerLevel(), global_config.log_json);
}

pub fn loadFromFile(file_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Config file not found: {s}, using defaults\n", .{file_path});
            return;
        },
        else => return err,
    };
    defer file.close();
    
    const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);
    
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch |err| {
        std.debug.print("Error parsing config file: {}\n", .{err});
        return;
    };
    defer parsed.deinit();
    
    const root = parsed.value.object;
    
    if (root.get("port")) |port| {
        switch (port) {
            .integer => |p| global_config.port = @intCast(p),
            else => {},
        }
    }
    
    if (root.get("ollama_host")) |host| {
        switch (host) {
            .string => |_| global_config.ollama_host = "127.0.0.1",
            else => {},
        }
    }
    
    if (root.get("ollama_port")) |port| {
        switch (port) {
            .integer => |p| global_config.ollama_port = @intCast(p),
            else => {},
        }
    }
    
    if (root.get("gpu_enabled")) |gpu| {
        switch (gpu) {
            .bool => |g| global_config.gpu_enabled = g,
            else => {},
        }
    }
    
    if (root.get("max_connections")) |max_conn| {
        switch (max_conn) {
            .integer => |mc| global_config.max_connections = @intCast(mc),
            else => {},
        }
    }
    
    if (root.get("log_level")) |level| {
        switch (level) {
            .string => |l| global_config.log_level = parseLogLevel(l),
            else => {},
        }
    }
}

pub fn saveToFile(file_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const config_json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "port": {},
        \\  "ollama_host": "{s}",
        \\  "ollama_port": {},
        \\  "log_level": "{s}",
        \\  "max_connections": {},
        \\  "request_timeout": {},
        \\  "gpu_enabled": {},
        \\  "metrics_enabled": {}
        \\}}
    , .{
        global_config.port,
        global_config.ollama_host,
        global_config.ollama_port,
        @tagName(global_config.log_level),
        global_config.max_connections,
        global_config.request_timeout,
        global_config.gpu_enabled,
        global_config.metrics_enabled,
    });
    defer allocator.free(config_json);
    
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    
    try file.writeAll(config_json);
}

fn parseLogLevel(level_str: []const u8) LogLevel {
    if (std.mem.eql(u8, level_str, "debug")) return .debug;
    if (std.mem.eql(u8, level_str, "info")) return .info;
    if (std.mem.eql(u8, level_str, "warn")) return .warn;
    if (std.mem.eql(u8, level_str, "error")) return .err;
    return .info;
}

pub fn printConfig() void {
    std.debug.print("GhostLLM Configuration:\n", .{});
    std.debug.print("  Port: {}\n", .{global_config.port});
    std.debug.print("  Ollama Host: {s}\n", .{global_config.ollama_host});
    std.debug.print("  Ollama Port: {}\n", .{global_config.ollama_port});
    std.debug.print("  Log Level: {s}\n", .{@tagName(global_config.log_level)});
    std.debug.print("  Max Connections: {}\n", .{global_config.max_connections});
    std.debug.print("  GPU Enabled: {}\n", .{global_config.gpu_enabled});
    std.debug.print("  Metrics Enabled: {}\n", .{global_config.metrics_enabled});
}