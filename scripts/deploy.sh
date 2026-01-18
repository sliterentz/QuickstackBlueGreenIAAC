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

# Source domain manager functions
source "$SCRIPT_DIR/domain_manager.sh"

# Add cleanup function
cleanup_volumes() {
    local hostname="$1"
    local pool_name="${2:-k3s_infra_pool}"
    local handle_domain="${3:-check}"  # check, preserve, remove
    
    echo "=== Cleaning up existing volumes for $hostname ==="
    
    # Sanitize hostname
    local sanitized=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    
    log_message "Sanitized hostname: $sanitized"
    log_message "Domain handling mode: $handle_domain"

    # Check if domain exists
    if check_domain_exists "$sanitized"; then
        echo -e "${YELLOW}⚠ Domain '$sanitized' already exists${NC}"
        log_message "Domain '$sanitized' exists"
        
        case "$handle_domain" in
            check)
                # Just report, don't do anything
                local state=$(get_domain_state "$sanitized")
                echo "  Current state: $state"
                echo "  Use --preserve-domain to keep it or --remove-domain to delete it"
                log_message "Domain check mode - state: $state"
                return 1
                ;;
                
            preserve)
                echo -e "${GREEN}✓ Preserving existing domain${NC}"
                log_message "Preserving domain '$sanitized'"

                # Validate configuration
                if validate_domain_config "$sanitized"; then
                    echo -e "${GREEN}✓ Domain configuration is valid${NC}"
                    log_message "Domain configuration validated successfully"
                    
                    # Handle domain state
                    if handle_existing_domain "$sanitized" "reuse"; then
                        echo -e "${GREEN}✓ Domain is ready for use${NC}"
                        log_message "Domain ready for reuse"

                        # Export sanitized name for later use
                        echo "$sanitized" > "$PROJECT_ROOT/.domain_name"
                        return 0
                    else
                        echo -e "${RED}✗ Failed to prepare domain${NC}"
                        log_message "Failed to prepare domain for reuse"
                        return 1
                    fi
                else
                    local validation_result=$?
                    if [ $validation_result -eq 2 ]; then
                        echo -e "${YELLOW}⚠ Domain configuration mismatch${NC}"
                        echo "  Consider using --remove-domain to recreate with correct configuration"
                        log_message "Domain configuration mismatch"
                        return 1
                    else
                        echo -e "${RED}✗ Domain validation failed${NC}"
                        log_message "Domain validation failed with code: $validation_result"
                        return 1
                    fi
                fi
                ;;
                
            remove)
                echo -e "${YELLOW}⚠ Removing existing domain${NC}"
                log_message "Removing domain '$sanitized'"
                
                if handle_existing_domain "$sanitized" "recreate"; then
                    echo -e "${GREEN}✓ Domain removed successfully${NC}"
                    log_message "Domain removed successfully"
                else
                    echo -e "${RED}✗ Failed to remove domain${NC}"
                    log_message "Failed to remove domain"
                    return 1
                fi
                ;;
                
            *)
                echo -e "${RED}✗ Unknown domain handling option: $handle_domain${NC}"
                log_message "Unknown domain handling option: $handle_domain"
                return 1
                ;;
        esac
    else
        log_message "Domain '$sanitized' does not exist"
        echo -e "${CYAN}ℹ Domain does not exist, will be created${NC}"
    fi
    
    # Clean up volumes only if domain was removed or doesn't exist
    if [ "$handle_domain" = "remove" ] || ! check_domain_exists "$sanitized"; then
        echo "Cleaning up volumes..."
        
        local volumes=(
            "cloudinit-${sanitized}.iso"
            "ubuntu-disk-${sanitized}.qcow2"
            "ubuntu-base-img-${sanitized}.qcow2"
        )
        
        for vol in "${volumes[@]}"; do
            if sudo virsh vol-info "$vol" --pool "$pool_name" >/dev/null 2>&1; then
                echo "  Removing: $vol"
                log_message "Removing volume: $vol"
                sudo virsh vol-delete "$vol" --pool "$pool_name" 2>/dev/null || true
            fi
        done
        
        echo "✓ Volume cleanup complete"
        log_message "Volume cleanup completed"
    else
        echo "Skipping volume cleanup (domain preserved)"
        log_message "Volume cleanup skipped - domain preserved"
    fi
    
    echo "Cleanup Process Done"
    log_message "Cleanup process completed"
    return 0
}

