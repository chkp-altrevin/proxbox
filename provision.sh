if [[ "${confirm,,}" == "y" ]]; then
        echo ""
        log "🏗️  Creating template from image..."
        
        # Set variables for create_template function
        IMAGE="$image_input"
        VMID="$vmid_input"
        VM_NAME="$name_input"
        MEMORY="$memory_config"
        CORES="$cores_config"
        STORAGE="$storage_config"
        PROVISION_VM=0
        
        create_template
        echo ""
        echo "✅ Template created successfully!"
        echo "🏗️  Template Details:"
        echo "   VMID: $vmid_input"
        echo "   Name: $name_input"
        echo "   Ready for cloning!"
        kiosk_pause
    fi
}

kiosk_provision_vm() {
    clear_screen
    echo "🖥️  Provision VM from Image"
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
    
    # Get VM name
    echo -n "Enter VM name [ubuntu-vm]: "
    read -r name_input
    name_input=${name_input:-ubuntu-vm}
    
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
    echo "📋 VM Configuration:"
    echo "   Image: $(basename "$image_input")"
    echo "   VMID: $vmid_input"
    echo "   Name: $name_input"
    echo "   Storage: $storage_config"
    echo "   Memory: ${memory_config}MB"
    echo "   Cores: $cores_config"
    echo ""
    echo -n "Create and start VM? [Y/n]: "
    
    local confirm
    read -r confirm
    confirm=${confirm:-y}
    
    if [[ "${confirm,,}" == "y" ]]; then
        echo ""
        log "🖥️  Creating VM from image..."
        
        # Set variables for create_template function
        IMAGE="$image_input"
        VMID="$vmid_input"
        VM_NAME="$name_input"
        MEMORY="$memory_config"
        CORES="$cores_config"
        STORAGE="$storage_config"
        PROVISION_VM=1
        
        create_template
        echo ""
        echo "✅ VM created and started successfully!"
        echo "🌐 VM Details:"
        echo "   VMID: $vmid_input"
        echo "   Name: $name_input"
        echo "   Status: Starting..."
        echo ""
        echo "💡 Access via Proxmox console or wait for network configuration"
        kiosk_pause
    fi
}

