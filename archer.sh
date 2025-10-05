#!/bin/bash

# --- Configuration & Setup ---
set -euo pipefail # Exit on error, unset var, or pipe failure

LOG_FILE="/tmp/archer-install.log"
# Clear log file for new session and start logging
> "$LOG_FILE"
exec > >(tee -a "${LOG_FILE}") 2>&1

# --- Functions ---

# Function to display error messages and exit
error_exit() {
    local exit_code=$?
    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!                      INSTALLATION FAILED                   !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "An error occurred (exit code: $exit_code) on line $1."
    echo "Please check the log file for details: ${LOG_FILE}"
    echo "You will be returned to the shell to inspect the system."
    # We don't exit with 1 to allow the user to stay in the shell
    exit 1
}

# Trap interrupts and errors for graceful exit
trap 'error_exit $LINENO' ERR
trap 'echo "Installation cancelled by user."; exit 0' SIGINT

# Ensure dialog is installed
if ! pacman -Q dialog &>/dev/null; then
    echo "Installing 'dialog' package for TUI..."
    pacman -Sy --noconfirm dialog
fi

# --- Main Script ---

# 1. Pre-flight checks and welcome
dialog --backtitle "Archer Setup" --title "Welcome!" \
--msgbox "Welcome to the Archer Installer!\n\nThis script will guide you through a comprehensive installation of Arch Linux.\n\nPlease ensure you have an active internet connection.\n\nAll actions are logged to: $LOG_FILE" 15 70

# Detect boot mode
if [ -d /sys/firmware/efi/efivars ]; then
    BOOT_MODE="UEFI"
else
    BOOT_MODE="BIOS"
fi
dialog --title "System Check" --infobox "Detected Boot Mode: $BOOT_MODE" 4 50; sleep 2

# 2. Gather User Configuration
KEYMAP=$(dialog --stdout --title "System Localization" --inputbox "Enter console keyboard layout:" 8 60 "us")
loadkeys "$KEYMAP"

TIMEZONE=$(dialog --stdout --title "System Localization" --fselect /usr/share/zoneinfo/ 20 80)
[[ -z "$TIMEZONE" ]] && TIMEZONE="Etc/UTC"

HOSTNAME=$(dialog --stdout --title "Network Configuration" --inputbox "Enter hostname:" 8 60 "arch")

# Root Password
while true; do
    ROOT_PASSWORD=$(dialog --stdout --title "User Accounts" --passwordbox "Enter 'root' password:" 8 60)
    [[ -n "$ROOT_PASSWORD" ]] && break
    dialog --msgbox "Password cannot be empty." 6 40
done
while true; do
    ROOT_PASSWORD_VERIFY=$(dialog --stdout --title "User Accounts" --passwordbox "Confirm 'root' password:" 8 60)
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_VERIFY" ]] && break
    dialog --msgbox "Passwords do not match." 6 40
done

# User Account
if dialog --title "User Accounts" --yesno "Create a new user account with sudo privileges?" 7 60; then
    CREATE_USER="yes"
    USERNAME=$(dialog --stdout --title "User Accounts" --inputbox "Enter username:" 8 60 "user")
    while true; do
        USER_PASSWORD=$(dialog --stdout --title "User Accounts" --passwordbox "Enter password for $USERNAME:" 8 60)
        [[ -n "$USER_PASSWORD" ]] && break
        dialog --msgbox "Password cannot be empty." 6 40
    done
    while true; do
        USER_PASSWORD_VERIFY=$(dialog --stdout --title "User Accounts" --passwordbox "Confirm password:" 8 60)
        [[ "$USER_PASSWORD" == "$USER_PASSWORD_VERIFY" ]] && break
        dialog --msgbox "Passwords do not match." 6 40
    done
else
    CREATE_USER="no"
fi

# --- [FIXED] Disk Selection ---
devices_list=()
while read -r line; do
    devices_list+=("$line")
done < <(lsblk -dno NAME,SIZE,MODEL | grep -v "boot\|rom\|loop")

