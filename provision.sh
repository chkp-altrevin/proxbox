#!/usr/bin/env bash
set -euo pipefail

# Global variables
LOG_FILE="/var/log/provision.log"
SCRIPT_PID=$$
CLEANUP_VMID=""
TEMP_FILES=()

# Configuration defaults
TEMPLATE_DEFAULT_VMID=9800
STORAGE="local-lvm"
CI_USER="ubuntu"
CI_SSH_KEY_PATH="/root/.ssh/authorized_keys"
CI_VENDOR_SNIPPET="local:snippets/vendor.yaml"
CI_TAGS="ubuntu-template,24.04,cloudinit"
CI_BOOT_ORDER="virtio0"
IMAGE_SIZE="40G"
DEFAULT_CORES=1
DEFAULT_MEMORY=2048
DEFAULT_SOCKETS=1
DEFAULT_OSTYPE="l26"
DEFAULT_BIOS="ovmf"
DEFAULT_MACHINE="q35"
DEFAULT_CPU="host"
DEFAULT_VGA="serial0"
DEFAULT_SERIAL0="socket"
KIOSK_MODE=false
DRY_RUN=0

# VM info cache
declare -A VM_INFO_CACHE
CACHE_TIMESTAMP=0
CACHE_TTL=30  # 30 seconds

# ========== CLEANUP & ERROR HANDLING ==========
cleanup() {
    local exit_code=$?
    
    # Clean up temporary files
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "$temp_file" ]]; then
            rm -f "$temp_file"
        fi
    done
    
    # Clean up failed VM if needed
    if [[ -n "$CLEANUP_VMID" ]] && [[ $exit_code -ne 0 ]]; then
        cleanup_failed_vm "$CLEANUP_VMID"
    fi
    
    log "Script exiting with code $exit_code"
    exit $exit_code
}

cleanup_failed_vm() {
    local vmid="$1"
    if [[ $DRY_RUN -eq 0 ]]; then
        if command -v qm >/dev/null 2>&1; then
            if qm status "$vmid" >/dev/null 2>&1; then
                log "🧹 Cleaning up failed VM $vmid"
                qm stop "$vmid" 2>/dev/null || true
                qm destroy "$vmid" --purge 2>/dev/null || true
            fi
        fi
    fi
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

trap cleanup EXIT
trap 'error_exit "Script interrupted"' INT TERM

# ========== PRIVILEGE & ENVIRONMENT CHECKS ==========
check_environment() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root for Proxmox operations"
    fi
    
    # Check if log directory is writable
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [[ ! -w "$log_dir" ]]; then
        error_exit "Cannot write to log directory: $log_dir"
    fi
    
    # Check for required commands
    local required_commands=("qm" "pvesm" "qemu-img")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error_exit "Required command not found: $cmd"
        fi
    done
    
    # Check available disk space (at least 10GB)
    local available_space
    available_space=$(df /var/lib/vz 2>/dev/null | awk 'NR==2 {print $4}' 2>/dev/null || echo "0")
    if [[ $available_space -lt 10485760 ]]; then  # 10GB in KB
        log "⚠️  Warning: Low disk space available (less than 10GB)"
    fi
}

# ========== CONFIGURATION LOADING ==========
load_configuration() {
    # Load environment configuration with proper precedence
    if [[ -f ".env" ]]; then
        # Validate .env file before sourcing
        if bash -n .env; then
            set -a  # Export all variables
            source .env
            set +a
            log "📄 Loaded configuration from .env"
        else
            log "⚠️  Warning: .env file has syntax errors, skipping"
        fi
    fi
}

# ========== LOGGING ==========
log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" | tee -a "$LOG_FILE"
}

