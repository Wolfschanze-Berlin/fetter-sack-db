# =============================================================================
# Clawd Camelot - Telegram to Athena Bridge
# =============================================================================
# Multi-stage Docker build with caching for Clawd.bot gateway connecting
# messaging platforms to Claude Code AI agents.
#
# Build: docker build -t clawd-camelot:local .
# Run:   docker compose up clawd-gateway
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Base - System dependencies (cached layer)
# -----------------------------------------------------------------------------
FROM node:22-bookworm-slim AS base

# Install system dependencies - this layer is cached
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    python3 \
    python3-pip \
    python3-venv \
    ca-certificates \
    jq

# Set working directory (using existing node user from base image)
WORKDIR /home/node

# -----------------------------------------------------------------------------
# Stage 2: Dependencies - Install npm packages (cached layer)
# -----------------------------------------------------------------------------
FROM base AS deps

# Install global npm packages with cache mount
RUN --mount=type=cache,target=/root/.npm \
    npm install -g clawdbot@latest @anthropic-ai/claude-code

# Install uv for Python package management
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv

# -----------------------------------------------------------------------------
# Stage 3: Production - Final image with app files
# -----------------------------------------------------------------------------
FROM deps AS production

# Create directories for persistence
RUN mkdir -p /home/node/.clawdbot \
    /home/node/.claude \
    /home/node/config \
    /home/node/agents \
    /home/node/workspace \
    && chown -R node:node /home/node

# Copy configuration files (changes here don't invalidate deps cache)
COPY --chown=node:node config/ /home/node/config/
COPY --chown=node:node agents/ /home/node/agents/
COPY --chown=node:node scripts/ /home/node/scripts/

# Copy entrypoint
COPY --chown=node:node entrypoint.sh /home/node/entrypoint.sh
RUN chmod +x /home/node/entrypoint.sh

# Switch to non-root user
USER node

# Expose gateway port
EXPOSE 18789

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:18789/health || exit 1

# Default command
ENTRYPOINT ["/home/node/entrypoint.sh"]
CMD ["gateway"]