if [ ${#devices_list[@]} -eq 0 ]; then
    dialog --msgbox "No suitable disks found for installation." 6 50
    error_exit
fi

devices_options=()
for i in "${!devices_list[@]}"; do
    # Parse line like "sda 500G Some Model"
    device_name=$(echo "${devices_list[$i]}" | awk '{print $1}')
    device_info=$(echo "${devices_list[$i]}" | awk '{$1=""; print $0}' | sed 's/^ //')
    status="OFF"
    # Set the first item to ON by default
    if [ $i -eq 0 ]; then
        status="ON"
    fi
    devices_options+=("/dev/$device_name" "$device_info" "$status")
done

num_devices=${#devices_list[@]}
DISK=$(dialog --stdout --title "Disk Setup" --radiolist "WARNING: THE SELECTED DISK WILL BE WIPED.\nSelect the target disk for installation:" 20 70 "$num_devices" "${devices_options[@]}")
[[ -z "$DISK" ]] && error_exit "No disk selected."


# Filesystem and Swap
FILESYSTEM=$(dialog --stdout --title "Disk Setup" --radiolist "Choose the root filesystem:" 12 60 2 "ext4" "Standard, reliable filesystem." ON "btrfs" "Modern filesystem with subvolumes." OFF)
if dialog --title "Disk Setup" --yesno "Create a swap partition?" 7 60; then
    CREATE_SWAP="yes"
    SWAP_SIZE=$(dialog --stdout --title "Disk Setup" --inputbox "Enter swap size in GB (e.g., 4):" 8 60 "4")
else
    CREATE_SWAP="no"
fi

# Init System
INIT_SYSTEM=$(dialog --stdout --title "Core System" --radiolist "Choose your init system:" 15 70 3 \
"systemd" "Standard Arch Linux init system." ON \
"openrc" "Dependency-based init system." OFF \
"runit" "Simple and fast init system." OFF)

# Desktop Environment / WM
DE_CHOICE=$(dialog --stdout --title "Graphical Environment" --radiolist "Select a Desktop Environment or Window Manager (or 'none'):" 20 70 7 \
"GNOME" "Modern and user-friendly desktop." OFF \
"Plasma" "Feature-rich and customizable desktop." OFF \
"XFCE" "Lightweight and stable desktop." OFF \
"Cinnamon" "Traditional and intuitive desktop." OFF \
"i3" "Popular tiling window manager." OFF \
"Hyprland" "Modern Wayland tiling compositor." OFF \
"none" "Base system only (no GUI)." ON)

# Graphics Drivers
GPU_VENDOR=$(dialog --stdout --title "Graphics Drivers" --radiolist "Select your graphics card vendor:" 15 70 4 \
"NVIDIA" "For NVIDIA GPUs (proprietary)." OFF \
"AMD" "For AMD GPUs (open-source)." OFF \
"Intel" "For Intel integrated graphics." OFF \
"VMware/VirtualBox" "For virtual machine guest drivers." ON)

# Additional Software
ADDITIONAL_SOFTWARE=$(dialog --stdout --title "Additional Software" \
--checklist "Select applications to install:" 15 70 4 \
"firefox" "Firefox Web Browser" ON \
"chromium" "Chromium Web Browser" OFF \
"libreoffice-fresh" "Office Suite" OFF \
"yay" "An AUR Helper" ON)

# 3. Final Confirmation
SUMMARY="
Installation Target: $DISK
Boot Mode: $BOOT_MODE
Filesystem: $FILESYSTEM
Swap: $CREATE_SWAP ($SWAP_SIZE GB)
Hostname: $HOSTNAME
Init System: $INIT_SYSTEM
Graphics: $GPU_VENDOR
Desktop: $DE_CHOICE

Software:
$(echo "$ADDITIONAL_SOFTWARE" | sed 's/ /\\n- /g' | sed 's/^/- /')

WARNING: ALL DATA ON $DISK WILL BE ERASED.
"
dialog --title "Final Confirmation" --yesno "$SUMMARY" 25 70
[[ $? -ne 0 ]] && error_exit "Installation cancelled by user."

# --- 4. Installation Begins ---
clear
echo "========================================================"
echo "         Starting Arch Linux Installation"
echo " See full log at ${LOG_FILE}"
echo "========================================================"
echo

# Activate debug trace
set -x

# Update system clock
echo "[+] Synchronizing system clock..."
timedatectl set-ntp true

# Optimize mirrors
echo "[+] Optimizing pacman mirrors..."
reflector --country Germany,France,Netherlands --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Partition disk
echo "[+] Partitioning disk: $DISK"
sgdisk -Z "$DISK" # Zap all data
if [ "$BOOT_MODE" == "UEFI" ]; then
    sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
    if [ "$CREATE_SWAP" == "yes" ]; then
        sgdisk -n 2:0:+${SWAP_SIZE}G -t 2:8200 -c 2:"Linux Swap" "$DISK"
        sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux Root" "$DISK"
    else
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux Root" "$DISK"
    fi
else # BIOS
    if [ "$CREATE_SWAP" == "yes" ]; then
        sgdisk -n 1:0:+${SWAP_SIZE}G -t 1:8200 -c 1:"Linux Swap" "$DISK"
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux Root" "$DISK"
        sgdisk -A 2:set:2 "$DISK" # Set bootable flag
    else
        sgdisk -n 1:0:0 -t 1:8300 -c 1:"Linux Root" "$DISK"
        sgdisk -A 1:set:2 "$DISK" # Set bootable flag
    fi
fi
partprobe "$DISK"
sleep 2 # Give kernel time to recognize new partitions

# Format partitions
echo "[+] Formatting partitions"
# Find partition names dynamically
EFI_PART=$(lsblk -no NAME,PARTLABEL "$DISK" | grep "EFI System Partition" | awk '{print "/dev/"$1}')
ROOT_PART=$(lsblk -no NAME,PARTLABEL "$DISK" | grep "Linux Root" | awk '{print "/dev/"$1}')
SWAP_PART=$(lsblk -no NAME,PARTLABEL "$DISK" | grep "Linux Swap" | awk '{print "/dev/"$1}')

if [ "$BOOT_MODE" == "UEFI" ]; then
    mkfs.fat -F32 "$EFI_PART"
fi
if [ "$CREATE_SWAP" == "yes" ]; then
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"
fi
if [ "$FILESYSTEM" == "btrfs" ]; then
    mkfs.btrfs -f -L ArchRoot "$ROOT_PART"
    mount "$ROOT_PART" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    umount /mnt
    mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt
    mkdir -p /mnt/home
    mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt
else # ext4
    mkfs.ext4 -L ArchRoot "$ROOT_PART"
    mount "$ROOT_PART" /mnt
fi

if [ "$BOOT_MODE" == "UEFI" ]; then
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot
fi

# Pacstrap
echo "[+] Installing base system (pacstrap)... This will take a while."
BASE_PACKAGES="base linux linux-firmware base-devel grub efibootmgr vim sudo"
# Add init-specific packages
case "$INIT_SYSTEM" in
    openrc) BASE_PACKAGES+=" openrc-desktop eudev-openrc networkmanager-openrc" ;;
    runit)  BASE_PACKAGES+=" runit elogind-runit networkmanager" ;;
    *)      BASE_PACKAGES+=" networkmanager" ;; # systemd
