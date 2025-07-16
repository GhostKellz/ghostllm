const std = @import("std");
const config = @import("../config/config.zig");
const logger = @import("../logging/logger.zig");
const providers = @import("providers.zig");

// Zeke-specific API endpoints for AI-powered development tools

pub const ZekeRequest = struct {
    code: ?[]const u8 = null,
    context: ?[]const u8 = null,
    language: ?[]const u8 = null,
    task: []const u8,
    model: ?[]const u8 = null,
};

pub const ZekeResponse = struct {
    suggestions: []const u8,
    explanation: ?[]const u8 = null,
    confidence: ?f32 = null,
    metadata: ?[]const u8 = null,
};

// Code completion endpoint: /v1/zeke/code/complete
pub fn handleCodeCompletion(allocator: std.mem.Allocator, request: ZekeRequest) ![]const u8 {
    logger.info("Zeke code completion requested", .{});
    
    const model = request.model orelse "gpt-4";
    const code = request.code orelse "";
    const context = request.context orelse "";
    const language = request.language orelse "zig";
    
    // Create specialized prompt for code completion
    const system_prompt = "You are an expert AI coding assistant specialized in code completion. Provide concise, accurate code completions.";
    const user_prompt = try std.fmt.allocPrint(allocator,
        \\Language: {s}
        \\Context: {s}
        \\Code to complete:
        \\```{s}
        \\{s}
        \\```
        \\
        \\Provide the most likely completion for this code. Return only the completion without explanation.
    , .{ language, context, language, code });
    defer allocator.free(user_prompt);
    
    var messages = std.ArrayList(providers.ChatMessage).init(allocator);
    defer messages.deinit();
    
    try messages.append(.{ .role = "system", .content = system_prompt });
    try messages.append(.{ .role = "user", .content = user_prompt });
    
    const chat_request = providers.ChatRequest{
        .model = model,
        .messages = messages.items,
        .temperature = 0.2, // Low temperature for more deterministic completions
        .max_tokens = 500,
    };
    
    const response = try providers.routeRequest(allocator, chat_request);
    defer allocator.free(response);
    
    return try formatZekeResponse(allocator, response, "code_completion");
}

// Code analysis endpoint: /v1/zeke/code/analyze
pub fn handleCodeAnalysis(allocator: std.mem.Allocator, request: ZekeRequest) ![]const u8 {
    logger.info("Zeke code analysis requested", .{});
    
    const model = request.model orelse "gpt-4";
    const code = request.code orelse "";
    const language = request.language orelse "zig";
    
    const system_prompt = "You are an expert code reviewer. Analyze code for quality, performance, security, and best practices.";
    const user_prompt = try std.fmt.allocPrint(allocator,
        \\Language: {s}
        \\Code to analyze:
        \\```{s}
        \\{s}
        \\```
        \\
        \\Provide analysis covering:
        \\1. Code quality and style
        \\2. Performance considerations
        \\3. Security issues
        \\4. Best practice recommendations
        \\5. Potential bugs or issues
        \\
        \\Format as JSON with sections: quality, performance, security, recommendations, issues.
    , .{ language, language, code });
    defer allocator.free(user_prompt);
    
    var messages = std.ArrayList(providers.ChatMessage).init(allocator);
    defer messages.deinit();
    
    try messages.append(.{ .role = "system", .content = system_prompt });
    try messages.append(.{ .role = "user", .content = user_prompt });
    
    const chat_request = providers.ChatRequest{
        .model = model,
        .messages = messages.items,
        .temperature = 0.3,
        .max_tokens = 1500,
    };
    
    const response = try providers.routeRequest(allocator, chat_request);
    defer allocator.free(response);
    
    return try formatZekeResponse(allocator, response, "code_analysis");
}

