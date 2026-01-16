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
TF_DIR="${PROJECT_ROOT}/terraform-kvm-ubuntu"

# Logging
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/terraform-plan-$(date +%Y%m%d-%H%M%S).log"
PLAN_FILE="tfplan-$(date +%Y%m%d-%H%M%S).out"

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           Terraform Plan - Optimized Execution         ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo -e "${CYAN}Log file: $LOG_FILE${NC}"
echo ""

# Function to print status
print_status() {
    local status=$1
    local message=$2
    
    if [ "$status" = "ok" ]; then
        echo -e "${GREEN}✓${NC} $message"
    elif [ "$status" = "warn" ]; then
        echo -e "${YELLOW}⚠${NC} $message"
    else
        echo -e "${RED}✗${NC} $message"
    fi
}

# Check if terraform directory exists
if [ ! -d "$TF_DIR" ]; then
    print_status "error" "Terraform directory not found: $TF_DIR"
    exit 1
fi

cd "$TF_DIR"
print_status "ok" "Changed to Terraform directory: $TF_DIR"
echo ""

# Step 1: Run pre-flight check
echo -e "${BLUE}[1/6]${NC} Running pre-flight checks..."
if bash "$SCRIPT_DIR/run-preflight.sh" &>/dev/null; then
    print_status "ok" "Pre-flight checks passed"
else
    print_status "warn" "Pre-flight checks had warnings (continuing...)"
fi
echo ""

# Step 2: Check Terraform initialization
echo -e "${BLUE}[2/6]${NC} Checking Terraform initialization..."
if [ -d ".terraform" ]; then
    print_status "ok" "Terraform is initialized"
else
    print_status "warn" "Terraform not initialized. Running terraform init..."
    echo ""
    
    if terraform init -upgrade 2>&1 | tee -a "$LOG_FILE"; then
        print_status "ok" "Terraform initialized successfully"
    else
        print_status "error" "Terraform initialization failed"
        exit 1
    fi
fi
echo ""

# Step 3: Validate configuration
echo -e "${BLUE}[3/6]${NC} Validating Terraform configuration..."
if terraform validate 2>&1 | tee -a "$LOG_FILE"; then
    print_status "ok" "Configuration is valid"
else
    print_status "error" "Configuration validation failed"
    exit 1
fi
echo ""

# Step 4: Format check
echo -e "${BLUE}[4/6]${NC} Checking Terraform formatting..."
if terraform fmt -check -recursive 2>&1 | tee -a "$LOG_FILE"; then
    print_status "ok" "All files are properly formatted"
else
    print_status "warn" "Some files need formatting"
    echo -e "${YELLOW}Run 'terraform fmt -recursive' to fix${NC}"
fi
echo ""

# Step 5: Run terraform plan
echo -e "${BLUE}[5/6]${NC} Running Terraform plan..."
echo -e "${CYAN}This may take a few minutes...${NC}"
echo ""

# Set parallelism for better performance
PARALLELISM=10

# Run plan with detailed output
if terraform plan \
    -parallelism=$PARALLELISM \
    -out="$PLAN_FILE" \
    -detailed-exitcode \
    2>&1 | tee -a "$LOG_FILE"; then
    
    PLAN_EXIT_CODE=${PIPESTATUS[0]}
    
    case $PLAN_EXIT_CODE in
        0)
            echo ""
            print_status "ok" "No changes detected - infrastructure is up to date"
            rm -f "$PLAN_FILE"
            ;;
        2)
            echo ""
            print_status "ok" "Plan completed successfully - changes detected"
            echo -e "${CYAN}Plan saved to: $PLAN_FILE${NC}"
            ;;
        *)
            echo ""
            print_status "error" "Plan failed with exit code: $PLAN_EXIT_CODE"
            exit $PLAN_EXIT_CODE
            ;;
    esac
else
    print_status "error" "Terraform plan failed"
    exit 1
fi
echo ""

# Step 6: Show plan summary
echo -e "${BLUE}[6/6]${NC} Plan Summary..."
echo ""

if [ -f "$PLAN_FILE" ]; then
    # Extract resource changes from plan
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                    PLAN SUMMARY                         ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    terraform show -no-color "$PLAN_FILE" | grep -E "Plan:|will be" | head -20
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}✅ Plan completed successfully${NC}"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo -e "  1. Review the plan: ${YELLOW}terraform show $PLAN_FILE${NC}"
    echo -e "  2. Apply changes: ${YELLOW}terraform apply \"$PLAN_FILE\"${NC}"
    echo -e "  3. Or apply with auto-approve: ${YELLOW}terraform apply -auto-approve${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Note: Plan file expires after 24 hours${NC}"
else
    echo -e "${GREEN}✅ No changes needed - infrastructure matches desired state${NC}"
fi

echo ""
echo -e "${CYAN}Full log saved to: ${YELLOW}$LOG_FILE${NC}"
echo ""

exit 0