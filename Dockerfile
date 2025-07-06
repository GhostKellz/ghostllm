FROM debian:bookworm-slim

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Zig
ARG ZIG_VERSION=0.13.0
RUN curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt \
    && ln -s "/opt/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig

# Create app directory
WORKDIR /app

# Copy source code
COPY . .

# Build the application
RUN zig build -Doptimize=ReleaseFast

# Expose port
EXPOSE 8080

# Set default mode
ENV GHOSTLLM_MODE=serve

# Create non-root user
RUN groupadd -r ghostllm && useradd -r -g ghostllm ghostllm
RUN chown -R ghostllm:ghostllm /app
USER ghostllm

# Run the application
CMD ["./zig-out/bin/ghostllm", "serve"]