kiosk_clone_vm() {
    clear_screen
    echo "🔄 Clone Existing VM/Template"
    echo ""
    
    local source_vmid
    source_vmid=$(paginated_vm_list "clone")
    
    if [[ -z "$source_vmid" ]]; then
        return
    fi
    
    # Validate source VMID
    if ! build_vm_info_cache || [[ -z "$(get_vm_info "$source_vmid" "name")" ]]; then
        echo "❌ VMID $source_vmid not found"
        kiosk_pause
        return
    fi
    
    # Show source VM/template details
    echo ""
    echo "📊 Source Details:"
    local vm_name memory is_template
    vm_name=$(get_vm_info "$source_vmid" "name")
    memory=$(get_vm_info "$source_vmid" "memory")
    is_template=$(get_vm_info "$source_vmid" "is_template")
    
    # Get additional details from config
    local vm_cores="Unknown"
    if [[ $DRY_RUN -eq 0 ]] && command -v qm >/dev/null 2>&1; then
        vm_cores=$(qm config "$source_vmid" 2>/dev/null | grep "^cores:" | cut -d' ' -f2 || echo "Unknown")
    fi
    
    echo "   VMID: $source_vmid"
    echo "   Name: $vm_name"
    echo "   Type: $([ "$is_template" == "true" ] && echo "📋 Template" || echo "🖥️  VM")"
    echo "   Memory: ${memory}MB"
    echo "   Cores: $vm_cores"
    
    # Get new VMID
    local suggested_vmid
    suggested_vmid=$(get_next_vmid)
    echo ""
    echo -n "Enter new VMID [$suggested_vmid]: "
    read -r new_vmid
    new_vmid=${new_vmid:-$suggested_vmid}
    
    # Validate new VMID
    validate_vmid "$new_vmid"
    
    # Get name
    echo -n "Enter name for cloned VM [cloned-vm-$new_vmid]: "
    read -r clone_name
    clone_name=${clone_name:-cloned-vm-$new_vmid}
    
    # Clone type with smart recommendations
    echo ""
    echo "Clone options:"
    if [[ "$is_template" == "true" ]]; then
        echo "  1) Full clone (independent copy - ⭐ recommended for templates)"
        echo "  2) Linked clone (dependent on original - not recommended for templates)"
    else
        echo "  1) Full clone (independent copy)"
        echo "  2) Linked clone (dependent on original - faster but requires source)"
    fi
    echo -n "Select clone type [1]: "
    read -r clone_type
    clone_type=${clone_type:-1}
    
    local full_flag=""
    local clone_description=""
    if [[ "$clone_type" == "1" ]]; then
        full_flag="--full"
        clone_description="Full clone (independent)"
    else
        clone_description="Linked clone (dependent)"
    fi
    
    echo ""
    echo "📋 Clone Configuration:"
    echo "   Source VMID: $source_vmid ($([ "$is_template" == "true" ] && echo "📋 Template" || echo "🖥️  VM"))"
    echo "   New VMID: $new_vmid"
    echo "   Name: $clone_name"
    echo "   Type: $clone_description"
    echo ""
    echo -n "Proceed with cloning? [Y/n]: "
    
    local confirm
    read -r confirm
    confirm=${confirm:-y}
    
    if [[ "${confirm,,}" == "y" ]]; then
        echo ""
        log "🔄 Cloning VMID $source_vmid to $new_vmid..."
        
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[DRY-RUN] qm clone $source_vmid $new_vmid --name $clone_name $full_flag"
        else
            # Set cleanup VMID in case of failure
            CLEANUP_VMID="$new_vmid"
            
            # Perform the clone
            if qm clone "$source_vmid" "$new_vmid" --name "$clone_name" $full_flag; then
                echo "✅ Clone operation completed successfully!"
                
                # Clear cleanup VMID on success
                CLEANUP_VMID=""
                
                # Only ask to start if it's not a template
                if [[ "$is_template" != "true" ]]; then
                    echo ""
                    echo -n "Start the cloned VM now? [y/N]: "
                    read -r start_confirm
                    if [[ "${start_confirm,,}" == "y" ]]; then
                        if qm start "$new_vmid"; then
                            echo "✅ VM started successfully!"
                            echo "🌐 VM Details:"
                            echo "   VMID: $new_vmid"
                            echo "   Name: $clone_name"
                            echo "   Status: Starting..."
                        else
                            echo "⚠️  Clone successful but failed to start VM"
                        fi
                    else
                        echo "✅ VM cloned successfully (not started)"
                    fi
                else
                    echo "📋 Template cloned to VM successfully!"
                    echo "   New VM VMID: $new_vmid"
                    echo ""
                    echo -n "Start the new VM now? [y/N]: "
                    read -r start_confirm
                    if [[ "${start_confirm,,}" == "y" ]]; then
                        if qm start "$new_vmid"; then
                            echo "✅ VM started successfully!"
                        else
                            echo "⚠️  Failed to start VM"
                        fi
                    fi
                fi
            else
                echo "❌ Clone operation failed"
                CLEANUP_VMID=""  # Don't cleanup on qm clone failure
            fi
        fi
        
        # Invalidate cache
        CACHE_TIMESTAMP=0
        kiosk_pause
    fi
}

kiosk_list_vms() {
    paginated_vm_list "list"
    # Always pause and return to menu regardless of paginated_vm_list return code
    kiosk_pause
}

