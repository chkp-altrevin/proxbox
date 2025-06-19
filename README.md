# 🏗️ ProxBox

> **Intelligent Proxmox Template & VM Provisioner with Interactive Management**

A powerful, user-friendly automation tool for creating, managing, and deploying Proxmox VE templates and virtual machines. Features both command-line interface and interactive kiosk mode for streamlined operations.

![proxbox-preview](https://github.com/user-attachments/assets/3809940b-f352-4bc4-baa8-fd022924e4c7)

## ✨ Features

- **🎛️ Interactive Kiosk Mode** - User-friendly menu-driven interface
- **📁 Template Creation** - Build reusable templates from ISO/IMG files  
- **🖥️ VM Provisioning** - Deploy VMs directly from images
- **🔄 Smart Cloning** - Full or linked clones with intelligent workflows
- **☁️ Cloud-Init Integration** - Automated guest configuration
- **🔍 Dry Run Mode** - Preview operations before execution
- **📊 Real-time Status** - Live VM/template monitoring
- **⚙️ Configurable Defaults** - Persistent settings management
- **🗑️ Safe Deletion** - Protected VM removal with confirmations

## 🚀 Quick Start
Clone the repo, chmod +x, follow procedures below or use the installer script which will handle these automagically.

### Interactive Mode (Recommended)
```bash
./provision.sh --kiosk
```
**Installer Script**
```bash
curl -fsSL https://raw.githubusercontent.com/chkp-altrevin/proxbox/main/provision.sh -o provision.sh -f && chmod +x provision.sh && ./provision.sh --kiosk
```

### Command Line Examples
```bash
# Create template from Ubuntu ISO
./provision.sh --image https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso

# Provision VM with custom specs
./provision.sh --provision-vm --image ubuntu.iso --memory 4096 --cores 2

# Clone existing template
./provision.sh --clone-vmid 9000

# List all VMs/templates
./provision.sh --list-vmids
```

```bash
# Interactive mode (recommended for exploration)
./provision.sh --kiosk

# Command line examples
./provision.sh --image ubuntu-24.04.iso --name my-template
./provision.sh --provision-vm --image my-image.iso
./provision.sh --clone-vmid 100 --name new-vm
./provision.sh --list-vmids
./provision.sh --dry-run --image test.iso  # Safe testing
```

## 📋 Usage

### 🎛️ Interactive Mode
Launch the intuitive menu interface:
```bash
./provision.sh --kiosk
```

**Menu Options:**
- Create templates from images
- Provision VMs with custom configurations  
- Clone existing VMs/templates
- Manage and delete VMs
- Configure default settings
- View usage examples

### 💻 Command Line Interface

#### Template Creation
```bash
./provision.sh --image <path|url> [options]
```

**Core Options:**
- `--image <file|url>` - Source image (ISO/IMG)
- `--vmid <id>` - Custom VMID (auto-generated if not specified)
- `--name <name>` - Template/VM name
- `--storage <id>` - Proxmox storage pool (default: local-lvm)
- `--memory <MB>` - RAM allocation (default: 2048)
- `--cores <num>` - CPU cores (default: 1)
- `--resize <size>` - Disk size (default: 40G)

**Cloud-Init Options:**
- `--ciuser <username>` - Default user (default: ubuntu)
- `--sshkeys <file>` - SSH public key file
- `--tags <tags>` - Comma-separated tags

#### VM Provisioning
```bash
./provision.sh --provision-vm --image <path|url> [options]
```
Creates and starts a VM instead of a template.

#### VM Management
```bash
# Clone VM/template
./provision.sh --clone-vmid <source_id>

# List all VMs
./provision.sh --list-vmids

# Delete VM
./provision.sh --delete-vmid <id>

# Dry run (preview)
./provision.sh --dry-run --image ubuntu.iso
```

## 🔧 Configuration

### Default Settings
```bash
STORAGE="local-lvm"          # Proxmox storage pool
DEFAULT_MEMORY=2048          # RAM in MB
DEFAULT_CORES=1              # CPU cores
IMAGE_SIZE="40G"             # Default disk size
CI_USER="ubuntu"             # Cloud-init user
```
## Customize using env file
Will override defaults if present and configured.

📋 Usage Instructions:

Copy the template:
```bash
cp .env.example .env
```
Customize settings:
```bash
nano .env

```
```
# Uncomment and modify desired values
```

🚀 Benefits:

- Environment-specific configurations (dev/prod)
- Easy customization without editing the main script
- Version control friendly (add .env to .gitignore)
- Comprehensive options for all use cases
- Clear documentation with examples and alternatives
- Performance tuning options included
- Security settings configurable


### Cloud-Init Integration
- Automatic guest agent installation
- DHCP network configuration
- SSH key injection
- Custom vendor snippets

## 📊 System Requirements

- **Proxmox VE 7.0+**
- **Root access** or sudo privileges
- **Internet connectivity** (for image downloads)
- **Storage space** for images and VMs

### Dependencies
- `qm` (Proxmox VM manager)
- `pvesh` (Proxmox API shell)
- `qemu-img` (Image manipulation)
- `curl` (Image downloads)

## 🛡️ Safety Features

- **VMID validation** - Prevents conflicts
- **Dry run mode** - Preview operations
- **Confirmation prompts** - Prevent accidental deletions
- **Error handling** - Graceful failure recovery
- **Logging** - Full operation audit trail

## 📁 File Structure

```
proxbox/
├── provision.sh           # Main provisioner script
├── README.md              # This file
└── logs/
    └── provision.log      # Operation logs
```

## 🔍 Troubleshooting

### Common Issues

**Permission Denied:**
```bash
chmod +x provision.sh
sudo ./provision.sh --kiosk
```

**VMID Already Exists:**
- Use `--list-vmids` to see existing VMs
- Specify custom VMID with `--vmid <id>`

**Storage Not Found:**
- Verify storage pool: `pvesm status`
- Update default: `./provision.sh --kiosk` → Settings

**Image Download Fails:**
- Check internet connectivity
- Verify URL accessibility
- Use local image file instead

### Debug Mode
Enable detailed logging:
```bash
./provision.sh --dry-run --image test.iso
```

## 🚦 Examples

### Basic Template Creation
```bash
./provision.sh --image ubuntu-24.04.iso \
  --name ubuntu-2404-template \
  --memory 2048 \
  --cores 2
```

### High-Performance VM
```bash
./provision.sh --provision-vm \
  --image debian-12.iso \
  --memory 8192 \
  --cores 4 \
  --storage nvme-pool \
  --name production-vm
```

### Batch Clone Operations
```bash
# Clone template multiple times
for i in {1..5}; do
  ./provision.sh --clone-vmid 9000 --name "web-server-$i"
done
```

## 🤝 Contributing

1. Fork the repository
2. Create feature branch: `git checkout -b feature-name`
3. Commit changes: `git commit -am 'Add feature'`
4. Push branch: `git push origin feature-name`
5. Submit pull request

## 📄 License

MIT License - see LICENSE file for details.

## 🆘 Support

- **Issues:** GitHub Issues tracker
- **Discussions:** GitHub Discussions
- **Documentation:** This README + `--help` flag

---

**Made with ❤️ for the Proxmox community**
