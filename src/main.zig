const std = @import("std");
const ghostllm = @import("ghostllm");

const Mode = enum {
    serve,
    bench,
    inspect,
    ghost,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const mode_str = args[1];
    const mode = std.meta.stringToEnum(Mode, mode_str) orelse {
        std.debug.print("Unknown mode: {s}\n", .{mode_str});
        try printUsage();
        return;
    };

    switch (mode) {
        .serve => try runServeMode(),
        .bench => try runBenchMode(),
        .inspect => try runInspectMode(),
        .ghost => try runGhostMode(),
    }
}

fn printUsage() !void {
    std.debug.print(
        "GhostLLM v0.2.0 - GPU-Accelerated AI Proxy\n" ++
        "\n" ++
        "Usage: ghostllm <mode> [options]\n" ++
        "\n" ++
        "Modes:\n" ++
        "  serve    Start QUIC-native LLM serving API\n" ++
        "  bench    Benchmark GPU inference & latency\n" ++
        "  inspect  Show GPU stats, model memory, and throughput\n" ++
        "  ghost    Smart contract-aware inferencing layer\n" ++
        "\n", .{});
}

fn runServeMode() !void {
    std.debug.print("Starting GhostLLM serve mode...\n", .{});
    try ghostllm.startServer();
}

fn runBenchMode() !void {
    std.debug.print("Running GhostLLM benchmarks...\n", .{});
    try ghostllm.runBenchmarks();
}

fn runInspectMode() !void {
    std.debug.print("Inspecting GPU and system stats...\n", .{});
    try ghostllm.inspectSystem();
}

fn runGhostMode() !void {
    std.debug.print("Starting GhostChain-aware inference mode...\n", .{});
    try ghostllm.startGhostMode();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