kiosk_delete_vm() {
    local delete_vmid
    delete_vmid=$(paginated_vm_list "delete")
    
    if [[ -z "$delete_vmid" ]]; then
        return
    fi
    
    # Validate VMID exists
    if ! build_vm_info_cache || [[ -z "$(get_vm_info "$delete_vmid" "name")" ]]; then
        echo "❌ VMID $delete_vmid not found"
        kiosk_pause
        return
    fi
    
    # Show VM details
    echo ""
    echo "📊 VM/Template Details:"
    local vm_name memory status is_template
    vm_name=$(get_vm_info "$delete_vmid" "name")
    memory=$(get_vm_info "$delete_vmid" "memory")
    status=$(get_vm_info "$delete_vmid" "status")
    is_template=$(get_vm_info "$delete_vmid" "is_template")
    
    # Get additional details from config
    local vm_cores="Unknown"
    if [[ $DRY_RUN -eq 0 ]] && command -v qm >/dev/null 2>&1; then
        vm_cores=$(qm config "$delete_vmid" 2>/dev/null | grep "^cores:" | cut -d' ' -f2 || echo "Unknown")
    fi
    
    echo "   VMID: $delete_vmid"
    echo "   Name: $vm_name"
    echo "   Type: $([ "$is_template" == "true" ] && echo "📋 Template" || echo "🖥️  VM")"
    echo "   Memory: ${memory}MB"
    echo "   Cores: $vm_cores"
    echo "   Status: $status"
    
    echo ""
    echo "⚠️  WARNING: This will permanently delete VMID $delete_vmid!"
    if [[ "$is_template" == "true" ]]; then
        echo "🔥 You are about to delete a TEMPLATE - this may affect cloned VMs!"
    fi
    echo ""
    echo -n "Type 'DELETE' to confirm (case sensitive): "
    local confirm
    read -r confirm
    
    if [[ "$confirm" == "DELETE" ]]; then
        echo ""
        log "🗑️  Deleting VMID $delete_vmid..."
        
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[DRY-RUN] qm stop $delete_vmid"
            echo "[DRY-RUN] qm destroy $delete_vmid --purge"
        else
            # Stop VM if running
            if [[ "$status" == "running" ]]; then
                echo "🛑 Stopping VM/Template..."
                if qm stop "$delete_vmid"; then
                    echo "✅ VM/Template stopped"
                    sleep 2
                else
                    echo "⚠️  Failed to stop VM/Template, attempting forced deletion..."
                fi
            fi
            
            # Delete VM/Template
            if qm destroy "$delete_vmid" --purge; then
                echo "✅ VMID $delete_vmid deleted successfully!"
                if [[ "$is_template" == "true" ]]; then
                    echo "📋 Template has been removed from the system"
                else
                    echo "🖥️  VM has been removed from the system"
                fi
                
                # Invalidate cache
                CACHE_TIMESTAMP=0
            else
                echo "❌ Failed to delete VMID $delete_vmid"
            fi
        fi
        kiosk_pause
    else
        echo "❌ Deletion cancelled (confirmation text must be exactly 'DELETE')"
        sleep 2
    fi
}

