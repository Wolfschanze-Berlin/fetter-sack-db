#!/bin/bash
# =============================================================================
# Clawd Camelot - Telegram Bot Setup Helper
# =============================================================================
# Guides you through creating and configuring a Telegram bot
#
# Usage: ./scripts/telegram-setup.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          Telegram Bot Setup for Clawd Camelot                 ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# -----------------------------------------------------------------------------
# Step 1: Create Bot with BotFather
# -----------------------------------------------------------------------------
echo -e "${CYAN}Step 1: Create your Telegram Bot${NC}"
echo ""
echo "1. Open Telegram and search for @BotFather"
echo "2. Send /newbot command"
echo "3. Follow the prompts to:"
echo "   - Choose a name (e.g., 'Athena Query Bot')"
echo "   - Choose a username (must end in 'bot', e.g., 'athena_query_bot')"
echo "4. BotFather will give you a token like:"
echo "   123456789:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
echo ""
echo -e "${YELLOW}Press Enter when you have your bot token...${NC}"
read -r

# -----------------------------------------------------------------------------
# Step 2: Enter Bot Token
# -----------------------------------------------------------------------------
echo ""
echo -e "${CYAN}Step 2: Enter your Bot Token${NC}"
echo ""
read -p "Paste your bot token: " BOT_TOKEN

# Validate token format (basic check)
if [[ ! "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
    echo -e "${RED}Invalid token format. Token should look like: 123456789:ABC-DEF...${NC}"
    exit 1
fi

# Test token with Telegram API
echo ""
echo -e "${YELLOW}Testing token with Telegram API...${NC}"
RESPONSE=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")

if echo "$RESPONSE" | grep -q '"ok":true'; then
    BOT_USERNAME=$(echo "$RESPONSE" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
    BOT_NAME=$(echo "$RESPONSE" | grep -o '"first_name":"[^"]*"' | cut -d'"' -f4)
    echo -e "${GREEN}✓ Token is valid!${NC}"
    echo "  Bot name: $BOT_NAME"
    echo "  Bot username: @$BOT_USERNAME"
else
    echo -e "${RED}Token is invalid. Please check and try again.${NC}"
    echo "Response: $RESPONSE"
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 3: Save Token to .env
# -----------------------------------------------------------------------------
echo ""
echo -e "${CYAN}Step 3: Saving token to .env${NC}"

ENV_FILE="$PROJECT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Creating .env from template..."
    cp "$PROJECT_DIR/.env.example" "$ENV_FILE"
fi

# Update or add TELEGRAM_BOT_TOKEN
if grep -q "^TELEGRAM_BOT_TOKEN=" "$ENV_FILE"; then
    # Replace existing token
    sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$BOT_TOKEN|" "$ENV_FILE"
else
    # Add token
    echo "TELEGRAM_BOT_TOKEN=$BOT_TOKEN" >> "$ENV_FILE"
fi

echo -e "${GREEN}✓ Token saved to .env${NC}"

# -----------------------------------------------------------------------------
# Step 4: Set Bot Commands
# -----------------------------------------------------------------------------
echo ""
echo -e "${CYAN}Step 4: Setting bot commands menu${NC}"

COMMANDS='[
  {"command": "start", "description": "Start the bot and show help"},
  {"command": "help", "description": "Show available commands"},
  {"command": "status", "description": "Check bot and connection status"},
  {"command": "id", "description": "Show your Telegram user ID"}
]'

RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setMyCommands" \
    -H "Content-Type: application/json" \
    -d "{\"commands\": $COMMANDS}")

if echo "$RESPONSE" | grep -q '"ok":true'; then
    echo -e "${GREEN}✓ Bot commands configured!${NC}"
else
    echo -e "${YELLOW}⚠ Could not set commands (may already exist)${NC}"
fi

# -----------------------------------------------------------------------------
# Step 5: Get Your User ID
# -----------------------------------------------------------------------------
echo ""
echo -e "${CYAN}Step 5: Get Your Telegram User ID${NC}"
echo ""
echo "To add yourself to the allowlist, you need your Telegram user ID."
echo "You can get it by:"
echo "  1. Sending any message to @userinfobot"
echo "  2. It will reply with your ID"
echo ""
read -p "Enter your Telegram user ID (or press Enter to skip): " USER_ID

if [ -n "$USER_ID" ]; then
    # Validate it's a number
    if [[ "$USER_ID" =~ ^[0-9]+$ ]]; then
        echo ""
        echo -e "${CYAN}Step 6: Updating allowlist${NC}"

        ALLOWLIST_FILE="$PROJECT_DIR/config/allowlist.json"

        # Use jq to update allowlist if available, otherwise manual edit
        if command -v jq &> /dev/null; then
            # Update allowlist with user ID
            TMP_FILE=$(mktemp)
            jq --argjson id "$USER_ID" \
               '.telegram.allowed_users = [{"id": $id, "name": "Admin"}]' \
               "$ALLOWLIST_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ALLOWLIST_FILE"
            echo -e "${GREEN}✓ Added user ID $USER_ID to allowlist${NC}"
        else
            echo -e "${YELLOW}Please manually edit config/allowlist.json:${NC}"
            echo "  Change the allowed_users id from 0 to $USER_ID"
        fi
    else
        echo -e "${YELLOW}Invalid user ID (should be a number). Please update allowlist manually.${NC}"
    fi
fi

# -----------------------------------------------------------------------------
# Done!
# -----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Telegram Bot Setup Complete!                         ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Bot: @$BOT_USERNAME"
echo ""
echo "Next steps:"
echo "  1. Review and update config/allowlist.json with allowed users"
echo "  2. Start the gateway: docker compose up -d clawd-gateway"
echo "  3. Message your bot on Telegram!"
echo ""
echo "Useful commands:"
echo "  docker compose logs -f clawd-gateway  # View logs"
echo "  docker compose restart clawd-gateway  # Restart after config changes"
echo ""
