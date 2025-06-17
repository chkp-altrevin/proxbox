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
CACHE_TTL=30

# ========== CLEANUP & ERROR HANDLING ==========
cleanup() {
    local exit_code=$?
    
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "$temp_file" ]]; then
            rm -f "$temp_file"
        fi
    done
    
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

# ========== ENVIRONMENT CHECKS ==========
check_environment() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root for Proxmox operations"
    fi
    
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [[ ! -w "$log_dir" ]]; then
        error_exit "Cannot write to log directory: $log_dir"
    fi
    
    local required_commands=("qm" "pvesm" "qemu-img")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error_exit "Required command not found: $cmd"
        fi
    done
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
    
    if ! [[ "$vmid" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid VMID: $vmid (must be numeric)"
    fi
    
    if [[ $vmid -lt 100 ]] || [[ $vmid -gt 999999999 ]]; then
        error_exit "VMID $vmid out of valid range (100-999999999)"
    fi
    
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
    if [[ $memory -lt 128 ]] || [[ $memory -gt 1048576 ]]; then
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
    
    unset VM_INFO_CACHE
    declare -gA VM_INFO_CACHE
    
    if ! command -v qm >/dev/null 2>&1; then
        log "⚠️  Proxmox tools not available for caching"
        return 1
    fi
    
    local vm_list
    vm_list=$(qm list 2>/dev/null || echo "")
    
    if [[ -z "$vm_list" ]]; then
        return 1
    fi
    
    local vmids
    mapfile -t vmids < <(echo "$vm_list" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}')
    
    for vmid in "${vmids[@]}"; do
        local vm_line
        vm_line=$(echo "$vm_list" | awk -v vmid="$vmid" '$1 == vmid {print $0}')
        
        local name status memory
        name=$(echo "$vm_line" | awk '{print $2}')
        status=$(echo "$vm_line" | awk '{print $3}')
        memory=$(echo "$vm_line" | awk '{print $4}')
        
        local is_template="false"
        if [[ -f "/etc/pve/qemu-server/${vmid}.conf" ]]; then
            if grep -q "^template:" "/etc/pve/qemu-server/${vmid}.conf" 2>/dev/null; then
                is_template="true"
            fi
        fi
        
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

# ========== SIMPLIFIED KIOSK FUNCTIONS ==========
kiosk_list_vms() {
    clear_screen
    echo "📋 All VMs and Templates"
    echo ""
    
    if build_vm_info_cache; then
        printf "   %-8s %-20s %-12s %-8s %s\n" "VMID" "NAME" "STATUS" "MEMORY" "TYPE"
        printf "   %s\n" "$(printf '%*s' 60 '' | tr ' ' '-')"
        
        while IFS= read -r vmid; do
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
        done < <(get_all_vmids)
    else
        echo "❌ Unable to retrieve VM information"
    fi
    
    kiosk_pause
}

kiosk_create_template() {
    clear_screen
    echo "📁 Create Template from Image"
    echo ""
    
    echo -n "Enter image path or URL: "
    read -r image_input
    
    if [[ -z "$image_input" ]]; then
        echo "❌ Image path/URL cannot be empty"
        kiosk_pause
        return
    fi
    
    local suggested_vmid
    suggested_vmid=$(get_next_vmid)
    echo -n "Enter VMID [$suggested_vmid]: "
    read -r vmid_input
    vmid_input=${vmid_input:-$suggested_vmid}
    
    echo -n "Enter template name [ubuntu-template]: "
    read -r name_input
    name_input=${name_input:-ubuntu-template}
    
    echo ""
    echo "📋 Template Configuration:"
    echo "   Image: $(basename "$image_input")"
    echo "   VMID: $vmid_input"
    echo "   Name: $name_input"
    echo ""
    echo -n "Create template? [Y/n]: "
    
    local confirm
    read -r confirm
    confirm=${confirm:-y}
    
    if [[ "${confirm,,}" == "y" ]]; then
        echo ""
        log "🏗️  Creating template from image..."
        
        IMAGE="$image_input"
        VMID="$vmid_input"
        VM_NAME="$name_input"
        PROVISION_VM=0
        
        create_template
        echo ""
        echo "✅ Template created successfully!"
        kiosk_pause
    fi
}

# ========== MAIN MENU ==========
kiosk_menu() {
    while true; do
        clear_screen
        show_current_status
        
        echo "🎛️  Main Menu - Select an action:"
        echo ""
        echo "   1) 📁 Create Template from Image"
        echo "   2) 📋 List All VMs/Templates"
        echo "   3) 📖 Show Examples"
        echo "   0) 🚪 Exit"
        echo ""
        echo -n "Enter your choice [0-3]: "
        
        local choice
        read -r choice
        
        case "$choice" in
            1) kiosk_create_template ;;
            2) kiosk_list_vms ;;
            3) show_examples; kiosk_pause ;;
            0) echo ""; echo "👋 Exiting. Goodbye!"; exit 0 ;;
            *) echo ""; echo "❌ Invalid choice. Please select 0-3."; sleep 2 ;;
        esac
    done
}

