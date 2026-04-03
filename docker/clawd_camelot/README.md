# Clawd Camelot

> Telegram ↔ Athena AI Bridge via Clawd.bot

Connect to athena-mpc AI agents through Telegram messaging for mobile data queries.

## Quick Start

### Prerequisites

- Docker and Docker Compose v2
- Telegram bot token (from [@BotFather](https://t.me/BotFather))
- Anthropic API key (from [console.anthropic.com](https://console.anthropic.com))
- AWS Athena credentials

### Setup

```bash
# Option 1: Guided setup (recommended)
./scripts/setup.sh

# Option 2: Telegram-specific setup
./scripts/telegram-setup.sh

# Option 3: Manual setup
cp .env.example .env
# Edit .env with:
# - TELEGRAM_BOT_TOKEN (from @BotFather)
# - ANTHROPIC_API_KEY (from console.anthropic.com)
# - ATHENA_ACCESS_KEY / ATHENA_ACCESS_KEY_SECRET

docker compose up -d clawd-gateway
```

### Creating Your Telegram Bot

1. **Open Telegram** and search for [@BotFather](https://t.me/BotFather)
2. **Send `/newbot`** and follow the prompts
3. **Copy the token** (looks like `123456789:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)
4. **Run the helper script**: `./scripts/telegram-setup.sh`

The script will:
- Validate your token with Telegram API
- Save it to `.env`
- Configure bot commands menu
- Help you set up the allowlist

### Verify

```bash
# Check gateway status
docker compose logs clawd-gateway

# Access dashboard
open http://localhost:18789/
```

## Configuration

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TELEGRAM_BOT_TOKEN` | Yes | Bot token from @BotFather |
| `ANTHROPIC_API_KEY` | Yes | Claude API key |
| `ATHENA_ACCESS_KEY` | Yes | AWS key for Athena queries |
| `ATHENA_ACCESS_KEY_SECRET` | Yes | AWS secret for Athena |
| `S3_OUTPUT_BUCKET` | No | Bucket for large results |

### Allowlist Setup

Edit `config/allowlist.json` to control access:

1. Get your Telegram user ID:
   - Message [@userinfobot](https://t.me/userinfobot) on Telegram
   - Copy the "Id" value

2. Add to allowlist:
```json
{
  "telegram": {
    "allowed_users": [
      {"id": YOUR_ID_HERE, "name": "Your Name"}
    ]
  }
}
```

3. Restart gateway:
```bash
docker compose restart clawd-gateway
```

## Usage

### Commands

```bash
# Start gateway
docker compose up -d clawd-gateway

# View logs
docker compose logs -f clawd-gateway

# Run CLI commands
docker compose run --rm clawd-cli status
docker compose run --rm clawd-cli channels list

# Stop
docker compose down
```

### Messaging

Once running, message your bot on Telegram:

```
You: What were the top 10 members by stake yesterday?

Bot: ⏳ Processing your request...

Bot: 📊 Query Results (10 rows)
| membercode | stake    | winlost |
|------------|----------|---------|
| ABC123     | 150,000  | -45,000 |
| DEF456     | 125,000  | 12,500  |
...
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│                 Telegram User                    │
└─────────────────────┬───────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────┐
│           clawd-camelot-gateway                  │
│           (Docker container)                     │
│                                                  │
│  ┌───────────────────────────────────────────┐  │
│  │  Clawd.bot Gateway (port 18789)           │  │
│  │  └── Telegram Channel (grammY)            │  │
│  │  └── athena-claude-wrapper agent          │  │
│  └───────────────────────────────────────────┘  │
│                      │                           │
│                      ▼                           │
│  ┌───────────────────────────────────────────┐  │
│  │  Claude Code CLI                          │  │
│  │  └── CLAUDE.md project context            │  │
│  │  └── data-analyst agent delegation        │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────┬───────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────┐
│               AWS Athena                         │
│         (ap-northeast-1 region)                  │
└─────────────────────────────────────────────────┘
```

## Files

```
docker/clawd_camelot/
├── Dockerfile              # Container image definition
├── docker-compose.yml      # Service orchestration
├── .env.example            # Environment template
├── entrypoint.sh           # Container startup script
├── config/
│   ├── clawdbot.json       # Gateway configuration
│   └── allowlist.json      # Access control
├── agents/
│   └── athena-claude-wrapper.ts  # Custom agent (Issue #206)
├── scripts/
│   ├── setup.sh            # First-time setup wizard
│   └── telegram-setup.sh   # Telegram bot configuration
└── README.md               # This file
```

## Troubleshooting

### Bot not responding

1. Check gateway logs:
   ```bash
   docker compose logs clawd-gateway
   ```

2. Verify bot token is valid:
   ```bash
   curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe"
   ```

3. Ensure you're on the allowlist

### Query timeout

Long Athena queries may timeout. Check:
- AWS credentials are valid
- Athena region is correct (ap-northeast-1)
- Query isn't scanning excessive data

### Permission denied

- Verify your Telegram ID is in `config/allowlist.json`
- Restart gateway after config changes

## Related Issues

- [#205](https://github.com/MainSystemDev/rnd-athena-mcp/issues/205) - Docker infrastructure (this)
- [#206](https://github.com/MainSystemDev/rnd-athena-mcp/issues/206) - athena-claude-wrapper agent
- [#207](https://github.com/MainSystemDev/rnd-athena-mcp/issues/207) - Telegram integration
- [#211](https://github.com/MainSystemDev/rnd-athena-mcp/issues/211) - S3 results upload
- [#212](https://github.com/MainSystemDev/rnd-athena-mcp/issues/212) - Allowlist security