# Default values
ACTION="apply"
AUTO_APPROVE=false
SKIP_PREFLIGHT=false
SKIP_PLAN=false
FORCE_CLEANUP=false
DOMAIN_HANDLING="check"  # check, preserve, remove

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cleanup)
            FORCE_CLEANUP=true
            shift
            ;;
        --preserve-domain)
            DOMAIN_HANDLING="preserve"
            shift
            ;;
        --remove-domain)
            DOMAIN_HANDLING="remove"
            FORCE_CLEANUP=true
            shift
            ;;
        --check-domain)
            DOMAIN_HANDLING="check"
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
  --preserve-domain Preserve existing domain (skip recreation)
  --remove-domain   Remove and recreate domain
  --check-domain    Check domain status (default)
  -h, --help        Show this help message

${CYAN}Examples:${NC}
  $0 plan                                    # Generate plan
  $0 apply                                   # Apply with confirmation
  $0 apply --auto-approve                    # Apply without confirmation
  $0 apply --auto-approve --preserve-domain  # Apply and preserve existing domain
  $0 destroy --auto-approve                  # Destroy without confirmation

${CYAN}Workflow:${NC}
  1. Pre-flight checks (system validation)
  2. Domain existence check and handling
  3. Terraform initialization
  4. Plan generation
  5. Apply/Destroy execution
  6. Post-deployment verification

${CYAN}Domain Preservation:${NC}
  When using ${GREEN}--preserve-domain${NC}, the script will:
  - Check if domain already exists
  - Validate domain configuration (memory, vCPUs)
  - Verify domain state (running, shut off, paused)
  - Attempt to reuse domain if valid
  - Start/resume domain if needed
  - Skip volume recreation to preserve data

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
echo -e "${CYAN}Domain handling: ${YELLOW}$DOMAIN_HANDLING${NC}"
echo -e "${CYAN}Working directory: ${YELLOW}$PROJECT_ROOT${NC}"
echo ""

log_message "=== Deployment Started ==="
log_message "Action: $ACTION"
log_message "Auto-approve: $AUTO_APPROVE"
log_message "Domain handling: $DOMAIN_HANDLING"
log_message "Working directory: $PROJECT_ROOT"

sleep 2

# Add before terraform init
echo "=== Cleaning Old Detection Files ==="
rm -f terraform-kvm-ubuntu/.virt_type
rm -f terraform-kvm-ubuntu/.emulator_path
rm -f terraform-kvm-ubuntu/.kvm_type
rm -f "$PROJECT_ROOT/.domain_name"
echo "✓ Detection files cleaned"
log_message "Detection files cleaned"
echo ""

# Get VM hostname from terraform variables
VM_HOSTNAME="k3s-master-01"  # Default value

# Try to get from example.tfvars
# if [ -f "$PROJECT_ROOT/example.tfvars" ]; then
#     EXTRACTED_HOSTNAME=$(grep -E '^\s*vm_hostname\s*=' "$PROJECT_ROOT/example.tfvars" 2>/dev/null | cut -d'"' -f2 || echo "")
#     if [ -n "$EXTRACTED_HOSTNAME" ]; then
#         VM_HOSTNAME="$EXTRACTED_HOSTNAME"
#     fi
# fi

# Try to get from terraform.tfvars if exists
if [ -f "$PROJECT_ROOT/terraform.tfvars" ]; then
    EXTRACTED_HOSTNAME=$(grep -E '^\s*vm_hostname\s*=' "$PROJECT_ROOT/terraform.tfvars" 2>/dev/null | cut -d'"' -f2 || echo "")
    if [ -n "$EXTRACTED_HOSTNAME" ]; then
        VM_HOSTNAME="$EXTRACTED_HOSTNAME"
    fi
fi

echo -e "${CYAN}Target VM hostname: ${YELLOW}$VM_HOSTNAME${NC}"
log_message "Target VM hostname: $VM_HOSTNAME"
echo ""

# Domain management logic
DOMAIN_MANAGEMENT_NEEDED=false
DOMAIN_MANAGEMENT_SUCCESS=false

# Determine if domain management is needed
if [ "$FORCE_CLEANUP" = true ] || [ "$DOMAIN_HANDLING" != "check" ]; then
    DOMAIN_MANAGEMENT_NEEDED=true