kiosk_settings() {
    while true; do
        clear_screen
        echo "⚙️  Settings Configuration"
        echo ""
        echo "Current Settings:"
        echo "  1) Storage: $STORAGE"
        echo "  2) Default Memory: ${MEMORY:-$DEFAULT_MEMORY}MB"
        echo "  3) Default Cores: ${CORES:-$DEFAULT_CORES}"
        echo "  4) Default Image Size: $IMAGE_SIZE"
        echo "  5) CI User: $CI_USER"
        echo "  6) SSH Key Path: $CI_SSH_KEY_PATH"
        echo "  7) Default Tags: $CI_TAGS"
        echo "  8) Dry Run Mode: $([ $DRY_RUN -eq 1 ] && echo "Enabled" || echo "Disabled")"
        echo ""
        echo "  9) Reset to defaults"
        echo "  0) Back to main menu"
        echo ""
        echo -n "Enter setting to change [0-9]: "
        
        local choice
        read -r choice
        
        case "$choice" in
            1)
                echo ""
                echo -n "Enter storage name [$STORAGE]: "
                local new_storage
                read -r new_storage
                if [[ -n "$new_storage" ]]; then
                    # Validate storage if not in dry run
                    if [[ $DRY_RUN -eq 0 ]]; then
                        if validate_storage "$new_storage" 2>/dev/null; then
                            STORAGE="$new_storage"
                            echo "✅ Storage updated to: $STORAGE"
                        else
                            echo "❌ Storage '$new_storage' not found or not available"
                        fi
                    else
                        STORAGE="$new_storage"
                        echo "✅ Storage updated to: $STORAGE (not validated in dry-run mode)"
                    fi
                    sleep 2
                fi
                ;;
            2)
                echo ""
                echo -n "Enter default memory in MB [${MEMORY:-$DEFAULT_MEMORY}]: "
                local new_memory
                read -r new_memory
                if [[ -n "$new_memory" ]]; then
                    if validate_memory "$new_memory" 2>/dev/null; then
                        MEMORY="$new_memory"
                        echo "✅ Memory updated to: ${MEMORY}MB"
                    else
                        echo "❌ Invalid memory value: $new_memory"
                    fi
                    sleep 2
                fi
                ;;
            3)
                echo ""
                echo -n "Enter default cores [${CORES:-$DEFAULT_CORES}]: "
                local new_cores
                read -r new_cores
                if [[ -n "$new_cores" ]]; then
                    if validate_cores "$new_cores" 2>/dev/null; then
                        CORES="$new_cores"
                        echo "✅ Cores updated to: $CORES"
                    else
                        echo "❌ Invalid cores value: $new_cores"
                    fi
                    sleep 2
                fi
                ;;
            4)
                echo ""
                echo -n "Enter default image size [$IMAGE_SIZE]: "
                local new_size
                read -r new_size
                if [[ -n "$new_size" ]]; then
                    if [[ "$new_size" =~ ^[0-9]+[KMGT]?$ ]]; then
                        IMAGE_SIZE="$new_size"
                        echo "✅ Image size updated to: $IMAGE_SIZE"
                    else
                        echo "❌ Invalid size format (use format like 40G, 500M, etc.)"
                    fi
                    sleep 2
                fi
                ;;
            5)
                echo ""
                echo -n "Enter CI user [$CI_USER]: "
                local new_user
                read -r new_user
                if [[ -n "$new_user" ]] && [[ "$new_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                    CI_USER="$new_user"
                    echo "✅ CI user updated to: $CI_USER"
                elif [[ -n "$new_user" ]]; then
                    echo "❌ Invalid username format"
                fi
                sleep 2
                ;;
            6)
                echo ""
                echo -n "Enter SSH key path [$CI_SSH_KEY_PATH]: "
                local new_keypath
                read -r new_keypath
                if [[ -n "$new_keypath" ]]; then
                    if [[ -f "$new_keypath" ]] || [[ $DRY_RUN -eq 1 ]]; then
                        CI_SSH_KEY_PATH="$new_keypath"
                        echo "✅ SSH key path updated to: $CI_SSH_KEY_PATH"
                    else
                        echo "❌ SSH key file not found: $new_keypath"
                    fi
                    sleep 2
                fi
                ;;
            7)
                echo ""
                echo -n "Enter tags (comma-separated) [$CI_TAGS]: "
                local new_tags
                read -r new_tags
                if [[ -n "$new_tags" ]]; then
                    CI_TAGS="$new_tags"
                    echo "✅ Tags updated to: $CI_TAGS"
                    sleep 2
                fi
                ;;
            8)
                if [[ $DRY_RUN -eq 1 ]]; then
                    DRY_RUN=0
                    echo "✅ Dry run mode disabled"
                else
                    DRY_RUN=1
                    echo "✅ Dry run mode enabled"
                fi
                sleep 2
                ;;
            9)
                STORAGE="local-lvm"
                MEMORY=""
                CORES=""
                IMAGE_SIZE="40G"
                CI_USER="ubuntu"
                CI_SSH_KEY_PATH="/root/.ssh/authorized_keys"
                CI_TAGS="ubuntu-template,24.04,cloudinit"
                DRY_RUN=0
                echo "✅ Settings reset to defaults"
                sleep 2
                ;;
            0)
                return
                ;;
            *)
                echo "❌ Invalid choice"
                sleep 2
                ;;
        esac
    done
}

