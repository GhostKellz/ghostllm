//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const serve_mode = @import("modes/serve.zig");
const gpu_monitor = @import("gpu/monitor.zig");
const config = @import("config/config.zig");

pub fn startServer() !void {
    // Load configuration from environment and files
    try config.loadFromEnv();
    config.loadFromFile("ghostllm.json") catch |err| {
        std.debug.print("Config file not found, using defaults: {}\n", .{err});
    };
    
    try serve_mode.startServer();
}

pub fn runBenchmarks() !void {
    std.debug.print("=== GhostLLM Benchmark Suite ===\n", .{});
    
    // GPU Benchmark
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    std.debug.print("Testing GPU detection and monitoring...\n", .{});
    const gpu_stats = gpu_monitor.detectGpus(allocator) catch |err| {
        std.debug.print("GPU detection failed: {}\n", .{err});
        return runCpuBenchmarks();
    };
    defer {
        for (gpu_stats.gpus) |gpu| {
            allocator.free(gpu.name);
            allocator.free(gpu.driver_version);
            allocator.free(gpu.cuda_version);
        }
        allocator.free(gpu_stats.gpus);
    }
    
    if (gpu_stats.gpu_count > 0) {
        std.debug.print("Found {} GPU(s)\n", .{gpu_stats.gpu_count});
        gpu_monitor.printGpuStats(gpu_stats);
        
        // GPU utilization test
        const utilization = gpu_monitor.getGpuUtilization(allocator) catch 0.0;
        std.debug.print("Average GPU Utilization: {d:.1}%\n", .{utilization});
        
        const memory = gpu_monitor.getGpuMemoryUsage(allocator) catch .{ .used = 0, .total = 0 };
        std.debug.print("GPU Memory Usage: {}/{} MB\n", .{ memory.used, memory.total });
    } else {
        std.debug.print("No GPUs detected, running CPU benchmarks...\n", .{});
        try runCpuBenchmarks();
    }
}

fn runCpuBenchmarks() !void {
    std.debug.print("Testing basic arithmetic performance...\n", .{});
    
    const start = std.time.microTimestamp();
    var sum: i64 = 0;
    var i: i64 = 0;
    while (i < 1000000) : (i += 1) {
        sum += i;
    }
    const end = std.time.microTimestamp();
    
    std.debug.print("Computed sum: {}\n", .{sum});
    std.debug.print("Time taken: {}μs\n", .{end - start});
    std.debug.print("Benchmark complete.\n", .{});
}

pub fn inspectSystem() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    std.debug.print("=== System Inspection ===\n", .{});
    std.debug.print("Platform: linux\n", .{});
    std.debug.print("Architecture: x86_64\n", .{});
    
    // Load and display configuration
    try config.loadFromEnv();
    config.printConfig();
    
    std.debug.print("\n", .{});
    
    // GPU detection and monitoring
    const gpu_stats = gpu_monitor.detectGpus(allocator) catch |err| {
        std.debug.print("GPU detection failed: {}\n", .{err});
        std.debug.print("GPU Status: No GPUs detected\n", .{});
        return;
    };
    defer {
        for (gpu_stats.gpus) |gpu| {
            allocator.free(gpu.name);
            allocator.free(gpu.driver_version);
            allocator.free(gpu.cuda_version);
        }
        allocator.free(gpu_stats.gpus);
    }
    
    gpu_monitor.printGpuStats(gpu_stats);
    
    std.debug.print("Memory: Arena allocator active\n", .{});
}

pub fn startGhostMode() !void {
    std.debug.print("=== GhostChain Integration Mode ===\n", .{});
    std.debug.print("Smart contract hooks: Not implemented\n", .{});
    std.debug.print("ZVM integration: Pending\n", .{});
    std.debug.print("Blockchain state: Disconnected\n", .{});
    std.debug.print("Ghost mode placeholder active.\n", .{});
    
    // Future: Implement GhostChain integration
    // - Smart contract event listening
    // - ZVM runtime integration
    // - Blockchain state synchronization
    // - Decentralized inference coordination
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