esac
pacstrap /mnt $BASE_PACKAGES

# Fstab
echo "[+] Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# --- 5. Chroot and System Configuration ---
echo "[+] Configuring the new system"

# Generate chroot script
cat <<CHROOT_SCRIPT > /mnt/chroot_config.sh
#!/bin/bash
set -euxo pipefail

echo "### CHROOT: Starting System Configuration ###"

# Timezone & Clock
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Localization
sed -i '/en_US.UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Network
echo "$HOSTNAME" > /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# Initramfs (mkinitcpio)
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader
if [ "$BOOT_MODE" == "UEFI" ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
    grub-install --target=i386-pc "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Enable services
case "$INIT_SYSTEM" in
    systemd) systemctl enable NetworkManager ;;
    openrc) rc-update add NetworkManager default ;;
    runit) ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/ ;;
esac

# User setup
echo "root:$ROOT_PASSWORD" | chpasswd
if [ "$CREATE_USER" == "yes" ]; then
    useradd -m -G wheel "$USERNAME"
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers
fi

# Graphical environment installation
if [ "$DE_CHOICE" != "none" ]; then
    echo "### CHROOT: Installing Graphical Environment: \$DE_CHOICE ###"
    DE_PACKAGES=""
    pacman -S --noconfirm --needed xorg-server
    case "\$DE_CHOICE" in
        "GNOME") DE_PACKAGES="gnome gdm" ;;
        "Plasma") DE_PACKAGES="plasma-meta sddm" ;;
        "XFCE") DE_PACKAGES="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter" ;;
        "Cinnamon") DE_PACKAGES="cinnamon lightdm lightdm-gtk-greeter" ;;
        "i3") DE_PACKAGES="i3-wm i3status dmenu lightdm lightdm-gtk-greeter" ;;
        "Hyprland") DE_PACKAGES="hyprland kitty waybar sddm" ;;
    esac
    pacman -S --noconfirm --needed \$DE_PACKAGES

    # Enable display manager
    DM_SERVICE=""
    case "\$DE_CHOICE" in
        "GNOME") DM_SERVICE="gdm" ;;
        "Plasma"|"Hyprland") DM_SERVICE="sddm" ;;
        "XFCE"|"Cinnamon"|"i3") DM_SERVICE="lightdm" ;;
    esac
    if [ -n "\$DM_SERVICE" ]; then
        case "$INIT_SYSTEM" in
            systemd) systemctl enable \$DM_SERVICE ;;
            # OpenRC/Runit would need specific service files, simplifying for now
        esac
    fi