# ========== CORE VM CREATION FUNCTION ==========
create_template() {
    if [[ -z "$IMAGE" ]]; then
        error_exit "--image flag is required"
    fi
    if [[ -z "$VMID" ]]; then
        VMID=$(get_next_vmid)
    fi
    
    validate_vmid "$VMID"
    validate_storage "$STORAGE"
    
    log "🆔 Using VMID: $VMID"
    
    CLEANUP_VMID="$VMID"
    
    if [[ ! -f "$IMAGE" ]] && [[ $DRY_RUN -eq 0 ]]; then
        error_exit "Image file '$IMAGE' not found"
    fi
    log "📁 Using local image: $IMAGE"
    
    VM_NAME="${VM_NAME:-ubuntu-template}"
    CORES="${CORES:-$DEFAULT_CORES}"
    MEMORY="${MEMORY:-$DEFAULT_MEMORY}"
    SOCKETS="${SOCKETS:-$DEFAULT_SOCKETS}"
    
    log "📦 Using Proxmox storage: $STORAGE"
    log "💾 Resizing image to $IMAGE_SIZE..."
    run_or_dry "qemu-img resize '$IMAGE' $IMAGE_SIZE"
    
    log "🛠️ Creating VM $VMID..."
    run_or_dry "qm create $VMID --name '$VM_NAME' --ostype $DEFAULT_OSTYPE --memory $MEMORY --cores $CORES --sockets $SOCKETS --agent 1 --bios $DEFAULT_BIOS --machine $DEFAULT_MACHINE --efidisk0 $STORAGE:0,pre-enrolled-keys=0 --cpu $DEFAULT_CPU --vga $DEFAULT_VGA --serial0 $DEFAULT_SERIAL0 --net0 virtio,bridge=vmbr0"
    
    log "📤 Importing disk..."
    run_or_dry "qm importdisk $VMID '$IMAGE' $STORAGE"
    run_or_dry "qm set $VMID --scsihw virtio-scsi-pci --virtio0 $STORAGE:vm-${VMID}-disk-1,discard=on"
    run_or_dry "qm set $VMID --boot order=$CI_BOOT_ORDER"
    run_or_dry "qm set $VMID --scsi1 ${STORAGE}:cloudinit"
    
    create_vendor_snippet
    
    log "🧩 Adding cloud-init snippet..."
    run_or_dry "qm set $VMID --cicustom vendor=${CI_VENDOR_SNIPPET}"
    
    log "🔐 Applying cloud-init settings..."
    run_or_dry "qm set $VMID --tags '$CI_TAGS'"
    run_or_dry "qm set $VMID --ciuser '$CI_USER'"
    run_or_dry "qm set $VMID --sshkeys '$CI_SSH_KEY_PATH'"
    run_or_dry "qm set $VMID --ipconfig0 ip=dhcp"
    
    if [[ "${PROVISION_VM:-0}" == "1" ]]; then
        log "🖥️ Starting VM (skipping template conversion)..."
        run_or_dry "qm start $VMID"
        log "✅ VM provisioning complete. VMID: $VMID"
    else
        log "📌 Converting VM to template..."
        run_or_dry "qm template $VMID"
        log "✅ Template creation complete. VMID: $VMID"
    fi
    
    CLEANUP_VMID=""
    CACHE_TIMESTAMP=0
}

