#!/bin/bash

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Logging
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"

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

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Add cleanup function
cleanup_volumes() {
    local hostname="$1"
    local pool_name="${2:-k3s_infra_pool}"
    
    echo "=== Cleaning up existing volumes for $hostname ==="
    
    # Sanitize hostname
    local sanitized=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    
    # List of volumes to check
    local volumes=(
        "cloudinit-${sanitized}.iso"
        "ubuntu-disk-${sanitized}.qcow2"
        "ubuntu-base-img-${sanitized}.qcow2"
    )
    
    for vol in "${volumes[@]}"; do
        if virsh vol-info "$vol" --pool "$pool_name" >/dev/null 2>&1; then
            echo "  Removing: $vol"
            virsh vol-delete "$vol" --pool "$pool_name" 2>/dev/null || true
        fi
    done
    
    echo "✓ Cleanup complete"
}

# Default values
ACTION="apply"
AUTO_APPROVE=false
SKIP_PREFLIGHT=false
SKIP_PLAN=false
FORCE_CLEANUP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cleanup)
            FORCE_CLEANUP=true
            shift
            ;;
        plan)
            ACTION="plan"
            shift
            ;;
        apply)
            ACTION="apply"
            shift
            ;;
        destroy)
            ACTION="destroy"
            shift
            ;;
        --auto-approve)
            AUTO_APPROVE=true
            shift
            ;;
        --skip-preflight)
            SKIP_PREFLIGHT=true
            shift
            ;;
        --skip-plan)
            SKIP_PLAN=true
            shift
            ;;
        -h|--help)
            cat << EOF
${BLUE}╔════════════════════════════════════════════════════════╗${NC}
${BLUE}║        Terraform KVM Deployment - Master Script        ║${NC}
${BLUE}╚════════════════════════════════════════════════════════╝${NC}

${CYAN}Usage:${NC}
  $0 [ACTION] [OPTIONS]

${CYAN}Actions:${NC}
  plan              Generate and show execution plan
  apply             Apply infrastructure changes (default)
  destroy           Destroy all infrastructure

${CYAN}Options:${NC}
  --auto-approve    Skip interactive approval
  --skip-preflight  Skip pre-flight checks
  --skip-plan       Skip plan generation (apply only)
  -h, --help        Show this help message

${CYAN}Examples:${NC}
  $0 plan                           # Generate plan
  $0 apply                          # Apply with confirmation
  $0 apply --auto-approve           # Apply without confirmation
  $0 destroy --auto-approve         # Destroy without confirmation

${CYAN}Workflow:${NC}
  1. Pre-flight checks (system validation)
  2. Terraform initialization
  3. Plan generation
  4. Apply/Destroy execution
  5. Post-deployment verification

EOF
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Banner
clear
echo -e "${MAGENTA}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║     ████████╗███████╗██████╗ ██████╗  █████╗ ███████╗        ║
║     ╚══██╔══╝██╔════╝██╔══██╗██╔══██╗██╔══██╗██╔════╝        ║
║        ██║   █████╗  ██████╔╝██████╔╝███████║█████╗          ║
║        ██║   ██╔══╝  ██╔══██╗██╔══██╗██╔══██║██╔══╝          ║
║        ██║   ███████╗██║  ██║██║  ██║██║  ██║██║             ║
║        ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝             ║
║                                                              ║
║              KVM Infrastructure Deployment                   ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "${CYAN}Action: ${YELLOW}$ACTION${NC}"
echo -e "${CYAN}Auto-approve: ${YELLOW}$AUTO_APPROVE${NC}"
echo -e "${CYAN}Working directory: ${YELLOW}$PROJECT_ROOT${NC}"
echo ""
sleep 2

# Add before terraform init
echo "=== Cleaning Old Detection Files ==="
rm -f terraform-kvm-ubuntu/.virt_type
rm -f terraform-kvm-ubuntu/.emulator_path
rm -f terraform-kvm-ubuntu/.kvm_type
echo "✓ Detection files cleaned"
echo ""

# Add cleanup before terraform if requested
if [ "$FORCE_CLEANUP" = true ]; then
    echo "Force cleanup requested..."
    cleanup_volumes "ubuntu-lts-vm" "k3s_infra_pool"
fi

# Step 1: Pre-flight checks
if [ "$SKIP_PREFLIGHT" = false ]; then
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                  Step 1: Pre-Flight Checks             ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if bash "$SCRIPT_DIR/run-preflight.sh"; then
        echo -e "${GREEN}✅ Pre-flight checks passed${NC}"
    else
        echo -e "${RED}❌ Pre-flight checks failed${NC}"
        exit 1
    fi
    echo ""
    sleep 2
else
    echo -e "${YELLOW}⚠️  Skipping pre-flight checks${NC}"
    echo ""
fi

# Step 2: Execute action
case $ACTION in
    plan)
        echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                  Step 2: Generate Plan                 ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        if bash "$SCRIPT_DIR/terraform_plan.sh"; then
            echo -e "${GREEN}✅ Plan generated successfully${NC}"
            exit 0
        else
            echo -e "${RED}❌ Plan generation failed${NC}"
            exit 1
        fi
        ;;
        
    apply)
        echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                  Step 2: Apply Changes                 ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        APPLY_ARGS=""
        if [ "$AUTO_APPROVE" = true ]; then
            APPLY_ARGS="--auto-approve"
        fi
        
        if bash "$SCRIPT_DIR/terraform_apply.sh" $APPLY_ARGS; then
            echo -e "${GREEN}✅ Deployment completed successfully${NC}"
            exit 0
        else
            echo -e "${RED}❌ Deployment failed${NC}"
            exit 1
        fi
        ;;
        
    destroy)
        echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                Step 2: Destroy Infrastructure          ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        DESTROY_ARGS=""
        if [ "$AUTO_APPROVE" = true ]; then
            DESTROY_ARGS="--auto-approve"
        fi
        
        if bash "$SCRIPT_DIR/terraform_destroy.sh" $DESTROY_ARGS; then
            echo -e "${GREEN}✅ Infrastructure destroyed successfully${NC}"
            exit 0
        else
            echo -e "${RED}❌ Destruction failed${NC}"
            exit 1
        fi
        ;;
esac