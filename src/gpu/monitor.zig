const std = @import("std");

pub const GpuInfo = struct {
    name: []const u8,
    memory_total: u64,
    memory_used: u64,
    memory_free: u64,
    utilization: f32,
    temperature: f32,
    power_draw: f32,
    driver_version: []const u8,
    cuda_version: []const u8,
};

pub const GpuStats = struct {
    gpu_count: u32,
    gpus: []GpuInfo,
    cuda_available: bool,
    nvml_available: bool,
};

pub fn detectGpus(allocator: std.mem.Allocator) !GpuStats {
    // Try to detect NVIDIA GPUs first
    if (detectNvidiaGpus(allocator)) |nvidia_stats| {
        return nvidia_stats;
    } else |_| {}
    
    // Try to detect AMD GPUs
    if (detectAmdGpus(allocator)) |amd_stats| {
        return amd_stats;
    } else |_| {}
    
    // Try to detect Intel GPUs
    if (detectIntelGpus(allocator)) |intel_stats| {
        return intel_stats;
    } else |_| {}
    
    // No GPUs detected
    return GpuStats{
        .gpu_count = 0,
        .gpus = &[_]GpuInfo{},
        .cuda_available = false,
        .nvml_available = false,
    };
}

fn detectNvidiaGpus(allocator: std.mem.Allocator) !GpuStats {
    // Try to run nvidia-smi command
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "nvidia-smi", "--query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu,power.draw,driver_version", "--format=csv,noheader,nounits" },
    }) catch {
        return error.NvidiaNotAvailable;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term.Exited != 0) {
        return error.NvidiaNotAvailable;
    }
    
    var gpu_list = std.ArrayList(GpuInfo).init(allocator);
    defer gpu_list.deinit();
    
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        
        var fields = std.mem.splitSequence(u8, line, ", ");
        const name = fields.next() orelse continue;
        const memory_total_str = fields.next() orelse continue;
        const memory_used_str = fields.next() orelse continue;
        const memory_free_str = fields.next() orelse continue;
        const utilization_str = fields.next() orelse continue;
        const temperature_str = fields.next() orelse continue;
        const power_draw_str = fields.next() orelse continue;
        const driver_version = fields.next() orelse continue;
        
        const gpu_info = GpuInfo{
            .name = try allocator.dupe(u8, name),
            .memory_total = std.fmt.parseInt(u64, memory_total_str, 10) catch 0,
            .memory_used = std.fmt.parseInt(u64, memory_used_str, 10) catch 0,
            .memory_free = std.fmt.parseInt(u64, memory_free_str, 10) catch 0,
            .utilization = std.fmt.parseFloat(f32, utilization_str) catch 0.0,
            .temperature = std.fmt.parseFloat(f32, temperature_str) catch 0.0,
            .power_draw = std.fmt.parseFloat(f32, power_draw_str) catch 0.0,
            .driver_version = try allocator.dupe(u8, driver_version),
            .cuda_version = try getCudaVersion(allocator),
        };
        
        try gpu_list.append(gpu_info);
    }
    
    return GpuStats{
        .gpu_count = @intCast(gpu_list.items.len),
        .gpus = try gpu_list.toOwnedSlice(),
        .cuda_available = checkCudaAvailable(),
        .nvml_available = true,
    };
}

fn detectAmdGpus(allocator: std.mem.Allocator) !GpuStats {
    // Try to run rocm-smi command
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "rocm-smi", "--showname", "--showmeminfo", "vram", "--showuse", "--showtemp", "--showpower" },
    }) catch {
        return error.AmdNotAvailable;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term.Exited != 0) {
        return error.AmdNotAvailable;
    }
    
    // Simplified AMD GPU detection - in real implementation would parse rocm-smi output
    var gpu_list = std.ArrayList(GpuInfo).init(allocator);
    defer gpu_list.deinit();
    
    const gpu_info = GpuInfo{
        .name = try allocator.dupe(u8, "AMD GPU"),
        .memory_total = 8192, // Placeholder
        .memory_used = 1024,
        .memory_free = 7168,
        .utilization = 0.0,
        .temperature = 65.0,
        .power_draw = 150.0,
        .driver_version = try allocator.dupe(u8, "ROCm"),
        .cuda_version = try allocator.dupe(u8, "N/A"),
    };
    
    try gpu_list.append(gpu_info);
    
    return GpuStats{
        .gpu_count = @intCast(gpu_list.items.len),
        .gpus = try gpu_list.toOwnedSlice(),
        .cuda_available = false,
        .nvml_available = false,
    };
}