fi

# If auto-approve is set with preserve-domain, we should handle it automatically
if [ "$AUTO_APPROVE" = true ] && [ "$DOMAIN_HANDLING" = "preserve" ]; then
    DOMAIN_MANAGEMENT_NEEDED=true
fi

# Add cleanup/domain check before terraform
if [ "$DOMAIN_MANAGEMENT_NEEDED" = true ]; then
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              Domain and Volume Management              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    log_message "Starting domain/volume management for $VM_HOSTNAME"
    log_message "Domain handling mode: $DOMAIN_HANDLING"
    
    if cleanup_volumes "$VM_HOSTNAME" "k3s_infra_pool" "$DOMAIN_HANDLING"; then
        echo -e "${GREEN}✓ Domain/volume management completed successfully${NC}"
        log_message "Domain/volume management completed successfully"
        DOMAIN_MANAGEMENT_SUCCESS=true
        
        # If domain was preserved, skip terraform apply for domain creation
        if [ "$DOMAIN_HANDLING" = "preserve" ]; then
            echo -e "${CYAN}ℹ Domain preserved, Terraform will detect existing resources${NC}"
            log_message "Domain preserved, continuing with Terraform"

            cd "$PROJECT_ROOT"
            
            # Initialize Terraform if needed
            echo "Initializing and upgrading Terraform..."
            log_message "Initializing and upgrading Terraform"
            if bash "$SCRIPT_DIR/terraform_init_upgrade.sh"; then
                echo -e "${GREEN}✓ Terraform initialization and upgrade successful${NC}"
                log_message "Terraform initialization and upgrade successful"
            else
                echo -e "${RED}✗ Terraform initialization and upgrade failed${NC}"
                log_message "Terraform initialization and upgrade failed"
                exit 1
            fi

            # Get sanitized domain name
            local sanitized=""
            if [ -f "$PROJECT_ROOT/.domain_name" ]; then
                sanitized=$(cat "$PROJECT_ROOT/.domain_name")
                log_message "Retrieved sanitized domain name: $sanitized"
            else
                sanitized=$(echo "$VM_HOSTNAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
                log_message "Generated sanitized domain name: $sanitized"
            fi

            # Try to import domain
            EXISTING_UUID=$(sudo virsh domuuid "$sanitized" 2>/dev/null || echo "")
            if [ -n "$EXISTING_UUID" ]; then
                echo "Importing domain with UUID: $EXISTING_UUID"
                log_message "Attempting to import domain UUID: $EXISTING_UUID"
                
                # Remove from state if already exists with different UUID
                terraform state rm libvirt_domain.ubuntu_vm 2>/dev/null || true
                
                # Import domain
                if terraform import -var-file=example.tfvars libvirt_domain.ubuntu_vm "$EXISTING_UUID" 2>/dev/null; then
                    echo -e "${GREEN}✓ Domain imported to Terraform state${NC}"
                    log_message "Domain imported successfully"
                else
                    echo -e "${YELLOW}⚠ Could not import domain, Terraform will manage it${NC}"
                    log_message "Domain import failed, continuing anyway"
                fi
            else
                echo -e "${YELLOW}⚠ Could not retrieve domain UUID${NC}"
                log_message "Could not retrieve domain UUID for import"
            fi
        fi
    else
        # Domain management failed
        DOMAIN_MANAGEMENT_SUCCESS=false

        if [ "$DOMAIN_HANDLING" = "check" ] && [ "$AUTO_APPROVE" = false ]; then
            echo ""
            echo -e "${CYAN}Domain already exists. What would you like to do?${NC}"
            echo "  1) Preserve and reuse existing domain (recommended)"
            echo "  2) Remove and recreate domain"
            echo "  3) Abort deployment"
            echo ""
            read -p "Enter choice [1-3]: " -n 1 -r CHOICE
            echo ""

            log_message "User prompted for domain handling choice"

            case $CHOICE in
                1)
                    DOMAIN_HANDLING="preserve"
                    log_message "User chose to preserve domain"
                    # Retry with preserve option
                    if cleanup_volumes "$VM_HOSTNAME" "k3s_infra_pool" "$DOMAIN_HANDLING"; then
                        DOMAIN_MANAGEMENT_SUCCESS=true
                        echo -e "${GREEN}✓ Domain preserved successfully${NC}"
                        log_message "Domain preserved on retry"
                    else
                        echo -e "${RED}✗ Failed to preserve domain${NC}"
                        log_message "Failed to preserve domain on retry"
                        exit 1
                    fi
                    ;;
                2)
                    DOMAIN_HANDLING="remove"
                    FORCE_CLEANUP=true
                    log_message "User chose to remove domain"
                    # Retry with remove option
                    if cleanup_volumes "$VM_HOSTNAME" "k3s_infra_pool" "$DOMAIN_HANDLING"; then
                        DOMAIN_MANAGEMENT_SUCCESS=true
                        echo -e "${GREEN}✓ Domain removed successfully${NC}"
                        log_message "Domain removed on retry"
                    else
                        echo -e "${RED}✗ Failed to remove domain${NC}"
                        log_message "Failed to remove domain on retry"
                        exit 1
                    fi
                    ;;
                3)
                    echo "Deployment aborted by user"
                    log_message "Deployment aborted by user"
                    exit 0
                    ;;
                *)
                    echo -e "${RED}Invalid choice, aborting${NC}"
                    log_message "Invalid choice entered, aborting"
                    exit 1
                    ;;
            esac
            
        elif [ "$DOMAIN_HANDLING" = "check" ] && [ "$AUTO_APPROVE" = true ]; then
            # Auto-approve mode but domain exists and no handling specified
            echo -e "${YELLOW}⚠ Domain exists but no handling option specified${NC}"
            echo -e "${CYAN}ℹ When using --auto-approve, you must specify domain handling:${NC}"
            echo "  - Use ${GREEN}--preserve-domain${NC} to reuse existing domain"
            echo "  - Use ${GREEN}--remove-domain${NC} to recreate domain"
            log_message "Domain exists, user action required"
            exit 1
        else
            echo -e "${RED}✗ Domain/volume management failed${NC}"
            log_message "Domain/volume management failed"
            exit 1
        fi
    fi
    echo ""
