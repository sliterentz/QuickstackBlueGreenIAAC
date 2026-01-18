#!/bin/bash

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Function to check if domain exists
check_domain_exists() {
    local domain_name="$1"
    
    if sudo virsh dominfo "$domain_name" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to get domain state
get_domain_state() {
    local domain_name="$1"
    
    if ! check_domain_exists "$domain_name"; then
        echo "not_found"
        return 1
    fi
    
    local state=$(sudo virsh domstate "$domain_name" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    echo "$state"
}

# Function to validate domain configuration
validate_domain_config() {
    local domain_name="$1"
    local expected_memory="${2:-4194304}"  # Default 4GB in KB
    local expected_vcpus="${3:-2}"
    
    echo -e "${CYAN}Validating domain configuration for: $domain_name${NC}"
    
    if ! check_domain_exists "$domain_name"; then
        echo -e "${RED}✗ Domain does not exist${NC}"
        return 1
    fi
    
    # Get current configuration
    local current_memory=$(sudo virsh dominfo "$domain_name" | grep "Max memory:" | awk '{print $3}')
    local current_vcpus=$(sudo virsh dominfo "$domain_name" | grep "CPU(s):" | awk '{print $2}')
    
    echo -e "${BLUE}Current configuration:${NC}"
    echo "  Memory: ${current_memory} KB"
    echo "  vCPUs: ${current_vcpus}"
    
    # Validate memory (allow 10% tolerance)
    local memory_diff=$((expected_memory - current_memory))
    local memory_tolerance=$((expected_memory / 10))
    
    if [ ${memory_diff#-} -gt $memory_tolerance ]; then
        echo -e "${YELLOW}⚠ Memory mismatch (expected: ${expected_memory} KB)${NC}"
        return 2
    fi
    
    # Validate vCPUs
    if [ "$current_vcpus" != "$expected_vcpus" ]; then
        echo -e "${YELLOW}⚠ vCPU mismatch (expected: ${expected_vcpus})${NC}"
        return 2
    fi
    
    echo -e "${GREEN}✓ Domain configuration is valid${NC}"
    return 0
}

# Function to handle existing domain
handle_existing_domain() {
    local domain_name="$1"
    local action="${2:-reuse}"  # reuse, recreate, or abort
    
    echo -e "${CYAN}Handling existing domain: $domain_name${NC}"
    
    local state=$(get_domain_state "$domain_name")
    echo "Current state: $state"
    
    case "$action" in
        reuse)
            case "$state" in
                "running")
                    echo -e "${GREEN}✓ Domain is running and will be reused${NC}"
                    return 0
                    ;;
                "shut off"|"shutoff")
                    echo -e "${YELLOW}⚠ Domain exists but is shut off${NC}"
                    echo "Attempting to start domain..."
                    if sudo virsh start "$domain_name" >/dev/null 2>&1; then
                        echo -e "${GREEN}✓ Domain started successfully${NC}"
                        return 0
                    else
                        echo -e "${RED}✗ Failed to start domain${NC}"
                        return 1
                    fi
                    ;;
                "paused")
                    echo -e "${YELLOW}⚠ Domain is paused${NC}"
                    echo "Resuming domain..."
                    if sudo virsh resume "$domain_name" >/dev/null 2>&1; then
                        echo -e "${GREEN}✓ Domain resumed successfully${NC}"
                        return 0
                    else
                        echo -e "${RED}✗ Failed to resume domain${NC}"
                        return 1
                    fi
                    ;;
                *)
                    echo -e "${RED}✗ Domain in unexpected state: $state${NC}"
                    return 1
                    ;;
            esac
            ;;
            
        recreate)
            echo -e "${YELLOW}⚠ Recreating domain...${NC}"
            
            # Stop domain if running
            if [ "$state" = "running" ]; then
                echo "Shutting down domain..."
                sudo virsh shutdown "$domain_name" >/dev/null 2>&1 || true
                sleep 5
                
                # Force destroy if still running
                if [ "$(get_domain_state "$domain_name")" = "running" ]; then
                    echo "Force destroying domain..."
                    sudo virsh destroy "$domain_name" >/dev/null 2>&1 || true
                fi
            fi
            
            # Undefine domain
            echo "Undefining domain..."
            sudo virsh undefine "$domain_name" --remove-all-storage >/dev/null 2>&1 || true
            
            echo -e "${GREEN}✓ Domain removed, ready for recreation${NC}"
            return 0
            ;;
            
        abort)
            echo -e "${RED}✗ Domain exists, aborting as requested${NC}"
            return 1
            ;;
            
        *)
            echo -e "${RED}✗ Unknown action: $action${NC}"
            return 1
            ;;
    esac
}

# Function to wait for domain to be ready
wait_for_domain_ready() {
    local domain_name="$1"
    local timeout="${2:-300}"  # 5 minutes default
    local interval=5
    local elapsed=0
    
    echo -e "${CYAN}Waiting for domain to be ready...${NC}"
    
    while [ $elapsed -lt $timeout ]; do
        local state=$(get_domain_state "$domain_name")
        
        if [ "$state" = "running" ]; then
            # Check if domain is responsive
            if sudo virsh domifaddr "$domain_name" >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Domain is ready${NC}"
                return 0
            fi
        fi
        
        echo -n "."
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo ""
    echo -e "${RED}✗ Timeout waiting for domain to be ready${NC}"
    return 1
}

# Function to get domain IP address
get_domain_ip() {
    local domain_name="$1"
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        local ip=$(sudo virsh domifaddr "$domain_name" 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1)
        
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        
        sleep 2
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Export functions
export -f check_domain_exists
export -f get_domain_state
export -f validate_domain_config
export -f handle_existing_domain
export -f wait_for_domain_ready
export -f get_domain_ip