# ========== CORE VM CREATION FUNCTION ==========
create_template() {
    # Validate inputs with proper error handling
    if [[ -z "$IMAGE" ]]; then
        error_exit "--image flag is required"
    fi
    if [[ -z "$VMID" ]]; then
        VMID=$(get_next_vmid)
    fi
    
    # Validate all inputs
    validate_vmid "$VMID"
    validate_memory "${MEMORY:-$DEFAULT_MEMORY}"
    validate_cores "${CORES:-$DEFAULT_CORES}"
    validate_storage "$STORAGE"
    
    log "🆔 Using VMID: $VMID"
    
    # Set cleanup VMID for error recovery
    CLEANUP_VMID="$VMID"
    
    # Download image if URL
    if [[ "$IMAGE" == http* ]]; then
        download_image "$IMAGE"
    else
        # Validate local file
        if [[ ! -f "$IMAGE" ]] && [[ $DRY_RUN -eq 0 ]]; then
            error_exit "Image file '$IMAGE' not found"
        fi
        log "📁 Using local image: $IMAGE"
    fi
    
    # Set defaults
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
    
    # Create vendor snippet
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
    
    # Clear cleanup VMID on success
    CLEANUP_VMID=""
    
    # Invalidate cache
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
  --resize <size>                Resize disk image (default: 40G)
  --cores <num>                  Number of CPU cores (default: 1)
  --memory <MB>                  Memory in MB (default: 2048)
  --sockets <num>                Number of CPU sockets (default: 1)
  --ostype <type>                Guest OS type (default: l26)
  --bios <type>                  BIOS type (default: ovmf)
  --machine <type>               Machine type (default: q35)
  --cpu <type>                   CPU type (default: host)
  --tags <tags>                  Tags for the template
  --ciuser <username>            Cloud-init user (default: ubuntu)
  --sshkeys <file>               SSH key path (default: /root/.ssh/authorized_keys)

🖥️  VM Provisioning:
  --provision-vm                 Create VM instead of template
  --clone-vmid <id>              Clone an existing VMID
  --replica <number>             Create additional clones (default: 0)

🗑️  VM Management:
  --delete-vmid <id>             Delete a VM by VMID
  --purge                        Force delete with purge
  --list-vmids                   List all existing VMIDs

⚙️  General Options:
  --dry-run                      Simulate actions without making changes
  --help, -h                     Show this help menu
  --examples                     Show usage examples

🔧 Environment:
  Create a .env file in the same directory to set default values:
    STORAGE=my-storage
    DEFAULT_MEMORY=4096
    DEFAULT_CORES=2
    CI_USER=myuser
EOF
}

show_examples() {
    cat <<EOF

🔧 Proxmox Template Provisioner – Usage Examples:

🎛️  Interactive mode (recommended):
  ./provision.sh --kiosk

📁 Create template from Ubuntu ISO:
  ./provision.sh --image https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso

🖥️  Create VM (not template) from image:
  ./provision.sh --provision-vm --image ubuntu-24.04.iso --name my-vm

🔄 Clone existing template:
  ./provision.sh --clone-vmid 9000 --name cloned-vm

📋 List all VMs and templates:
  ./provision.sh --list-vmids

🗑️  Delete a VM:
  ./provision.sh --delete-vmid 101 --purge

⚙️  Custom configuration:
  ./provision.sh --image ubuntu.iso --vmid 200 --memory 4096 --cores 2 --storage local

🔍 Dry run (preview actions):
  ./provision.sh --dry-run --image ubuntu.iso

🏗️  Environment configuration (.env file):
  STORAGE=my-nvme-storage
  DEFAULT_MEMORY=4096
  DEFAULT_CORES=2
  CI_USER=myuser
  CI_SSH_KEY_PATH=/root/.ssh/my_key
  CI_TAGS=my-template,ubuntu,cloud-init

EOF
}

# ========== MAIN EXECUTION ==========

# Initialize environment
check_environment
load_configuration

# Argument parsing variables
IMAGE=""
VMID=""
VM_NAME=""
DELETE_VMID=""
PROVISION_VM=0
CLONE_VMID=""
LIST_VMIDS=0
CORES=""
MEMORY=""
SOCKETS=""
REPLICA=0
PURGE_DELETE=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kiosk) KIOSK_MODE=true; shift ;;
        --image) IMAGE="$2"; shift 2 ;;
        --vmid) VMID="$2"; shift 2 ;;
        --name) VM_NAME="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --resize) IMAGE_SIZE="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --sockets) SOCKETS="$2"; shift 2 ;;
        --ostype) DEFAULT_OSTYPE="$2"; shift 2 ;;
        --bios) DEFAULT_BIOS="$2"; shift 2 ;;
        --machine) DEFAULT_MACHINE="$2"; shift 2 ;;
        --cpu) DEFAULT_CPU="$2"; shift 2 ;;
        --tags) CI_TAGS="$2"; shift 2 ;;
        --ciuser) CI_USER="$2"; shift 2 ;;
        --sshkeys) CI_SSH_KEY_PATH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --delete-vmid) DELETE_VMID="$2"; shift 2 ;;
        --purge) PURGE_DELETE=1; shift ;;
        --provision-vm) PROVISION_VM=1; shift ;;
        --clone-vmid) CLONE_VMID="$2"; shift 2 ;;
        --replica) REPLICA="$2"; shift 2 ;;
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