fn detectIntelGpus(_: std.mem.Allocator) !GpuStats {
    // Try to detect Intel GPUs through system info
    // This is a simplified implementation
    return error.IntelNotAvailable;
}

fn getCudaVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "nvidia-smi", "--query-gpu=cuda_version", "--format=csv,noheader" },
    }) catch {
        return allocator.dupe(u8, "Unknown");
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term.Exited == 0 and result.stdout.len > 0) {
        const version = std.mem.trim(u8, result.stdout, " \n\r");
        return allocator.dupe(u8, version);
    }
    
    return allocator.dupe(u8, "Unknown");
}

fn checkCudaAvailable() bool {
    // Simple check for CUDA availability
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "nvidia-smi", "-L" },
    }) catch {
        return false;
    };
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    
    return result.term.Exited == 0;
}

pub fn printGpuStats(stats: GpuStats) void {
    std.debug.print("=== GPU Information ===\n", .{});
    std.debug.print("GPU Count: {}\n", .{stats.gpu_count});
    std.debug.print("CUDA Available: {}\n", .{stats.cuda_available});
    std.debug.print("NVML Available: {}\n", .{stats.nvml_available});
    std.debug.print("\n", .{});
    
    for (stats.gpus, 0..) |gpu, i| {
        std.debug.print("GPU {}:\n", .{i});
        std.debug.print("  Name: {s}\n", .{gpu.name});
        std.debug.print("  Memory Total: {} MB\n", .{gpu.memory_total});
        std.debug.print("  Memory Used: {} MB\n", .{gpu.memory_used});
        std.debug.print("  Memory Free: {} MB\n", .{gpu.memory_free});
        std.debug.print("  Utilization: {d:.1}%\n", .{gpu.utilization});
        std.debug.print("  Temperature: {d:.1}°C\n", .{gpu.temperature});
        std.debug.print("  Power Draw: {d:.1}W\n", .{gpu.power_draw});
        std.debug.print("  Driver Version: {s}\n", .{gpu.driver_version});
        std.debug.print("  CUDA Version: {s}\n", .{gpu.cuda_version});
        std.debug.print("\n", .{});
    }
}

pub fn getGpuUtilization(allocator: std.mem.Allocator) !f32 {
    const stats = try detectGpus(allocator);
    defer {
        for (stats.gpus) |gpu| {
            allocator.free(gpu.name);
            allocator.free(gpu.driver_version);
            allocator.free(gpu.cuda_version);
        }
        allocator.free(stats.gpus);
    }
    
    if (stats.gpu_count == 0) return 0.0;
    
    var total_utilization: f32 = 0.0;
    for (stats.gpus) |gpu| {
        total_utilization += gpu.utilization;
    }
    
    return total_utilization / @as(f32, @floatFromInt(stats.gpu_count));
}

pub fn getGpuMemoryUsage(allocator: std.mem.Allocator) !struct { used: u64, total: u64 } {
    const stats = try detectGpus(allocator);
    defer {
        for (stats.gpus) |gpu| {
            allocator.free(gpu.name);
            allocator.free(gpu.driver_version);
            allocator.free(gpu.cuda_version);
        }
        allocator.free(stats.gpus);
    }
    
    if (stats.gpu_count == 0) return .{ .used = 0, .total = 0 };
    
    var total_used: u64 = 0;
    var total_memory: u64 = 0;
    
    for (stats.gpus) |gpu| {
        total_used += gpu.memory_used;
        total_memory += gpu.memory_total;
    }
    
    return .{ .used = total_used, .total = total_memory };
}