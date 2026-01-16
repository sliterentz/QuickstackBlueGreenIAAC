#!/bin/bash

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║        Terraform KVM Deployment - Pre-Flight           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}❌ Do not run this wrapper script as root${NC}"
    echo -e "${YELLOW}This script will use sudo when needed${NC}"
    exit 1
fi

# Change to project root
cd "$PROJECT_ROOT"
echo -e "${BLUE}📁 Working directory: $PROJECT_ROOT${NC}"
echo ""

# Fix permissions first
echo -e "${BLUE}🔧 Step 1: Fixing file permissions...${NC}"
if [ -f "$SCRIPT_DIR/fix_permission.sh" ]; then
    bash "$SCRIPT_DIR/fix_permission.sh"
else
    echo -e "${YELLOW}⚠️  fix_permission.sh not found, skipping...${NC}"
fi
echo ""

# Make pre-flight check executable
chmod +x "$SCRIPT_DIR/pre-flight-check.sh" 2>/dev/null || true

# Run pre-flight check
echo -e "${BLUE}🚀 Step 2: Running pre-flight checks...${NC}"
echo ""

if sudo -E bash "$SCRIPT_DIR/pre-flight-check.sh"; then
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Pre-Flight Check Passed ✅                ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}You can now proceed with:${NC}"
    echo -e "  ${YELLOW}cd terraform-kvm-ubuntu${NC}"
    echo -e "  ${YELLOW}terraform init${NC}"
    echo -e "  ${YELLOW}terraform plan${NC}"
    echo ""
    exit 0
else
    EXIT_CODE=$?
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              Pre-Flight Check Failed ❌                ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Please fix the issues above and try again${NC}"
    echo -e "${YELLOW}Check the log file for more details${NC}"
    echo ""
    exit $EXIT_CODE
fi