if [[ -n "$DELETE_VMID" ]]; then
    validate_vmid "$DELETE_VMID"
    
    log "⚠️  Deleting VMID: $DELETE_VMID"
    
    if [[ $DRY_RUN -eq 0 ]]; then
        if ! qm status "$DELETE_VMID" >/dev/null 2>&1; then
            error_exit "VMID $DELETE_VMID not found"
        fi
    fi
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] qm stop $DELETE_VMID"
        echo "[DRY-RUN] qm destroy $DELETE_VMID $([ $PURGE_DELETE -eq 1 ] && echo "--purge")"
    else
        # Stop VM if running
        local vm_status
        vm_status=$(qm status "$DELETE_VMID" 2>/dev/null | awk '{print $2}' || echo "stopped")
        if [[ "$vm_status" == "running" ]]; then
            log "🛑 Stopping VM..."
            qm stop "$DELETE_VMID" || log "⚠️  Failed to stop VM gracefully"
        fi
        
        # Delete VM
        local destroy_args=("$DELETE_VMID")
        if [[ $PURGE_DELETE -eq 1 ]]; then
            destroy_args+=("--purge")
        fi
        
        if qm destroy "${destroy_args[@]}"; then
            log "✅ VMID $DELETE_VMID deleted successfully"
        else
            error_exit "Failed to delete VMID $DELETE_VMID"
        fi
    fi
    exit 0
fi

if [[ -n "$CLONE_VMID" ]]; then
    validate_vmid "$CLONE_VMID"
    
    # Validate source exists
    if [[ $DRY_RUN -eq 0 ]]; then
        if ! qm status "$CLONE_VMID" >/dev/null 2>&1; then
            error_exit "Source VMID $CLONE_VMID not found"
        fi
    fi
    
    # Get new VMID
    local new_vmid="${VMID:-$(get_next_vmid)}"
    validate_vmid "$new_vmid"
    
    # Set name
    local clone_name="${VM_NAME:-cloned-vm-$new_vmid}"
    
    log "🔄 Cloning VMID $CLONE_VMID to $new_vmid..."
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] qm clone $CLONE_VMID $new_vmid --name $clone_name --full"
    else
        CLEANUP_VMID="$new_vmid"
        
        if qm clone "$CLONE_VMID" "$new_vmid" --name "$clone_name" --full; then
            log "✅ Clone operation completed successfully!"
            CLEANUP_VMID=""  # Clear on success
            
            # Handle replicas
            for (( i=1; i<=REPLICA; i++ )); do
                local replica_vmid
                replica_vmid=$(get_next_vmid)
                validate_vmid "$replica_vmid"
                
                log "🔄 Creating replica $i/$REPLICA (VMID: $replica_vmid)..."
                if qm clone "$CLONE_VMID" "$replica_vmid" --name "${clone_name}-replica-$i" --full; then
                    log "✅ Replica $i created successfully"
                else
                    log "❌ Failed to create replica $i"
                fi
            done
        else
            error_exit "Clone operation failed"
        fi
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
fi#!/usr/bin/env bash
set -euo pipefail

# ========== GLOBAL VARIABLES ==========
declare -g LOG_FILE="/var/log/provision.log"
declare -g SCRIPT_PID="$"
declare -g CLEANUP_VMID=""
declare -a TEMP_FILES=()

# Configuration defaults
declare -g TEMPLATE_DEFAULT_VMID=9800
declare -g STORAGE="local-lvm"
declare -g CI_USER="ubuntu"
declare -g CI_SSH_KEY_PATH="/root/.ssh/authorized_keys"
declare -g CI_VENDOR_SNIPPET="local:snippets/vendor.yaml"
declare -g CI_TAGS="ubuntu-template,24.04,cloudinit"
declare -g CI_BOOT_ORDER="virtio0"
declare -g IMAGE_SIZE="40G"
declare -g DEFAULT_CORES=1
declare -g DEFAULT_MEMORY=2048
declare -g DEFAULT_SOCKETS=1
declare -g DEFAULT_OSTYPE="l26"
declare -g DEFAULT_BIOS="ovmf"
declare -g DEFAULT_MACHINE="q35"
declare -g DEFAULT_CPU="host"
declare -g DEFAULT_VGA="serial0"
declare -g DEFAULT_SERIAL0="socket"
declare -g KIOSK_MODE=false
declare -g DRY_RUN=0

# VM info cache
declare -A VM_INFO_CACHE
declare -g CACHE_TIMESTAMP=0
declare -g CACHE_TTL=30  # 30 seconds

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
    read -r confirm
    confirm=${confirm:-y}