// Code explanation endpoint: /v1/zeke/code/explain
pub fn handleCodeExplanation(allocator: std.mem.Allocator, request: ZekeRequest) ![]const u8 {
    logger.info("Zeke code explanation requested", .{});
    
    const model = request.model orelse "gpt-4";
    const code = request.code orelse "";
    const language = request.language orelse "zig";
    
    const system_prompt = "You are an expert programming tutor. Explain code clearly and educationally.";
    const user_prompt = try std.fmt.allocPrint(allocator,
        \\Language: {s}
        \\Code to explain:
        \\```{s}
        \\{s}
        \\```
        \\
        \\Provide a clear, educational explanation of:
        \\1. What this code does
        \\2. How it works step by step
        \\3. Key concepts and patterns used
        \\4. Any notable techniques or algorithms
        \\
        \\Make it understandable for developers learning {s}.
    , .{ language, language, code, language });
    defer allocator.free(user_prompt);
    
    var messages = std.ArrayList(providers.ChatMessage).init(allocator);
    defer messages.deinit();
    
    try messages.append(.{ .role = "system", .content = system_prompt });
    try messages.append(.{ .role = "user", .content = user_prompt });
    
    const chat_request = providers.ChatRequest{
        .model = model,
        .messages = messages.items,
        .temperature = 0.4,
        .max_tokens = 1000,
    };
    
    const response = try providers.routeRequest(allocator, chat_request);
    defer allocator.free(response);
    
    return try formatZekeResponse(allocator, response, "code_explanation");
}

// Code refactoring endpoint: /v1/zeke/code/refactor
pub fn handleCodeRefactoring(allocator: std.mem.Allocator, request: ZekeRequest) ![]const u8 {
    logger.info("Zeke code refactoring requested", .{});
    
    const model = request.model orelse "gpt-4";
    const code = request.code orelse "";
    const language = request.language orelse "zig";
    
    const system_prompt = "You are an expert software engineer specializing in code refactoring. Improve code while maintaining functionality.";
    const user_prompt = try std.fmt.allocPrint(allocator,
        \\Language: {s}
        \\Code to refactor:
        \\```{s}
        \\{s}
        \\```
        \\
        \\Provide refactored code that:
        \\1. Maintains the same functionality
        \\2. Improves readability and maintainability
        \\3. Follows {s} best practices
        \\4. Optimizes performance where possible
        \\5. Reduces complexity
        \\
        \\Return the refactored code with explanations of changes made.
    , .{ language, language, code, language });
    defer allocator.free(user_prompt);
    
    var messages = std.ArrayList(providers.ChatMessage).init(allocator);
    defer messages.deinit();
    
    try messages.append(.{ .role = "system", .content = system_prompt });
    try messages.append(.{ .role = "user", .content = user_prompt });
    
    const chat_request = providers.ChatRequest{
        .model = model,
        .messages = messages.items,
        .temperature = 0.3,
        .max_tokens = 1500,
    };
    
    const response = try providers.routeRequest(allocator, chat_request);
    defer allocator.free(response);
    
    return try formatZekeResponse(allocator, response, "code_refactoring");
}

// Test generation endpoint: /v1/zeke/code/test
pub fn handleTestGeneration(allocator: std.mem.Allocator, request: ZekeRequest) ![]const u8 {
    logger.info("Zeke test generation requested", .{});
    
    const model = request.model orelse "gpt-4";
    const code = request.code orelse "";
    const language = request.language orelse "zig";
    
    const system_prompt = "You are an expert in test-driven development. Generate comprehensive tests for given code.";
    const user_prompt = try std.fmt.allocPrint(allocator,
        \\Language: {s}
        \\Code to test:
        \\```{s}
        \\{s}
        \\```
        \\
        \\Generate comprehensive tests that:
        \\1. Test normal functionality
        \\2. Test edge cases
        \\3. Test error conditions
        \\4. Follow {s} testing conventions
        \\5. Include descriptive test names
        \\
        \\Provide complete test code with setup and assertions.
    , .{ language, language, code, language });
    defer allocator.free(user_prompt);
    
    var messages = std.ArrayList(providers.ChatMessage).init(allocator);
    defer messages.deinit();
    
    try messages.append(.{ .role = "system", .content = system_prompt });
    try messages.append(.{ .role = "user", .content = user_prompt });
    
    const chat_request = providers.ChatRequest{
        .model = model,
        .messages = messages.items,
        .temperature = 0.3,
        .max_tokens = 2000,
    };
    
    const response = try providers.routeRequest(allocator, chat_request);
    defer allocator.free(response);
    
    return try formatZekeResponse(allocator, response, "test_generation");
}

