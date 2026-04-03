#!/bin/bash
# =============================================================================
# Clawd Camelot - Container Entrypoint
# =============================================================================
# Handles initialization and startup of Clawd.bot gateway
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# -----------------------------------------------------------------------------
# Initialize Configuration
# -----------------------------------------------------------------------------
init_config() {
    log_info "Initializing Clawd Camelot configuration..."

    # Create required directories with correct permissions
    mkdir -p ~/.clawdbot/agents/main/agent
    mkdir -p ~/.clawdbot/agents/main/sessions
    mkdir -p ~/.clawdbot/credentials
    chmod 700 ~/.clawdbot 2>/dev/null || true

    # Set gateway mode to local
    log_info "Setting gateway mode to local..."
    clawdbot config set gateway.mode local 2>/dev/null || true
    clawdbot config set gateway.port "${CLAWD_GATEWAY_PORT:-18789}" 2>/dev/null || true

    # Configure Telegram channel if token is set
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        log_info "Adding Telegram channel..."
        clawdbot channels add --channel telegram --token "$TELEGRAM_BOT_TOKEN" 2>/dev/null || true

        # Configure DM access (open mode - allow user 121146099 without pairing)
        log_info "Configuring DM access..."
        clawdbot config set 'channels.telegram.allowFrom' '["*"]' 2>/dev/null || true
        clawdbot config set channels.telegram.dmPolicy open 2>/dev/null || true

        # Configure group access (open for all)
        log_info "Configuring group access..."
        clawdbot config set channels.telegram.groupPolicy open 2>/dev/null || true
        clawdbot config set 'channels.telegram.groups.-1003692385437.requireMention' true 2>/dev/null || true
        clawdbot config set 'channels.telegram.groupAllowFrom' '["*"]' 2>/dev/null || true

        # Configure forum topic routing (required for forum supergroups - GitHub issue #727)
        # Topic 4010 is the main bot channel in the forum
        # Use requireMention:false to ensure automatic responses are delivered
        log_info "Configuring forum topic routing..."
        clawdbot config set 'channels.telegram.groups.-1003692385437.topics' '{"4010":{"requireMention":false}}' 2>/dev/null || true

        # Set streamMode to off (send complete message, not streaming)
        clawdbot config set channels.telegram.streamMode off 2>/dev/null || true

        # Register custom commands with Telegram
        log_info "Registering Telegram commands..."
        clawdbot config set 'channels.telegram.commands' '[
            {"command":"start","description":"Start the bot and show help"},
            {"command":"help","description":"Show available commands"},
            {"command":"athena","description":"Query AWS Athena data warehouse"},
            {"command":"sentinel","description":"OpenSearch fraud detection AI"},
            {"command":"excalibur","description":"Cross-database investigation AI"},
            {"command":"msbo_cs","description":"Customer service investigation"},
            {"command":"aws","description":"AWS operations workflow"}
        ]' 2>/dev/null || true
    fi

    # Copy essential workspace files to Clawd.bot's writable agent directory
    # The workspace mount is read-only, so we copy what Claude needs
    log_info "Setting up workspace for Clawd.bot agent..."
    mkdir -p ~/clawd/.claude/commands 2>/dev/null || true

    # Copy CLAUDE.md and project context
    cp /home/node/workspace/CLAUDE.md ~/clawd/ 2>/dev/null || log_warn "Could not copy CLAUDE.md"
    cp /home/node/workspace/.claude/PROJECT_INDEX.json ~/clawd/.claude/ 2>/dev/null || true

    # Copy command definitions (these tell Claude about /athena, /sentinel, etc.)
    cp -r /home/node/workspace/.claude/commands/* ~/clawd/.claude/commands/ 2>/dev/null || true

    # Create symlinks for read-only data (schema docs, scripts)
    ln -sf /home/node/workspace/db ~/clawd/db 2>/dev/null || true
    ln -sf /home/node/workspace/scripts ~/clawd/scripts 2>/dev/null || true
    ln -sf /home/node/workspace/docs ~/clawd/docs 2>/dev/null || true
    ln -sf /home/node/workspace/reports ~/clawd/reports 2>/dev/null || true

    # Create TOOLS.md with project commands for Clawd.bot agent
    # This bridges Clawd.bot's embedded agent to Claude Code CLI commands
    log_info "Creating TOOLS.md with project commands..."
    cat > ~/clawd/TOOLS.md << 'TOOLS_EOF'
# TOOLS.md - Athena MPC Project Commands

This workspace provides data analytics and investigation tools for the W88 platform.

## Project Context

Read `CLAUDE.md` for full project instructions. Read `.claude/PROJECT_INDEX.json` for 94% token-optimized project structure.

## Available Slash Commands

When users request these capabilities, use the **coding-agent** skill to run Claude Code CLI with the appropriate command.

### Data Analytics Commands

| Command | Description | Use When |
|---------|-------------|----------|
| `/athena` | AWS Athena query expert | User wants to query data warehouse, run SQL, analyze member data |
| `/athena-cli` | Direct Athena CLI operations | User needs raw AWS Athena commands |
| `/athena-with-persona` | Persona-driven reports | User wants analysis from a specific perspective |

### Investigation Commands

| Command | Description | Use When |
|---------|-------------|----------|
| `/sentinel` | OpenSearch fraud detection AI | User suspects fraud, wants behavior analysis |
| `/excalibur` | Cross-database investigation AI | User needs to correlate data across Athena + OpenSearch |
| `/msbo-cs` | Customer service investigation | User has CS tickets to investigate |
| `/king-arthur` | Multi-agent investigation orchestrator | Complex investigations needing multiple data sources |

### AWS Operations

| Command | Description | Use When |
|---------|-------------|----------|
| `/aws` | AWS operations workflow | User needs AWS CLI operations |
| `/update-schema` | Sync Athena schema docs | Schema documentation needs refresh |

### Reporting

| Command | Description | Use When |
|---------|-------------|----------|
| `/email-report` | Generate email reports | User wants to send analysis via email |

## How to Execute Commands

Use the **coding-agent** skill with Claude Code CLI:

```bash
# Via coding-agent skill (PTY required for interactive)
bash pty:true workdir:/home/node/clawd command:"claude -p '/athena show tables in idc-prod-dw1'"
```

**For quick queries:**
```bash
bash pty:true workdir:/home/node/clawd command:"claude -p '/athena [user query]'"
```

## Athena Databases

| Database | Purpose |
|----------|---------|
| `idc-prod-91-mainsys` | Core transactions (deposits, withdrawals, sessions) |
| `idc-prod-dw1` | Primary data warehouse (daily/weekly/monthly analytics) |
| `idc-prod-dw1-linkdb` | Member profiles and reference data |
| `idc-prod-dw2` | Casino analytics (table-level breakdown) |
| `idc-prod-dw3` | Multi-product game breakdowns |
| `idc-prod-dw4` | Additional consolidations |

## Quick Reference

- **Simple Athena query**: Ask me to query Athena, I'll use coding-agent with `/athena`
- **Fraud investigation**: Ask about suspicious activity, I'll use `/sentinel` or `/excalibur`
- **Member lookup**: Ask about a member, I'll query the data warehouse
- **Schema info**: Ask about tables/fields, I'll describe the schema
TOOLS_EOF

    # Verify setup
    if [ -f ~/clawd/CLAUDE.md ]; then
        log_info "Workspace setup complete - CLAUDE.md accessible"
        log_info "Commands available: $(ls ~/clawd/.claude/commands/ 2>/dev/null | wc -l)"
        log_info "TOOLS.md created: $([ -f ~/clawd/TOOLS.md ] && echo 'yes' || echo 'no')"
    else
        log_warn "Workspace setup may have failed"
    fi

    # Copy allowlist if exists (with error handling for permission issues)
    if [ -f /home/node/config/allowlist.json ]; then
        cp /home/node/config/allowlist.json ~/.clawdbot/allowlist.json 2>/dev/null || log_warn "Could not copy allowlist (may already exist)"
    fi

    chmod 600 ~/.clawdbot/clawdbot.json 2>/dev/null || true

    log_info "Configuration initialized"
}

# -----------------------------------------------------------------------------
# Validate Environment
# -----------------------------------------------------------------------------
validate_env() {
    local has_error=false

    log_info "Validating environment..."

    # Check for Telegram token if Telegram is enabled
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        log_warn "TELEGRAM_BOT_TOKEN not set - Telegram channel will be disabled"
    else
        log_info "Telegram bot token configured"
    fi

    # Check for Anthropic API key
    if [ -z "$ANTHROPIC_API_KEY" ]; then
        log_warn "ANTHROPIC_API_KEY not set - Claude Code may not function"
    else
        log_info "Anthropic API key configured"
    fi

    # Check for Athena credentials
    if [ -z "$ATHENA_ACCESS_KEY" ] || [ -z "$ATHENA_ACCESS_KEY_SECRET" ]; then
        log_warn "Athena credentials not fully configured"
    else
        log_info "Athena credentials configured"
    fi

    if [ "$has_error" = true ]; then
        log_error "Environment validation failed"
        exit 1
    fi

    log_info "Environment validation passed"
}

# -----------------------------------------------------------------------------
# Start Gateway
# -----------------------------------------------------------------------------
start_gateway() {
    log_info "Starting Clawd.bot gateway on port ${CLAWD_GATEWAY_PORT:-18789}..."

    # Set working directory to workspace for CLAUDE.md access
    cd /home/node/workspace

    # Auto-fix any configuration issues
    log_info "Running doctor to apply any pending fixes..."
    clawdbot doctor --fix 2>/dev/null || true

    # Start the gateway (--host not supported, binding handled by Docker)
    exec clawdbot gateway \
        --port "${CLAWD_GATEWAY_PORT:-18789}" \
        --verbose
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    case "${1:-gateway}" in
        gateway)
            init_config
            validate_env
            start_gateway
            ;;
        onboard)
            log_info "Running onboarding wizard..."
            exec clawdbot onboard "${@:2}"
            ;;
        health)
            exec clawdbot health
            ;;
        status)
            exec clawdbot status
            ;;
        channels)
            exec clawdbot channels "${@:2}"
            ;;
        *)
            # Pass through to clawdbot CLI
            exec clawdbot "$@"
            ;;
    esac
}

main "$@"
