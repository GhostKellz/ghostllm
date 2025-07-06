const std = @import("std");
const http_client = @import("src/protocol/http_client.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const client = http_client.HttpClient.init(allocator);
    
    std.debug.print("Testing GhostLLM API endpoints...\n", .{});
    
    // Test health endpoint
    std.debug.print("\nTesting /health\n", .{});
    const health_response = client.get("http://127.0.0.1:8080/health") catch |err| {
        std.debug.print("Health check failed: {}\n", .{err});
        return;
    };
    defer allocator.free(health_response);
    std.debug.print("Response: {s}\n", .{health_response});
    
    // Test models endpoint
    std.debug.print("\nTesting /v1/models\n", .{});
    const models_response = client.get("http://127.0.0.1:8080/v1/models") catch |err| {
        std.debug.print("Models request failed: {}\n", .{err});
        return;
    };
    defer allocator.free(models_response);
    std.debug.print("Response: {s}\n", .{models_response});
    
    // Test chat completions endpoint
    std.debug.print("\nTesting /v1/chat/completions\n", .{});
    const chat_body = 
        \\{"model": "llama2", "messages": [{"role": "user", "content": "Hello!"}]}
    ;
    const chat_response = client.post("http://127.0.0.1:8080/v1/chat/completions", chat_body) catch |err| {
        std.debug.print("Chat completions request failed: {}\n", .{err});
        return;
    };
    defer allocator.free(chat_response);
    std.debug.print("Response: {s}\n", .{chat_response});
    
    std.debug.print("\nAll tests completed!\n", .{});
}