# ========== INPUT VALIDATION ==========
validate_vmid() {
    local vmid="$1"
    
    # Check if numeric
    if ! [[ "$vmid" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid VMID: $vmid (must be numeric)"
    fi
    
    # Check range (100-999999999)
    if [[ $vmid -lt 100 ]] || [[ $vmid -gt 999999999 ]]; then
        error_exit "VMID $vmid out of valid range (100-999999999)"
    fi
    
    # Check if already exists (always validate, even in dry-run)
    if command -v qm >/dev/null 2>&1; then
        if qm status "$vmid" >/dev/null 2>&1; then
            error_exit "VMID $vmid already exists"
        fi
    fi
}

validate_memory() {
    local memory="$1"
    if ! [[ "$memory" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid memory value: $memory (must be numeric)"
    fi
    if [[ $memory -lt 128 ]] || [[ $memory -gt 1048576 ]]; then  # 128MB to 1TB
        error_exit "Memory $memory out of valid range (128-1048576 MB)"
    fi
}

validate_cores() {
    local cores="$1"
    if ! [[ "$cores" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid cores value: $cores (must be numeric)"
    fi
    if [[ $cores -lt 1 ]] || [[ $cores -gt 256 ]]; then
        error_exit "Cores $cores out of valid range (1-256)"
    fi
}

validate_storage() {
    local storage="$1"
    if [[ $DRY_RUN -eq 0 ]]; then
        if ! pvesm status "$storage" >/dev/null 2>&1; then
            error_exit "Storage '$storage' not found or not available"
        fi
    fi
}

validate_filename() {
    local filename="$1"
    # Check for path traversal
    if [[ "$filename" =~ \.\./|^/ ]]; then
        error_exit "Invalid filename: $filename (contains path traversal)"
    fi
    # Check for dangerous characters
    if [[ "$filename" =~ [\|\;\&\$\`\\] ]]; then
        error_exit "Invalid filename: $filename (contains dangerous characters)"
    fi
}

validate_url() {
    local url="$1"
    if ! [[ "$url" =~ ^https?:// ]]; then
        error_exit "Invalid URL: $url (must start with http:// or https://)"
    fi
}

# ========== VM INFO CACHING ==========
should_refresh_cache() {
    local current_time
    current_time=$(date +%s)
    (( current_time - CACHE_TIMESTAMP > CACHE_TTL ))
}

build_vm_info_cache() {
    if ! should_refresh_cache && [[ ${#VM_INFO_CACHE[@]} -gt 0 ]]; then
        return 0
    fi
    
    log "🔄 Refreshing VM info cache..."
    
    # Clear existing cache
    unset VM_INFO_CACHE
    declare -gA VM_INFO_CACHE
    
    if ! command -v qm >/dev/null 2>&1; then
        log "⚠️  Proxmox tools not available for caching"
        return 1
    fi
    
    # Get all VMIDs efficiently
    local vm_list
    vm_list=$(qm list 2>/dev/null || echo "")
    
    if [[ -z "$vm_list" ]]; then
        return 1
    fi
    
    # Parse VMIDs
    local vmids
    mapfile -t vmids < <(echo "$vm_list" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}')
    
    # Build info cache in batch
    for vmid in "${vmids[@]}"; do
        local vm_line
        vm_line=$(echo "$vm_list" | awk -v vmid="$vmid" '$1 == vmid {print $0}')
        
        # Extract info from qm list output
        local name status memory
        name=$(echo "$vm_line" | awk '{print $2}')
        status=$(echo "$vm_line" | awk '{print $3}')
        memory=$(echo "$vm_line" | awk '{print $4}')
        
        # Check if template
        local is_template="false"
        if [[ -f "/etc/pve/qemu-server/${vmid}.conf" ]]; then
            if grep -q "^template:" "/etc/pve/qemu-server/${vmid}.conf" 2>/dev/null; then
                is_template="true"
            fi
        fi
        
        # Store in cache
        VM_INFO_CACHE["${vmid}_name"]="$name"
        VM_INFO_CACHE["${vmid}_status"]="$status"
        VM_INFO_CACHE["${vmid}_memory"]="$memory"
        VM_INFO_CACHE["${vmid}_is_template"]="$is_template"
        VM_INFO_CACHE["${vmid}_line"]="$vm_line"
    done
    
    CACHE_TIMESTAMP=$(date +%s)
    log "✅ VM info cache updated (${#vmids[@]} entries)"
}

get_vm_info() {
    local vmid="$1"
    local field="$2"
    
    build_vm_info_cache
    echo "${VM_INFO_CACHE["${vmid}_${field}"]:-}"
}

get_all_vmids() {
    build_vm_info_cache
    local vmids=()
    for key in "${!VM_INFO_CACHE[@]}"; do
        if [[ "$key" =~ ^([0-9]+)_name$ ]]; then
            vmids+=("${BASH_REMATCH[1]}")
        fi
    done
    printf '%s\n' "${vmids[@]}" | sort -n
}

# ========== UTILITY FUNCTIONS ==========
run_or_dry() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] $*"
    else
        log "Executing: $*"
        eval "$@"
    fi
}

get_next_vmid() {
    if command -v pvesh >/dev/null 2>&1; then
        local next_id
        next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "")
        if [[ -n "$next_id" ]] && [[ "$next_id" =~ ^[0-9]+$ ]]; then
            echo "$next_id"
        else
            echo "100"
        fi
    else
        echo "100"
    fi
}

download_image() {
    local url="$1"
    
    validate_url "$url"
    
    local filename
    filename=$(basename "$url")
    validate_filename "$filename"
    
    # Ensure filename has proper extension
    if ! [[ "$filename" =~ \.(iso|img|qcow2)$ ]]; then
        filename="${filename}.img"
    fi
    
    # Check if file already exists
    if [[ -f "$filename" ]]; then
        log "📁 Image file already exists: $filename"
        read -p "Overwrite existing file? [y/N]: " -r overwrite
        if [[ ! "${overwrite,,}" == "y" ]]; then
            IMAGE="$filename"
            return 0
        fi
    fi
    
    log "📥 Downloading image from URL: $url"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] curl -fSL '$url' -o '$filename'"
        IMAGE="$filename"
    else
        # Create temp file first, then move on success
        local temp_file
        temp_file=$(mktemp "${filename}.XXXXXX")
        TEMP_FILES+=("$temp_file")
        
        if curl -fSL --connect-timeout 30 --max-time 3600 --progress-bar "$url" -o "$temp_file"; then
            mv "$temp_file" "$filename"
            IMAGE="$filename"
            log "✅ Download completed: $filename"
            
            # Remove from temp files array since we moved it
            TEMP_FILES=("${TEMP_FILES[@]/$temp_file}")
        else
            error_exit "Failed to download image from $url"
        fi
    fi
}

create_vendor_snippet() {
    local snippet_path="/var/lib/vz/snippets/vendor.yaml"
    
    if [[ ! -f "$snippet_path" ]] && [[ $DRY_RUN -eq 0 ]]; then
        log "🧩 Creating cloud-init vendor snippet..."
        
        local snippet_dir
        snippet_dir=$(dirname "$snippet_path")
        if [[ ! -d "$snippet_dir" ]]; then
            mkdir -p "$snippet_dir"
        fi
        
        cat > "$snippet_path" <<'EOF'
#cloud-config
runcmd:
  - apt update
  - apt install -y qemu-guest-agent
  - systemctl start qemu-guest-agent
  - systemctl enable qemu-guest-agent
EOF
        log "✅ Vendor snippet created at $snippet_path"
    elif [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] Would create vendor snippet at $snippet_path"
    fi
}

# ========== KIOSK MODE FUNCTIONS ==========
clear_screen() {
    clear
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                      🏗️  PROXMOX TEMPLATE PROVISIONER                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
}

show_current_status() {
    echo "📊 Current Configuration:"
    echo "   Storage: $STORAGE"
    echo "   Default Memory: ${MEMORY:-$DEFAULT_MEMORY}MB"
    echo "   Default Cores: ${CORES:-$DEFAULT_CORES}"
    echo "   CI User: $CI_USER"
    echo "   Image Size: $IMAGE_SIZE"
    echo "   Dry Run: $([ $DRY_RUN -eq 1 ] && echo "Enabled" || echo "Disabled")"
    echo ""
    
    # Show recent VMs/Templates
    echo "📋 Recent VMs/Templates:"
    if build_vm_info_cache; then
        local count=0
        while IFS= read -r vmid; do
            if [[ $count -ge 5 ]]; then break; fi
            local name status is_template
            name=$(get_vm_info "$vmid" "name")
            status=$(get_vm_info "$vmid" "status")
            is_template=$(get_vm_info "$vmid" "is_template")
            
            local type_icon="🖥️ "
            if [[ "$is_template" == "true" ]]; then
                type_icon="📋"
            fi
            
            printf "   %s %s %-20s %s\n" "$type_icon" "$vmid" "$name" "$status"
            ((count++))
        done < <(get_all_vmids | tail -5)
    else
        echo "   ⚠️  Unable to retrieve VM information"
    fi
    echo ""
}

kiosk_pause() {
    echo ""
    echo -n "Press Enter to continue..."
    read -r
}

# ========== IMAGE DISCOVERY ==========
discover_images() {
    local -a image_list=()
    local -a image_display=()
    
    # Check common Proxmox ISO storage locations
    local iso_paths=(
        "/var/lib/vz/template/iso"
        "/var/lib/vz/template/cache" 
    )
    
    # Add expanded paths for mounted storage
    for path in /mnt/pve/*/template/iso /mnt/pve/*/template/cache; do
        if [[ -d "$path" ]]; then
            iso_paths+=("$path")
        fi
    done
    
    local count=1
    for iso_path in "${iso_paths[@]}"; do
        if [[ -d "$iso_path" ]]; then
            while IFS= read -r -d '' file; do
                if [[ -f "$file" ]] && [[ "$file" =~ \.(iso|img|qcow2)$ ]]; then
                    local filename
                    filename=$(basename "$file")
                    local filesize
                    filesize=$(du -h "$file" 2>/dev/null | cut -f1 || echo "Unknown")
                    image_list+=("$file")
                    image_display+=("$count) $filename ($filesize)")
                    ((count++))
                fi
            done < <(find "$iso_path" -maxdepth 1 -type f \( -name "*.iso" -o -name "*.img" -o -name "*.qcow2" \) -print0 2>/dev/null)
        fi
    done
    
    # Also check using pvesm if available
    if command -v pvesm >/dev/null 2>&1; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^([^:]+):(.+)$ ]]; then
                local storage="${BASH_REMATCH[1]}"
                local filename="${BASH_REMATCH[2]}"
                if [[ "$filename" =~ \.(iso|img|qcow2)$ ]]; then
                    local full_path="$storage:iso/$filename"
                    # Check if we haven't already added this file
                    local already_added=false
                    for existing in "${image_list[@]}"; do
                        if [[ "$(basename "$existing")" == "$filename" ]]; then
                            already_added=true
                            break
                        fi
                    done
                    if [[ "$already_added" == false ]]; then
                        image_list+=("$full_path")
                        image_display+=("$count) $filename (Proxmox storage: $storage)")
                        ((count++))
                    fi
                fi
            fi
        done < <(pvesm list local 2>/dev/null | grep -E '\.(iso|img|qcow2)' || true)
    fi
    
    # Return results through global arrays (bash limitation workaround)
    DISCOVERED_IMAGES=("${image_list[@]}")
    DISCOVERED_IMAGE_DISPLAY=("${image_display[@]}")
}

# Global arrays for image discovery
declare -a DISCOVERED_IMAGES=()
declare -a DISCOVERED_IMAGE_DISPLAY=()

select_image() {
    discover_images
    
    if [[ ${#DISCOVERED_IMAGES[@]} -gt 0 ]]; then
        echo "📁 Available Images:"
        for display_item in "${DISCOVERED_IMAGE_DISPLAY[@]}"; do
            echo "   $display_item"
        done
        echo ""
        echo "   0) Enter custom path or URL"
        echo ""
        echo -n "Select an image [0-$((${#DISCOVERED_IMAGES[@]}))] or press Enter for custom: "
        
        local image_choice
        read -r image_choice
        
        if [[ -n "$image_choice" ]] && [[ "$image_choice" =~ ^[0-9]+$ ]] && [[ "$image_choice" -gt 0 ]] && [[ "$image_choice" -le ${#DISCOVERED_IMAGES[@]} ]]; then
            # User selected a numbered option
            echo "${DISCOVERED_IMAGES[$((image_choice-1))]}"
        else
            # User wants to enter custom path
            echo ""
            echo -n "Enter custom image path or URL: "
            local custom_input
            read -r custom_input
            echo "$custom_input"
        fi
    else
        echo "   ⚠️  No images found in default locations"
        echo ""
        echo -n "Enter image path or URL: "
        local manual_input
        read -r manual_input
        echo "$manual_input"
    fi
}

# ========== PAGINATED VM LISTING ==========
paginated_vm_list() {
    local action_type="$1"  # "clone", "delete", "list"
    local selected_vmid=""
    
    if ! build_vm_info_cache; then
        echo "❌ Unable to retrieve VM information"
        return 1
    fi
    
    local -a vmids
    mapfile -t vmids < <(get_all_vmids)
    
    if [[ ${#vmids[@]} -eq 0 ]]; then
        echo "❌ No VMs or templates found"
        return 1
    fi
    
    # Pagination setup
    local page=1
    local items_per_page=20
    local total_count=${#vmids[@]}
    local total_pages=$(( (total_count + items_per_page - 1) / items_per_page ))
    
    while true; do
        clear_screen
        case "$action_type" in
            "clone") echo "🔄 Clone Existing VM/Template" ;;
            "delete") echo "🗑️  Delete VM/Template" ;;
            "list") echo "📋 All VMs and Templates" ;;
        esac
        echo ""
        
        # Warning for delete action
        if [[ "$action_type" == "delete" ]]; then
            echo "⚠️  WARNING: This will permanently delete the selected VM/Template!"
            echo ""
        fi
        
        # Calculate start and end indices for current page
        local start_idx=$(( (page - 1) * items_per_page ))
        local end_idx=$(( start_idx + items_per_page - 1 ))
        if [[ $end_idx -ge $total_count ]]; then
            end_idx=$(( total_count - 1 ))
        fi
        
        # Show header
        printf "   %-8s %-20s %-12s %-8s %s\n" "VMID" "NAME" "STATUS" "MEMORY" "TYPE"
        printf "   %s\n" "$(printf '%*s' 60 '' | tr ' ' '-')"
        
        # Display current page items
        for (( i=start_idx; i<=end_idx; i++ )); do
            local vmid="${vmids[$i]}"
            local name status memory is_template
            name=$(get_vm_info "$vmid" "name")
            status=$(get_vm_info "$vmid" "status")
            memory=$(get_vm_info "$vmid" "memory")
            is_template=$(get_vm_info "$vmid" "is_template")
            
            local type_display="🖥️  VM"
            if [[ "$is_template" == "true" ]]; then
                type_display="📋 Template"
            fi
            
            printf "   %-8s %-20s %-12s %-8s %s\n" "$vmid" "$name" "$status" "$memory" "$type_display"
        done
        
        echo ""
        echo "📊 Page $page of $total_pages (Total: $total_count items)"
        
        if [[ "$action_type" == "list" ]]; then
            # Count summary
            local template_count=0 vm_count=0
            for vmid in "${vmids[@]}"; do
                if [[ "$(get_vm_info "$vmid" "is_template")" == "true" ]]; then
                    ((template_count++))
                else
                    ((vm_count++))
                fi
            done
            echo "📈 Summary: $vm_count VMs, $template_count Templates"
        fi
        
        echo ""
        
        # Navigation options
        local nav_options="Navigation: "
        if [[ $page -gt 1 ]]; then
            nav_options+="[P]revious  "
        fi
        if [[ $page -lt $total_pages ]]; then
            nav_options+="[N]ext  "
        fi
        
        if [[ "$action_type" != "list" ]]; then
            nav_options+="[S]elect VMID  "
        fi
        nav_options+="[Q]uit"
        
        echo "$nav_options"
        echo ""
        echo -n "Choose action: "
        
        local action
        read -r action
        action=$(echo "$action" | tr '[:upper:]' '[:lower:]')
        
        case "$action" in
            p|prev|previous)
                if [[ $page -gt 1 ]]; then
                    ((page--))
                else
                    echo "❌ Already on first page"
                    sleep 1
                fi
                ;;
            n|next)
                if [[ $page -lt $total_pages ]]; then
                    ((page++))
                else
                    echo "❌ Already on last page"
                    sleep 1
                fi
                ;;
            s|select)
                if [[ "$action_type" != "list" ]]; then
                    echo ""
                    echo -n "Enter VMID: "
                    read -r selected_vmid
                    if [[ -n "$selected_vmid" ]]; then
                        echo "$selected_vmid"
                        return 0
                    fi
                else
                    echo "❌ Select not available in list mode"
                    sleep 2
                fi
                ;;
            q|quit)
                if [[ "$action_type" == "list" ]]; then
                    return 0  # Return success for list mode
                else
                    return 1  # Return failure for clone/delete modes
                fi
                ;;
            [0-9]*)
                if [[ "$action_type" != "list" ]] && [[ "$action" =~ ^[0-9]+$ ]]; then
                    # Check if VMID exists
                    for vmid in "${vmids[@]}"; do
                        if [[ "$vmid" == "$action" ]]; then
                            echo "$action"
                            return 0
                        fi
                    done
                    echo "❌ VMID $action not found in the list"
                    sleep 2
                else
                    echo "❌ Invalid option"
                    sleep 2
                fi
                ;;
            *)
                echo "❌ Invalid option"
                sleep 2
                ;;
        esac
    done
}

# ========== KIOSK MENU FUNCTIONS ==========
kiosk_menu() {
    while true; do
        clear_screen
        show_current_status
        
        echo "🎛️  Main Menu - Select an action:"
        echo ""
        echo "   1) 📁 Create Template from Image    - Build template from ISO/IMG"
        echo "   2) 🖥️  Provision VM from Image      - Create VM from ISO/IMG"
        echo "   3) 🔄 Clone Existing VM/Template   - Clone from existing VMID"
        echo "   4) 📋 List All VMs/Templates       - Show all VMIDs"
        echo "   5) 🗑️  Delete VM/Template           - Remove by VMID"
        echo "   6) ⚙️  Settings                     - Configure defaults"
        echo "   7) 📖 Show Examples                - Usage examples"
        echo "   0) 🚪 Exit                         - Quit kiosk mode"
        echo ""
        echo -n "Enter your choice [0-7]: "
        
        local choice
        read -r choice
        
        case "$choice" in
            1) kiosk_create_template ;;
            2) kiosk_provision_vm ;;
            3) kiosk_clone_vm ;;
            4) kiosk_list_vms ;;
            5) kiosk_delete_vm ;;
            6) kiosk_settings ;;
            7) show_examples; kiosk_pause ;;
            0) echo ""; echo "👋 Exiting. Goodbye!"; exit 0 ;;
            *) echo ""; echo "❌ Invalid choice. Please select 0-7."; sleep 2 ;;
        esac
    done
}

kiosk_create_template() {
    clear_screen
    echo "📁 Create Template from Image"
    echo ""
    
    local image_input
    image_input=$(select_image)
    
    if [[ -z "$image_input" ]]; then
        echo "❌ Image path/URL cannot be empty"
        kiosk_pause
        return
    fi
    
    # Get VMID
    local suggested_vmid
    suggested_vmid=$(get_next_vmid)
    echo ""
    echo -n "Enter VMID [$suggested_vmid]: "
    read -r vmid_input
    vmid_input=${vmid_input:-$suggested_vmid}
    
    # Get template name
    echo -n "Enter template name [ubuntu-template]: "
    read -r name_input
    name_input=${name_input:-ubuntu-template}
    
    # Advanced options prompt
    echo ""
    echo "⚙️  Configure advanced options? [y/N]: "
    read -r advanced_config
    
    local memory_config="${MEMORY:-$DEFAULT_MEMORY}"
    local cores_config="${CORES:-$DEFAULT_CORES}"
    local storage_config="$STORAGE"
    
    if [[ "${advanced_config,,}" == "y" ]]; then
        echo ""
        echo "📊 Advanced Configuration:"
        echo -n "Memory (MB) [$memory_config]: "
        read -r new_memory
        if [[ -n "$new_memory" ]]; then
            memory_config="$new_memory"
        fi
        
        echo -n "CPU Cores [$cores_config]: "
        read -r new_cores
        if [[ -n "$new_cores" ]]; then
            cores_config="$new_cores"
        fi
        
        echo -n "Storage [$storage_config]: "
        read -r new_storage
        if [[ -n "$new_storage" ]]; then
            storage_config="$new_storage"
        fi
    fi
    
    echo ""
    echo "📋 Template Configuration:"
    echo "   Image: $(basename "$image_input")"
    echo "   VMID: $vmid_input"
    echo "   Name: $name_input"
    echo "   Storage: $storage_config"
    echo "   Memory: ${memory_config}MB"
    echo "   Cores: $cores_config"
    echo ""
    echo -n "Create template? [Y/n]: "
    
    local confirm