# ========== HELP FUNCTIONS ==========
show_help() {
    cat <<EOF
Usage: $0 [options]

🎛️  Interactive Mode:
  --kiosk                        Launch interactive kiosk mode

📁 Template Creation:
  --image <file|url>             Path or URL to the image file (required)
  --vmid <id>                    Set VMID (default: auto-generated)
  --name <name>                  Template/VM name (default: ubuntu-template)
  --storage <id>                 Proxmox storage ID (default: local-lvm)
  --cores <num>                  Number of CPU cores (default: 1)
  --memory <MB>                  Memory in MB (default: 2048)

🖥️  VM Provisioning:
  --provision-vm                 Create VM instead of template

🗑️  VM Management:
  --list-vmids                   List all existing VMIDs

⚙️  General Options:
  --dry-run                      Simulate actions without making changes
  --help, -h                     Show this help menu
  --examples                     Show usage examples
EOF
}

show_examples() {
    cat <<EOF

🔧 Proxmox Template Provisioner – Usage Examples:

🎛️  Interactive mode (recommended):
  ./provision.sh --kiosk

📁 Create template from local image:
  ./provision.sh --image /path/to/ubuntu-24.04.iso

🖥️  Create VM (not template) from image:
  ./provision.sh --provision-vm --image ubuntu-24.04.iso --name my-vm

📋 List all VMs and templates:
  ./provision.sh --list-vmids

🔍 Dry run (preview actions):
  ./provision.sh --dry-run --image ubuntu.iso

EOF
}

# ========== MAIN EXECUTION ==========
check_environment

# Argument parsing variables
IMAGE=""
VMID=""
VM_NAME=""
PROVISION_VM=0
LIST_VMIDS=0
CORES=""
MEMORY=""
SOCKETS=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kiosk) KIOSK_MODE=true; shift ;;
        --image) IMAGE="$2"; shift 2 ;;
        --vmid) VMID="$2"; shift 2 ;;
        --name) VM_NAME="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --sockets) SOCKETS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --provision-vm) PROVISION_VM=1; shift ;;
        --list-vmids) LIST_VMIDS=1; shift ;;
        --help|-h) show_help; exit 0 ;;
        --examples) show_examples; exit 0 ;;
        *) echo "❌ Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Handle different execution modes
if [[ "$KIOSK_MODE" == "true" ]]; then
    log "🎛️  Starting kiosk mode"
    kiosk_menu
    exit 0
fi

if [[ $LIST_VMIDS -eq 1 ]]; then
    log "📋 Listing existing VMIDs:"
    if build_vm_info_cache; then
        printf "%-8s %-20s %-12s %-8s %s\n" "VMID" "NAME" "STATUS" "MEMORY" "TYPE"
        printf "%s\n" "$(printf '%*s' 60 '' | tr ' ' '-')"
        
        while IFS= read -r vmid; do
            local name status memory is_template
            name=$(get_vm_info "$vmid" "name")
            status=$(get_vm_info "$vmid" "status")
            memory=$(get_vm_info "$vmid" "memory")
            is_template=$(get_vm_info "$vmid" "is_template")
            
            local type_display="🖥️  VM"
            if [[ "$is_template" == "true" ]]; then
                type_display="📋 Template"
            fi
            
            printf "%-8s %-20s %-12s %-8s %s\n" "$vmid" "$name" "$status" "$memory" "$type_display"
        done < <(get_all_vmids)
    else
        echo "❌ Unable to retrieve VM information"
        exit 1
    fi
    exit 0
fi

# If we get here, either create template/VM or show help
if [[ -n "$IMAGE" ]]; then
    create_template
else
    log "❌ No action specified. Use --help for usage information."
    show_help
    exit 1
fi