#!/bin/bash
# =============================================================================
# Clawd Camelot - Setup Script
# =============================================================================
# First-time setup helper for Clawd Camelot Docker deployment
#
# Usage: ./scripts/setup.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          Clawd Camelot - Setup Wizard                        ║"
echo "║          Telegram ↔ Athena AI Bridge                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# -----------------------------------------------------------------------------
# Check Prerequisites
# -----------------------------------------------------------------------------
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    echo "Install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo -e "${RED}Error: Docker Compose v2 is not available${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Docker and Docker Compose available${NC}"

# -----------------------------------------------------------------------------
# Create .env file
# -----------------------------------------------------------------------------
if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo -e "${YELLOW}Creating .env file from template...${NC}"
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    echo -e "${GREEN}✓ Created .env file${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Edit .env file with your credentials:${NC}"
    echo "  1. TELEGRAM_BOT_TOKEN - Create bot via @BotFather"
    echo "  2. ANTHROPIC_API_KEY - From console.anthropic.com"
    echo "  3. ATHENA_ACCESS_KEY/SECRET - AWS credentials for Athena"
    echo ""
    read -p "Press Enter to open .env in editor (or Ctrl+C to edit manually)..."

    if command -v code &> /dev/null; then
        code "$PROJECT_DIR/.env"
    elif command -v nano &> /dev/null; then
        nano "$PROJECT_DIR/.env"
    elif command -v vim &> /dev/null; then
        vim "$PROJECT_DIR/.env"
    else
        echo "Edit manually: $PROJECT_DIR/.env"
    fi
else
    echo -e "${GREEN}✓ .env file already exists${NC}"
fi

# -----------------------------------------------------------------------------
# Build Docker Image
# -----------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}Building Docker image...${NC}"
cd "$PROJECT_DIR"
docker compose build clawd-gateway

echo -e "${GREEN}✓ Docker image built successfully${NC}"

# -----------------------------------------------------------------------------
# Run Onboarding
# -----------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}Running Clawd.bot onboarding...${NC}"
docker compose run --rm clawd-cli onboard

# -----------------------------------------------------------------------------
# Start Gateway
# -----------------------------------------------------------------------------
echo ""
read -p "Start the gateway now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Starting gateway...${NC}"
    docker compose up -d clawd-gateway

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          Clawd Camelot is running!                            ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Dashboard: http://localhost:18789/"
    echo "Logs:      docker compose logs -f clawd-gateway"
    echo "Stop:      docker compose down"
else
    echo ""
    echo "To start later, run:"
    echo "  cd $PROJECT_DIR && docker compose up -d clawd-gateway"
fi

echo ""
echo -e "${GREEN}Setup complete!${NC}"