fi

# Graphics drivers
echo "### CHROOT: Installing Graphics Drivers for \$GPU_VENDOR ###"
DRIVER_PACKAGES=""
case "\$GPU_VENDOR" in
    "NVIDIA") DRIVER_PACKAGES="nvidia-dkms nvidia-utils" ;;
    "AMD") DRIVER_PACKAGES="mesa xf86-video-amdgpu" ;;
    "Intel") DRIVER_PACKAGES="mesa xf86-video-intel" ;;
    "VMware/VirtualBox") DRIVER_PACKAGES="virtualbox-guest-utils xf86-video-vmware" ;;
esac
pacman -S --noconfirm --needed \$DRIVER_PACKAGES

# Additional software
if [ -n "$ADDITIONAL_SOFTWARE" ]; then
    echo "### CHROOT: Installing Additional Software ###"
    pacman -S --noconfirm --needed $(echo "$ADDITIONAL_SOFTWARE" | sed 's/yay//')
fi

# AUR Helper (yay) - must be run as user
if [[ "$ADDITIONAL_SOFTWARE" == *"yay"* ]] && [ "$CREATE_USER" == "yes" ]; then
    echo "### CHROOT: Installing AUR Helper (yay) for user \$USERNAME ###"
    pacman -S --noconfirm --needed git
    sudo -u $USERNAME bash -c "cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm"
fi

echo "### CHROOT: System Configuration Complete ###"
CHROOT_SCRIPT

# Pass variables to and execute the chroot script
arch-chroot /mnt env \
    TIMEZONE="$TIMEZONE" \
    KEYMAP="$KEYMAP" \
    HOSTNAME="$HOSTNAME" \
    ROOT_PASSWORD="$ROOT_PASSWORD" \
    CREATE_USER="$CREATE_USER" \
    USERNAME="$USERNAME" \
    USER_PASSWORD="$USER_PASSWORD" \
    BOOT_MODE="$BOOT_MODE" \
    DISK="$DISK" \
    INIT_SYSTEM="$INIT_SYSTEM" \
    DE_CHOICE="$DE_CHOICE" \
    GPU_VENDOR="$GPU_VENDOR" \
    ADDITIONAL_SOFTWARE="$ADDITIONAL_SOFTWARE" \
    bash /chroot_config.sh

# Cleanup
rm /mnt/chroot_config.sh

# --- 6. Finalization ---
# Deactivate debug trace
set +x
echo
echo "========================================================"
echo "         Installation Finalizing"
echo "========================================================"

echo "[+] Unmounting filesystems"
umount -R /mnt
swapoff -a

dialog --title "Installation Complete" --msgbox "Congratulations! Arch Linux has been installed successfully.\n\nFull log is available at ${LOG_FILE}\n\nYou can now reboot your system. Remove the installation media." 12 70

