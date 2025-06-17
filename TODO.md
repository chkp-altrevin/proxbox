## Todo Items

### Cluster Support Extended
- node selection
- list vm/templates
- all vm/template actions referenced
- add widgets in kiosk to support if enabled
---
### Kiosk Current Status
- add Storage Locations
- add Networks
- add Proxmox OS version info:

### Kiosk Widgets
- add to widget window Default Configuration "Modify 6)"
- add Default Configuration side of Current Configuration
---

### Main Menu Adds

- Add Stop and Start VMs
- Add Migrate
- Add Snapshot
- Add "Show Kiosk Use Case Examples" - show_use_cases hi performance vm -> option 2, add your image, configure advanced options "6" customize values,  migrate vm -> config options 

### Main Menu Modifications - Priority
1) 
2)
3)
4) fix exits kiosk after listing vms
5) 
6) add to settings, all vm options with ability to save as a template, we need to suport import which is listed abvoe in Main Menu -Import 
7) 
- Modify 7) to "Show Batch Use Case Examples" - Force Delete Many VMIDS `--delete-vmids 123 124 125 126` or `--delete-vmids 123 --delete-vmids 124`
- Add ?) "Tag Multiple VMs/Templates" - Tag Many VMIDS `--provision-vm --tags 123 124 125 126` or `--delete-vmids 123 --delete-vmids 124`
- Maybe add new function for new flag --vmids (to support multiple) need to establish verifications and stops
---

### Settings Menu

1) add auto-discovery of storage devices and allow user to select
2
3
4
5
6
7
8
9) resets to defaults

### Settings Menu add ons
Add - Modify Defaults, creates a default_env file, to support all defaults. creates like the ranchup provisioning a folder of templates by date/timestamp and template name defined somewhere

Add - Import (.env) based on config file ****
Add - make current settings the default profile - save, name 
qm create <vmid> [options]

Option: ?? for creating vm from image, use a predefined template to speed things up:

1. linux vm template
qm create 133 --name ubuntu-vm --memory 4096 --net0 virtio,bridge=vmbr0 --sockets 1 --cores 2 --ostype l26 --ide2 local:iso/ubuntu-22.04.iso,media=cdrom --scsi0 local-lvm:32,iothread=1

2. windows vm template
qm create 134 --name windows-server-2022 --memory 8192 --net0 model=virtio,bridge=vmbr0 --ostype win10 --scsi0 local-lvm:50,iothread=1 --cdrom local:iso/windows-server.iso --sockets 1 --cores 4 --bios ovmf --machine q35 --boot order=scsi0;cdrom0

3. create custom template
qm create <vmid> --name <vmname> --memory <memory_mb> --net0 <network_config> --ostype win<version> --scsi0 <storage>:<disk_size> --cdrom <iso_storage>:<iso_file> --sockets <sockets> --cores <cores> --bios <bios> --machine <machine_type> --boot <boot_order>

```
Explanation of Parameters:

<vmid>: A unique numerical ID for the VM (e.g., 101).
--name <vmname>: The name of the VM (e.g., "windows-server-2022").
--memory <memory_mb>: RAM in megabytes (e.g., 4096 for 4GB).
--net0 <network_config>: Networking configuration (e.g., model=virtio,bridge=vmbr0).
--ostype win<version>: Operating system type (e.g., win10 for Windows Server 2016 and later, win8 for older versions).
--scsi0 <storage>:<disk_size>: Disk storage and size (e.g., local-lvm:50,iothread=1 for 50GB on local-lvm).
--cdrom <iso_storage>:<iso_file>: ISO image location (e.g., local:iso/windows-server.iso).
--sockets <sockets>: Number of CPU sockets.
--cores <cores>: Number of CPU cores per socket.
--bios <bios>: BIOS type, usually ovmf for UEFI.
--machine <machine_type>: Machine type, usually q35.
--boot <boot_order>: Boot order, usually order=scsi0;cdrom0
```

## References

- cloud-init support
  https://pve.proxmox.com/wiki/Cloud-Init_Support