fi

# Step 0: Pre-flight validation
echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          Step 0: Initial Environment Check             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check dependencies
for cmd in sudo virsh terraform jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}❌ Error: '$cmd' is not installed or not in PATH${NC}"
        exit 1
    fi
done
print_status "ok" "All required tools are installed (virsh, terraform, jq)"

# Check libvirt connection
if ! sudo virsh -c qemu:///system uri &>/dev/null; then
    echo -e "${RED}❌ Error: Cannot connect to libvirt. Is libvirtd running?${NC}"
    echo -e "${YELLOW}Try: sudo systemctl start libvirtd${NC}"
    exit 1
fi
print_status "ok" "Connected to libvirt daemon"

# Check log directory permissions
if [ ! -w "$LOG_DIR" ]; then
    echo -e "${YELLOW}⚠ Warning: Log directory $LOG_DIR is not writable, attempting to fix...${NC}"
    mkdir -p "$LOG_DIR" && chmod 755 "$LOG_DIR" || {
        echo -e "${RED}❌ Error: Cannot create or write to log directory${NC}"
        exit 1
    }
fi
print_status "ok" "Log directory is ready: $LOG_DIR"
echo ""

# Step 1: Pre-flight checks
if [ "$SKIP_PREFLIGHT" = false ]; then
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                  Step 1: Pre-Flight Checks             ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    log_message "Starting pre-flight checks"
    
    if bash "$SCRIPT_DIR/run-preflight.sh"; then
        echo -e "${GREEN}✅ Pre-flight checks passed${NC}"
        log_message "Pre-flight checks passed"
    else
        echo -e "${RED}❌ Pre-flight checks failed${NC}"
        log_message "Pre-flight checks failed"
        exit 1
    fi
    echo ""
    sleep 2
