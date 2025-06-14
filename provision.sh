#!/usr/bin/env bash
set -euo pipefail
# Load environment configuration

if [[ -f ".env" ]]; then
    source .env
    log "📄 Loaded configuration from .env"
fi

# ========== CONFIGURATION ==========
LOG_FILE="/var/log/provision.log"
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

# ========== LOGGING ==========
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
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
    echo ""
    
    # Show recent VMs/Templates
    echo "📋 Recent VMs/Templates:"
    if command -v qm &>/dev/null; then
        qm list | tail -5 | awk 'NR==1 || $1 ~ /^[0-9]+$/ {printf "   %s\n", $0}'
    else
        echo "   ⚠️  Proxmox tools not available"
    fi
    echo ""
}

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
    
    # Show available images in Proxmox
    echo "📁 Available Images in Proxmox:"
    local image_list=()
    local image_display=()
    
    # Check common Proxmox ISO storage locations
    local iso_paths=(
        "/var/lib/vz/template/iso"
        "/var/lib/vz/template/cache" 
        "/mnt/pve/*/template/iso"
        "/mnt/pve/*/template/cache"
    )
    
    local count=1
    for iso_path in "${iso_paths[@]}"; do
        if [[ -d "$iso_path" ]] 2>/dev/null; then
            while IFS= read -r -d '' file; do
                if [[ -f "$file" && "$file" =~ \.(iso|img|qcow2)$ ]]; then
                    local filename=$(basename "$file")
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
    if command -v pvesm &>/dev/null; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^(.*):(.*)$ ]]; then
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
    
    if [[ ${#image_list[@]} -gt 0 ]]; then
        for display_item in "${image_display[@]}"; do
            echo "   $display_item"
        done
        echo ""
        echo "   0) Enter custom path or URL"
        echo ""
        echo -n "Select an image [0-$((count-1))] or press Enter for custom: "
        
        local image_choice
        read -r image_choice
        
        local image_input=""
        if [[ -n "$image_choice" && "$image_choice" =~ ^[0-9]+$ && "$image_choice" -gt 0 && "$image_choice" -lt "$count" ]]; then
            # User selected a numbered option
            image_input="${image_list[$((image_choice-1))]}"
            echo "✅ Selected: $(basename "$image_input")"
        elif [[ "$image_choice" == "0" || -z "$image_choice" ]]; then
            # User wants to enter custom path
            echo ""
            echo -n "Enter custom image path or URL: "
            read -r image_input
        else
            echo "❌ Invalid selection"
            kiosk_pause
            return
        fi
    else
        echo "   ⚠️  No images found in default locations"
        echo "   Common locations checked:"
        for iso_path in "${iso_paths[@]}"; do
            echo "     - $iso_path"
        done
        echo ""
        echo -n "Enter image path or URL: "
        read -r image_input
    fi
    
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
        memory_config="${new_memory:-$memory_config}"
        
        echo -n "CPU Cores [$cores_config]: "
        read -r new_cores
        cores_config="${new_cores:-$cores_config}"
        
        echo -n "Storage [$storage_config]: "
        read -r new_storage
        storage_config="${new_storage:-$storage_config}"
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
    
    # Show available images in Proxmox
    echo "📁 Available Images in Proxmox:"
    local image_list=()
    local image_display=()
    
    # Check common Proxmox ISO storage locations
    local iso_paths=(
        "/var/lib/vz/template/iso"
        "/var/lib/vz/template/cache" 
        "/mnt/pve/*/template/iso"
        "/mnt/pve/*/template/cache"
    )
    
    local count=1
    for iso_path in "${iso_paths[@]}"; do
        if [[ -d "$iso_path" ]] 2>/dev/null; then
            while IFS= read -r -d '' file; do
                if [[ -f "$file" && "$file" =~ \.(iso|img|qcow2)$ ]]; then
                    local filename=$(basename "$file")
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
    if command -v pvesm &>/dev/null; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^(.*):(.*)$ ]]; then
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
    
    if [[ ${#image_list[@]} -gt 0 ]]; then
        for display_item in "${image_display[@]}"; do
            echo "   $display_item"
        done
        echo ""
        echo "   0) Enter custom path or URL"
        echo ""
        echo -n "Select an image [0-$((count-1))] or press Enter for custom: "
        
        local image_choice
        read -r image_choice
        
        local image_input=""
        if [[ -n "$image_choice" && "$image_choice" =~ ^[0-9]+$ && "$image_choice" -gt 0 && "$image_choice" -lt "$count" ]]; then
            # User selected a numbered option
            image_input="${image_list[$((image_choice-1))]}"
            echo "✅ Selected: $(basename "$image_input")"
        elif [[ "$image_choice" == "0" || -z "$image_choice" ]]; then
            # User wants to enter custom path
            echo ""
            echo -n "Enter custom image path or URL: "
            read -r image_input
        else
            echo "❌ Invalid selection"
            kiosk_pause
            return
        fi
    else
        echo "   ⚠️  No images found in default locations"
        echo "   Common locations checked:"
        for iso_path in "${iso_paths[@]}"; do
            echo "     - $iso_path"
        done
        echo ""
        echo -n "Enter image path or URL: "
        read -r image_input
    fi
    
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
        memory_config="${new_memory:-$memory_config}"
        
        echo -n "CPU Cores [$cores_config]: "
        read -r new_cores
        cores_config="${new_cores:-$cores_config}"
        
        echo -n "Storage [$storage_config]: "
        read -r new_storage
        storage_config="${new_storage:-$storage_config}"
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
    
    # Show available VMs
    echo "📋 Available VMs/Templates:"
    qm list | awk 'NR==1 || $1 ~ /^[0-9]+$/' | head -10
    echo ""
    
    echo -n "Enter source VMID to clone: "
    read -r source_vmid
    if [[ -z "$source_vmid" ]] || ! [[ "$source_vmid" =~ ^[0-9]+$ ]]; then
        echo "❌ Invalid VMID"
        kiosk_pause
        return
    fi
    
    # Check if source VMID exists
    if ! qm status "$source_vmid" &>/dev/null; then
        echo "❌ VMID $source_vmid not found"
        kiosk_pause
        return
    fi
    
    # Get new VMID
    local suggested_vmid
    suggested_vmid=$(get_next_vmid)
    echo -n "Enter new VMID [$suggested_vmid]: "
    read -r new_vmid
    new_vmid=${new_vmid:-$suggested_vmid}
    
    # Get name
    echo -n "Enter name for cloned VM [cloned-vm-$new_vmid]: "
    read -r clone_name
    clone_name=${clone_name:-cloned-vm-$new_vmid}
    
    # Clone type
    echo ""
    echo "Clone options:"
    echo "  1) Full clone (independent copy)"
    echo "  2) Linked clone (dependent on original)"
    echo -n "Select clone type [1]: "
    read -r clone_type
    clone_type=${clone_type:-1}
    
    local full_flag=""
    if [[ "$clone_type" == "1" ]]; then
        full_flag="--full"
    fi
    
    echo ""
    echo "📋 Clone Configuration:"
    echo "   Source VMID: $source_vmid"
    echo "   New VMID: $new_vmid"
    echo "   Name: $clone_name"
    echo "   Type: $([ "$clone_type" == "1" ] && echo "Full clone" || echo "Linked clone")"
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
            qm clone "$source_vmid" "$new_vmid" --name "$clone_name" $full_flag
            echo ""
            echo -n "Start the cloned VM now? [y/N]: "
            read -r start_confirm
            if [[ "${start_confirm,,}" == "y" ]]; then
                qm start "$new_vmid"
                echo "✅ VM cloned and started successfully!"
            else
                echo "✅ VM cloned successfully (not started)!"
            fi
        fi
        kiosk_pause
    fi
}

kiosk_list_vms() {
    clear_screen
    echo "📋 All VMs and Templates"
    echo ""
    
    if command -v qm &>/dev/null; then
        qm list | awk 'NR==1 || $1 ~ /^[0-9]+$/'
        echo ""
        echo "Legend: STATUS - running/stopped, TYPE - vm/template"
    else
        echo "❌ Proxmox tools not available"
    fi
    
    kiosk_pause
}

kiosk_delete_vm() {
    clear_screen
    echo "🗑️  Delete VM/Template"
    echo ""
    
    # Show available VMs
    echo "📋 Available VMs/Templates:"
    qm list | awk 'NR==1 || $1 ~ /^[0-9]+$/' | head -10
    echo ""
    
    echo -n "Enter VMID to delete: "
    read -r delete_vmid
    if [[ -z "$delete_vmid" ]] || ! [[ "$delete_vmid" =~ ^[0-9]+$ ]]; then
        echo "❌ Invalid VMID"
        kiosk_pause
        return
    fi
    
    # Check if VMID exists
    if ! qm status "$delete_vmid" &>/dev/null; then
        echo "❌ VMID $delete_vmid not found"
        kiosk_pause
        return
    fi
    
    # Show VM details
    echo ""
    echo "📊 VM Details:"
    qm config "$delete_vmid" | head -5
    echo ""
    
    echo "⚠️  WARNING: This will permanently delete VMID $delete_vmid!"
    echo -n "Type 'DELETE' to confirm: "
    read -r confirm
    
    if [[ "$confirm" == "DELETE" ]]; then
        echo ""
        log "🗑️  Deleting VMID $delete_vmid..."
        
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[DRY-RUN] qm stop $delete_vmid"
            echo "[DRY-RUN] qm destroy $delete_vmid --purge"
        else
            # Stop VM if running
            if qm status "$delete_vmid" | grep -q "running"; then
                echo "🛑 Stopping VM..."
                qm stop "$delete_vmid" || true
                sleep 2
            fi
            
            # Delete VM
            qm destroy "$delete_vmid" --purge
            echo "✅ VMID $delete_vmid deleted successfully!"
        fi
        kiosk_pause
    else
        echo "❌ Deletion cancelled"
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
                    STORAGE="$new_storage"
                    echo "✅ Storage updated to: $STORAGE"
                    sleep 2
                fi
                ;;
            2)
                echo ""
                echo -n "Enter default memory in MB [${MEMORY:-$DEFAULT_MEMORY}]: "
                local new_memory
                read -r new_memory
                if [[ -n "$new_memory" ]] && [[ "$new_memory" =~ ^[0-9]+$ ]]; then
                    MEMORY="$new_memory"
                    echo "✅ Memory updated to: ${MEMORY}MB"
                    sleep 2
                fi
                ;;
            3)
                echo ""
                echo -n "Enter default cores [${CORES:-$DEFAULT_CORES}]: "
                local new_cores
                read -r new_cores
                if [[ -n "$new_cores" ]] && [[ "$new_cores" =~ ^[0-9]+$ ]]; then
                    CORES="$new_cores"
                    echo "✅ Cores updated to: $CORES"
                    sleep 2
                fi
                ;;
            4)
                echo ""
                echo -n "Enter default image size [$IMAGE_SIZE]: "
                local new_size
                read -r new_size
                if [[ -n "$new_size" ]]; then
                    IMAGE_SIZE="$new_size"
                    echo "✅ Image size updated to: $IMAGE_SIZE"
                    sleep 2
                fi
                ;;
            5)
                echo ""
                echo -n "Enter CI user [$CI_USER]: "
                local new_user
                read -r new_user
                if [[ -n "$new_user" ]]; then
                    CI_USER="$new_user"
                    echo "✅ CI user updated to: $CI_USER"
                    sleep 2
                fi
                ;;
            6)
                echo ""
                echo -n "Enter SSH key path [$CI_SSH_KEY_PATH]: "
                local new_keypath
                read -r new_keypath
                if [[ -n "$new_keypath" ]]; then
                    CI_SSH_KEY_PATH="$new_keypath"
                    echo "✅ SSH key path updated to: $CI_SSH_KEY_PATH"
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