// Terminal command assistance endpoint: /v1/zeke/terminal/assist
pub fn handleTerminalAssistance(allocator: std.mem.Allocator, request: ZekeRequest) ![]const u8 {
    logger.info("Zeke terminal assistance requested", .{});
    
    const model = request.model orelse "gpt-3.5-turbo";
    const task = request.task;
    const context = request.context orelse "";
    
    const system_prompt = "You are an expert system administrator and developer. Help with terminal commands, debugging, and development tasks.";
    const user_prompt = try std.fmt.allocPrint(allocator,
        \\Context: {s}
        \\Task: {s}
        \\
        \\Provide:
        \\1. The exact command(s) to run
        \\2. Explanation of what each command does
        \\3. Any prerequisites or warnings
        \\4. Alternative approaches if applicable
        \\
        \\Focus on practical, safe, and efficient solutions.
    , .{ context, task });
    defer allocator.free(user_prompt);
    
    var messages = std.ArrayList(providers.ChatMessage).init(allocator);
    defer messages.deinit();
    
    try messages.append(.{ .role = "system", .content = system_prompt });
    try messages.append(.{ .role = "user", .content = user_prompt });
    
    const chat_request = providers.ChatRequest{
        .model = model,
        .messages = messages.items,
        .temperature = 0.3,
        .max_tokens = 800,
    };
    
    const response = try providers.routeRequest(allocator, chat_request);
    defer allocator.free(response);
    
    return try formatZekeResponse(allocator, response, "terminal_assistance");
}

// Project intelligence endpoint: /v1/zeke/project/analyze
pub fn handleProjectAnalysis(allocator: std.mem.Allocator, request: ZekeRequest) ![]const u8 {
    logger.info("Zeke project analysis requested", .{});
    
    const model = request.model orelse "gpt-4";
    const context = request.context orelse "";
    
    const system_prompt = "You are an expert software architect. Analyze project structure, dependencies, and provide architectural insights.";
    const user_prompt = try std.fmt.allocPrint(allocator,
        \\Project context: {s}
        \\
        \\Analyze the project and provide insights on:
        \\1. Architecture and design patterns
        \\2. Code organization and structure
        \\3. Dependencies and potential issues
        \\4. Performance optimization opportunities
        \\5. Security considerations
        \\6. Maintainability improvements
        \\7. Technology stack recommendations
        \\
        \\Provide actionable recommendations for improvement.
    , .{context});
    defer allocator.free(user_prompt);
    
    var messages = std.ArrayList(providers.ChatMessage).init(allocator);
    defer messages.deinit();
    
    try messages.append(.{ .role = "system", .content = system_prompt });
    try messages.append(.{ .role = "user", .content = user_prompt });
    
    const chat_request = providers.ChatRequest{
        .model = model,
        .messages = messages.items,
        .temperature = 0.4,
        .max_tokens = 2000,
    };
    
    const response = try providers.routeRequest(allocator, chat_request);
    defer allocator.free(response);
    
    return try formatZekeResponse(allocator, response, "project_analysis");
}

fn formatZekeResponse(allocator: std.mem.Allocator, openai_response: []const u8, response_type: []const u8) ![]const u8 {
    // Parse the OpenAI response
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, openai_response, .{}) catch {
        return try createZekeErrorResponse(allocator, "Failed to parse AI response");
    };
    defer parsed.deinit();
    
    if (parsed.value.object.get("choices")) |choices| {
        if (choices.array.items.len > 0) {
            const first_choice = choices.array.items[0];
            if (first_choice.object.get("message")) |message| {
                if (message.object.get("content")) |content| {
                    const timestamp = std.time.timestamp();
                    
                    return try std.fmt.allocPrint(allocator,
                        \\{{"type": "{s}", "content": "{s}", "timestamp": {}, "status": "success", "provider": "ghostllm", "model": "ai"}}
                    , .{ response_type, content.string, timestamp });
                }
            }
        }
    }
    
    return try createZekeErrorResponse(allocator, "Invalid AI response format");
}

fn createZekeErrorResponse(allocator: std.mem.Allocator, error_message: []const u8) ![]const u8 {
    const timestamp = std.time.timestamp();
    return try std.fmt.allocPrint(allocator,
        \\{{"type": "error", "message": "{s}", "timestamp": {}, "status": "error"}}
    , .{ error_message, timestamp });
}