else
    echo -e "${YELLOW}⚠️  Skipping pre-flight checks${NC}"
    log_message "Pre-flight checks skipped"
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
            log_message "Plan generated successfully"
            exit 0
        else
            echo -e "${RED}❌ Plan generation failed${NC}"
            log_message "Plan generation failed"
            exit 1
        fi
        ;;
        
    apply)
        echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                  Step 2: Apply Changes                 ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""

        log_message "Starting Terraform apply"

        APPLY_ARGS=""
        if [ "$AUTO_APPROVE" = true ]; then
            APPLY_ARGS="--auto-approve"
            log_message "Auto-approve enabled"
        fi
        
        # Add skip-plan if requested
        if [ "$SKIP_PLAN" = true ]; then
            APPLY_ARGS="$APPLY_ARGS --skip-plan"
            log_message "Skip plan enabled"
        fi

        # Retry mechanism
        MAX_RETRIES=3
        RETRY_COUNT=0
        SUCCESS=false
        
        while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            if [ $RETRY_COUNT -gt 0 ]; then
                echo -e "${YELLOW}⚠️  Retry attempt $((RETRY_COUNT+1))/${MAX_RETRIES}...${NC}"
                log_message "Retry attempt $((RETRY_COUNT+1))/${MAX_RETRIES}"
                echo "Waiting 10 seconds before retrying..."
                sleep 10
            fi

            log_message "Executing terraform_apply.sh with args: $APPLY_ARGS"

            if bash "$SCRIPT_DIR/terraform_apply.sh" $APPLY_ARGS; then
                SUCCESS=true
                log_message "Terraform apply succeeded"
                break
            else
                echo -e "${RED}❌ Deployment attempt $((RETRY_COUNT+1)) failed${NC}"
                log_message "Deployment attempt $((RETRY_COUNT+1)) failed"
                RETRY_COUNT=$((RETRY_COUNT + 1))
            fi
        done
        
        if [ "$SUCCESS" = true ]; then
            echo -e "${GREEN}✅ Deployment completed successfully${NC}"
            log_message "=== Deployment Completed Successfully ==="

            # Show summary
            echo ""
            echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                  Deployment Summary                    ║${NC}"
            echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${CYAN}VM Hostname:${NC} $VM_HOSTNAME"
            echo -e "${CYAN}Domain Handling:${NC} $DOMAIN_HANDLING"
            echo -e "${CYAN}Log File:${NC} $LOG_FILE"
            echo ""
            
            # Show connection info if available
            if [ -f "$PROJECT_ROOT/terraform.tfstate" ]; then
                echo -e "${CYAN}Connection Information:${NC}"
                cd "$PROJECT_ROOT"
                terraform output -json 2>/dev/null | jq -r '.ssh_connection.value // empty' || echo "  Run 'terraform output' to see connection details"
            fi
            
            exit 0
        else
            echo -e "${RED}❌ Deployment failed after $MAX_RETRIES attempts${NC}"
            log_message "=== Deployment Failed after $MAX_RETRIES attempts ==="
            echo ""
            echo -e "${CYAN}Troubleshooting:${NC}"
            echo "  1. Check log file: $LOG_FILE"
            echo "  2. Verify domain status: virsh list --all"
            echo "  3. Check Terraform state: terraform state list"
            echo "  4. Try with --preserve-domain if domain exists"
            echo ""
            exit 1
        fi
        ;;
        
    destroy)
        echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                Step 2: Destroy Infrastructure          ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""

        log_message "Starting infrastructure destruction"

        DESTROY_ARGS=""
        if [ "$AUTO_APPROVE" = true ]; then
            DESTROY_ARGS="--auto-approve"
            log_message "Auto-approve enabled for destroy"
        fi
        
        if bash "$SCRIPT_DIR/terraform_destroy.sh" $DESTROY_ARGS; then
            echo -e "${GREEN}✅ Infrastructure destroyed successfully${NC}"
            log_message "=== Infrastructure Destroyed Successfully ==="

            # Cleanup domain if it still exists
            local sanitized=$(echo "$VM_HOSTNAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
            if sudo virsh dominfo "$sanitized" >/dev/null 2>&1; then
                echo ""
                echo -e "${YELLOW}⚠ Domain still exists, cleaning up...${NC}"
                log_message "Cleaning up remaining domain"
                
                sudo virsh destroy "$sanitized" 2>/dev/null || true
                sudo virsh undefine "$sanitized" --remove-all-storage 2>/dev/null || true
                
                echo -e "${GREEN}✓ Domain cleanup complete${NC}"
                log_message "Domain cleanup completed"
            fi

            exit 0
        else
            echo -e "${RED}❌ Destruction failed${NC}"
            log_message "=== Infrastructure Destruction Failed ==="
            exit 1
        fi
        ;;
esac