kiosk_pause() {
    echo ""
    echo -n "Press Enter to continue..."
    read -r
}

# ========== HELP MENUS ==========
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

EOF
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
    if command -v pvesh &>/dev/null; then
        pvesh get /cluster/nextid 2>/dev/null || echo "100"
    else
        echo "100"
    fi
}

validate_vmid() {
    local vmid="$1"
    if ! [[ "$vmid" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid VMID: $vmid (must be numeric)"
    fi
    
    if qm status "$vmid" &>/dev/null; then
        error_exit "VMID $vmid already exists"
    fi
}

download_image() {
    local url="$1"
    local filename
    filename=$(basename "$url")
    
    log "📥 Downloading image from URL: $url"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] curl -fSL '$url' -o '$filename'"
        IMAGE="$filename"
    else
        if curl -fSL "$url" -o "$filename"; then
            IMAGE="$filename"
            log "✅ Download completed: $filename"
        else
            error_exit "Failed to download image from $url"
        fi
    fi
}

create_vendor_snippet() {
    local snippet_path="/var/lib/vz/snippets/vendor.yaml"
    
    if [[ ! -f "$snippet_path" ]] && [[ $DRY_RUN -eq 0 ]]; then
        log "🧩 Creating cloud-init vendor snippet..."
        mkdir -p "$(dirname "$snippet_path")"
        cat > "$snippet_path" <<EOF
#cloud-config
runcmd:
  - apt update
  - apt install -y qemu-guest-agent
  - systemctl start qemu-guest-agent
  - systemctl enable qemu-guest-agent
EOF
        log "✅ Vendor snippet created at $snippet_path"
    fi
}

create_template() {
    # Validate inputs
    [[ -z "$IMAGE" ]] && error_exit "--image flag is required"
    [[ -z "$VMID" ]] && VMID=$(get_next_vmid)
    
    log "🆔 Using VMID: $VMID"
    
    # Download image if URL
    if [[ "$IMAGE" == http* ]]; then
        download_image "$IMAGE"
    else
        if [[ ! -f "$IMAGE" ]] && [[ $DRY_RUN -eq 0 ]]; then
            error_exit "Image file '$IMAGE' not found"
        fi
        log "📁 Using local image: $IMAGE"
    fi
    
    # Validate VMID
    if [[ $DRY_RUN -eq 0 ]]; then
        validate_vmid "$VMID"
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
    
    if [[ "$PROVISION_VM" == "1" ]]; then
        log "🖥️ Starting VM (skipping template conversion)..."
        run_or_dry "qm start $VMID"
        log "✅ VM provisioning complete. VMID: $VMID"
    else
        log "📌 Converting VM to template..."
        run_or_dry "qm template $VMID"
        log "✅ Template creation complete. VMID: $VMID"
    fi
}

# ========== ARGUMENT PARSING ==========
IMAGE=""
VMID=""
VM_NAME=""
DRY_RUN=0
DELETE_VMID=""
PROVISION_VM=0
CLONE_VMID=""
LIST_VMIDS=0
CORES=""
MEMORY=""
SOCKETS=""
REPLICA=0

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
        --tags) CI_TAGS="$2"; shift 2 ;;
        --ciuser) CI_USER="$2"; shift 2 ;;
        --sshkeys) CI_SSH_KEY_PATH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --delete-vmid) DELETE_VMID="$2"; shift 2 ;;
        --provision-vm) PROVISION_VM=1; shift ;;
        --clone-vmid) CLONE_VMID="$2"; shift 2 ;;
        --replica) REPLICA="$2"; shift 2 ;;
        --list-vmids) LIST_VMIDS=1; shift ;;
        --help|-h) show_help; exit 0 ;;
        --examples) show_examples; exit 0 ;;
        *) echo "❌ Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# ========== MAIN EXECUTION ==========

# Handle kiosk mode
if [[ "$KIOSK_MODE" == "true" ]]; then
    kiosk_menu
    exit 0
fi

# Handle list VMIDs
if [[ $LIST_VMIDS -eq 1 ]]; then
    log "📋 Listing existing VMIDs:"
    qm list | awk 'NR==1 || $1 ~ /^[0-9]+$/' | tee -a "$LOG_FILE"
    exit 0
fi

# Handle delete VMID
if [[ -n "$DELETE_VMID" ]]; then
    log "⚠️  Deleting VMID: $DELETE_VMID"
    if qm status "$DELETE_VMID" &>/dev/null; then
        qm stop "$DELETE_VMID" || true
        qm destroy "$DELETE_VMID" --purge
        log "✅ VMID $DELETE_VMID deleted."
    else
        log "❌ VMID $DELETE_VMID not found."
    fi
    exit 0
