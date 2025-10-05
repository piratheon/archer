#!/bin/bash

# █████╗  ██████╗ ██████╗ ██╗  ██╗███████╗██████╗
# ██╔══██╗██╔═══██╗██╔══██╗██║  ██║██╔════╝██╔══██╗
# ███████║██║   ██║██████╔╝███████║█████╗  ██████╔╝
# ██╔══██║██║   ██║██╔══██╗██╔══██║██╔══╝  ██╔══██╗
# ██║  ██║╚██████╔╝██║  ██║██║  ██║███████╗██║  ██║
# ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝
#
# A comprehensive TUI-based installer for Arch Linux.

# --- Configuration & Setup ---
set -eo pipefail
LOG_FILE="/tmp/archer-install.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

# --- Global Variables ---
CONFIG_VARS=(
    BOOT_MODE DISK ENCRYPTION_PASSWORD FILESYSTEM CREATE_SWAP SWAP_SIZE
    HOSTNAME TIMEZONE ROOT_PASSWORD CREATE_USER USERNAME USER_PASSWORD USER_SHELL
    KERNEL GPU_VENDOR DE_CHOICE BOOTLOADER_CHOICE ENABLE_FIREWALL
    ENABLE_BLUETOOTH DOTFILES_URL ADDITIONAL_SOFTWARE
)

# --- Functions ---

error_exit() {
    dialog --backtitle "Archer Installer" --title "Error" --msgbox "An error occurred. Please check the log file for details:\n\n$LOG_FILE" 8 70
    clear
    exit 1
}

trap 'error_exit' ERR
trap 'dialog --yesno "Are you sure you want to cancel the installation?" 7 60 && exit 1' SIGINT

pre_flight_checks() {
    if ! pacman -Q dialog &>/dev/null; then
        pacman -Sy --noconfirm dialog
    fi
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root."
    fi
    if ! ping -c 1 archlinux.org &>/dev/null; then
        error_exit "No internet connection detected. Please connect to the internet first."
    fi
    if [ -d /sys/firmware/efi/efivars ]; then
        BOOT_MODE="UEFI"
    else
        BOOT_MODE="BIOS"
    fi
}

show_welcome() {
    dialog --backtitle "Archer Installer" --title "Welcome!" \
    --msgbox "Welcome to the Archer Installer!\n\nThis script will guide you through a comprehensive installation of Arch Linux.\n\nDetected Boot Mode: $BOOT_MODE\n\nPress Enter to begin configuration." 12 70
}

# --- Configuration Gathering Functions ---

get_disk_selection() {
    mapfile -t devices < <(lsblk -dno NAME,SIZE,MODEL | grep -v "boot\|rom\|loop" | awk '{print "/dev/"$1, $2" ("$3" "$4" "$5")"}')
    DISK=$(dialog --stdout --title "Disk Setup" --radiolist "WARNING: THE SELECTED DISK WILL BE WIPED.\nSelect the target disk:" 20 70 "${#devices[@]}" "${devices[@]}")
    [[ -z "$DISK" ]] && error_exit "No disk selected."
}

get_encryption() {
    if dialog --title "Disk Setup" --yesno "Do you want to encrypt the root partition?" 7 60; then
        ENCRYPT_DISK="yes"
        while true; do
            ENCRYPTION_PASSWORD=$(dialog --stdout --title "Disk Encryption" --passwordbox "Enter LUKS encryption password:" 8 60)
            [[ -n "$ENCRYPTION_PASSWORD" ]] && break
            dialog --msgbox "Password cannot be empty." 6 40
        done
        while true; do
            local pass_verify=$(dialog --stdout --title "Disk Encryption" --passwordbox "Confirm password:" 8 60)
            [[ "$ENCRYPTION_PASSWORD" == "$pass_verify" ]] && break
            dialog --msgbox "Passwords do not match." 6 40
        done
    else
        ENCRYPT_DISK="no"
    fi
}

get_filesystem_and_swap() {
    FILESYSTEM=$(dialog --stdout --title "Disk Setup" --radiolist "Choose the root filesystem:" 12 60 2 "ext4" "Standard, reliable filesystem." ON "btrfs" "Modern filesystem with subvolumes." OFF)
    if dialog --title "Disk Setup" --yesno "Create a swap partition?" 7 60; then
        CREATE_SWAP="yes"
        SWAP_SIZE=$(dialog --stdout --title "Disk Setup" --inputbox "Enter swap size in GB (e.g., 4):" 8 60 "4")
    else
        CREATE_SWAP="no"
    fi
}

get_locale_and_network() {
    HOSTNAME=$(dialog --stdout --title "Localization & Network" --inputbox "Enter hostname:" 8 60 "archer")
    # Timezone selection
    local regions=("Africa" "America" "Antarctica" "Asia" "Atlantic" "Australia" "Europe" "Pacific")
    local region=$(dialog --stdout --title "Timezone" --menu "Select your region:" 15 60 ${#regions[@]} "${regions[@]}" 1)
    mapfile -t cities < <(find /usr/share/zoneinfo/${region} -type f -printf "%P\n")
    local city=$(dialog --stdout --title "Timezone" --menu "Select your city:" 20 70 ${#cities[@]} "${cities[@]}")
    TIMEZONE="${region}/${city}"
}

get_user_accounts() {
    while true; do
        ROOT_PASSWORD=$(dialog --stdout --title "User Accounts" --passwordbox "Enter 'root' password:" 8 60)
        [[ -n "$ROOT_PASSWORD" ]] && break
    done
    if dialog --title "User Accounts" --yesno "Create a new user account with sudo privileges?" 7 60; then
        CREATE_USER="yes"
        USERNAME=$(dialog --stdout --title "User Accounts" --inputbox "Enter username:" 8 60 "user")
        while true; do
            USER_PASSWORD=$(dialog --stdout --title "User Accounts" --passwordbox "Enter password for $USERNAME:" 8 60)
            [[ -n "$USER_PASSWORD" ]] && break
        done
        USER_SHELL=$(dialog --stdout --title "User Accounts" --radiolist "Select default shell for $USERNAME:" 12 60 3 "bash" "The GNU Bourne-Again SHell" ON "zsh" "Z SHell" OFF "fish" "Friendly Interactive SHell" OFF)
    else
        CREATE_USER="no"
    fi
}

get_system_components() {
    KERNEL=$(dialog --stdout --title "Core System" --radiolist "Choose your kernel:" 15 70 3 \
    "linux" "The latest stable kernel." ON \
    "linux-lts" "Long-Term Support kernel." OFF \
    "linux-zen" "Performance-tuned kernel." OFF)

    if [ "$BOOT_MODE" == "UEFI" ]; then
        BOOTLOADER_CHOICE=$(dialog --stdout --title "Core System" --radiolist "Choose your bootloader:" 12 70 2 \
        "grub" "Versatile and widely-used." ON \
        "systemd-boot" "Simple, for UEFI only." OFF)
    else
        BOOTLOADER_CHOICE="grub" # GRUB is the only option for BIOS
    fi
}

get_graphics_and_desktop() {
    DE_CHOICE=$(dialog --stdout --title "Graphical Environment" --radiolist "Select a Desktop, WM, or Server profile:" 20 70 8 \
    "GNOME" "Modern and user-friendly desktop." OFF \
    "Plasma" "Feature-rich and customizable." OFF \
    "XFCE" "Lightweight and stable desktop." OFF \
    "Cinnamon" "Traditional and intuitive." OFF \
    "i3" "Popular tiling window manager." OFF \
    "Hyprland" "Modern Wayland tiling compositor." OFF \
    "Server" "Minimal system with SSH." OFF \
    "none" "Base system only (no GUI)." ON)

    if [ "$DE_CHOICE" != "none" ] && [ "$DE_CHOICE" != "Server" ]; then
        GPU_VENDOR=$(dialog --stdout --title "Graphics Drivers" --radiolist "Select graphics card vendor:" 15 70 4 \
        "NVIDIA" "For NVIDIA GPUs (proprietary)." OFF \
        "AMD" "For AMD GPUs (open-source)." OFF \
        "Intel" "For Intel integrated graphics." OFF \
        "VMware/VirtualBox" "For virtual machine guests." ON)
    fi
}

get_extra_software() {
    ENABLE_FIREWALL=$(dialog --stdout --title "Security & Services" --radiolist "Enable UFW Firewall?" 10 60 2 "yes" "" ON "no" "" OFF)
    ENABLE_BLUETOOTH=$(dialog --stdout --title "Security & Services" --radiolist "Install Bluetooth support?" 10 60 2 "yes" "" OFF "no" "" ON)

    if [ "$CREATE_USER" == "yes" ]; then
        DOTFILES_URL=$(dialog --stdout --title "Personalization" --inputbox "Enter Git URL to clone dotfiles (optional):" 8 70)
    fi

    ADDITIONAL_SOFTWARE=$(dialog --stdout --title "Additional Software" \
    --checklist "Select applications to install:" 15 70 4 \
    "firefox" "Firefox Web Browser" ON \
    "chromium" "Chromium Web Browser" OFF \
    "libreoffice-fresh" "Office Suite" OFF \
    "yay" "An AUR Helper" ON)
}

confirm_settings() {
    local summary="
    --- Disk & System ---
    Installation Target: $DISK ($BOOT_MODE)
    Filesystem: $FILESYSTEM
    Encrypted: $ENCRYPT_DISK
    Swap: $CREATE_SWAP ($SWAP_SIZE GB)
    Kernel: $KERNEL
    Bootloader: $BOOTLOADER_CHOICE

    --- Localization & Network ---
    Hostname: $HOSTNAME
    Timezone: $TIMEZONE

    --- User Accounts ---
    Create User: $CREATE_USER ($USERNAME, shell: $USER_SHELL)

    --- Graphics & Software ---
    Desktop/WM: $DE_CHOICE
    Graphics: $GPU_VENDOR
    Firewall: $ENABLE_FIREWALL
    Bluetooth: $ENABLE_BLUETOOTH
    "
    dialog --title "Final Confirmation" --yesno "$summary\n\nWARNING: ALL DATA ON $DISK WILL BE ERASED.\nDo you want to start the installation?" 25 70
}

# --- Installation Step Functions ---

run_installation() {
    clear
    echo "Starting installation... This will take some time. See $LOG_FILE for details."

    # --- Optimize mirrors ---
    echo "Optimizing pacman mirrors..."
    iso_countries=$(curl -s "https://archlinux.org/mirrorlist/?ip_version=4" | grep -oP 'value="\K[^"]+' | head -n 20)
    selected_countries=$(dialog --stdout --title "Mirror Optimization" --checklist "Select countries for fastest mirrors:" 20 70 20 $(for c in $iso_countries; do echo "$c" "" OFF; done))
    reflector --country "$(echo $selected_countries | sed 's/ /_2C/g')" --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

    # --- Disk Preparation ---
    echo "Partitioning disk: $DISK"
    sgdisk -Z "$DISK" # Zap all data
    # Partitioning logic... (UEFI vs BIOS)
    if [ "$BOOT_MODE" == "UEFI" ]; then
        sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK"
        if [ "$CREATE_SWAP" == "yes" ]; then
            sgdisk -n 2:0:+${SWAP_SIZE}G -t 2:8200 -c 2:"swap" "$DISK"
            sgdisk -n 3:0:0 -t 3:8300 -c 3:"root" "$DISK"
        else
            sgdisk -n 2:0:0 -t 2:8300 -c 2:"root" "$DISK"
        fi
    else # BIOS
        sgdisk -n 1:0:+2M -t 1:ef02 -c 1:"BIOS_boot" "$DISK"
        if [ "$CREATE_SWAP" == "yes" ]; then
            sgdisk -n 2:0:+${SWAP_SIZE}G -t 2:8200 -c 2:"swap" "$DISK"
            sgdisk -n 3:0:0 -t 3:8300 -c 3:"root" "$DISK"
        else
            sgdisk -n 2:0:0 -t 2:8300 -c 2:"root" "$DISK"
        fi
    fi
    partprobe "$DISK"
    sleep 2

    # --- Filesystem and Encryption Setup ---
    local root_part=$(lsblk -no NAME,PARTLABEL | grep "root" | awk '{print "/dev/"$1}')
    local efi_part=$(lsblk -no NAME,PARTLABEL | grep "EFI" | awk '{print "/dev/"$1}')
    local swap_part=$(lsblk -no NAME,PARTLABEL | grep "swap" | awk '{print "/dev/"$1}')
    local root_device=$root_part

    if [ "$ENCRYPT_DISK" == "yes" ]; then
        echo "Encrypting root partition..."
        echo -n "$ENCRYPTION_PASSWORD" | cryptsetup luksFormat --type luks2 --verbose "$root_part" -
        echo -n "$ENCRYPTION_PASSWORD" | cryptsetup open "$root_part" cryptlvm -
        root_device="/dev/mapper/cryptlvm"
        pvcreate $root_device
        vgcreate vg0 $root_device
        lvcreate -l 100%FREE vg0 -n root
        root_device="/dev/vg0/root"
    fi

    echo "Formatting partitions..."
    if [ "$CREATE_SWAP" == "yes" ]; then
        mkswap "$swap_part"
        swapon "$swap_part"
    fi
    if [ "$BOOT_MODE" == "UEFI" ]; then
        mkfs.fat -F32 "$efi_part"
    fi

    if [ "$FILESYSTEM" == "btrfs" ]; then
        mkfs.btrfs -f -L ArchRoot "$root_device"
        mount "$root_device" /mnt
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home
        btrfs subvolume create /mnt/@log
        btrfs subvolume create /mnt/@pkg
        umount /mnt
        mount -o noatime,compress=zstd,subvol=@ "$root_device" /mnt
        mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg}
        mount -o noatime,compress=zstd,subvol=@home "$root_device" /mnt/home
        mount -o noatime,compress=zstd,subvol=@log "$root_device" /mnt/var/log
        mount -o noatime,compress=zstd,subvol=@pkg "$root_device" /mnt/var/cache/pacman/pkg
    else # ext4
        mkfs.ext4 -L ArchRoot "$root_device"
        mount "$root_device" /mnt
    fi

    if [ "$BOOT_MODE" == "UEFI" ]; then
        mkdir -p /mnt/boot
        mount "$efi_part" /mnt/boot
    fi

    # --- Pacstrap ---
    echo "Installing base system (pacstrap)..."
    local base_pkgs="base $KERNEL linux-firmware base-devel grub efibootmgr vim sudo"
    base_pkgs+=" networkmanager"
    pacstrap /mnt $base_pkgs

    # --- Fstab ---
    echo "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab

    # --- Chroot Configuration ---
    echo "Configuring the new system via chroot..."
    # Passwords to files to avoid exposure in process list
    echo -n "$ROOT_PASSWORD" > /mnt/root_pass
    if [ "$CREATE_USER" == "yes" ]; then
        echo -n "$USER_PASSWORD" > /mnt/user_pass
    fi

    # Export variables for chroot script
    for var in "${CONFIG_VARS[@]}"; do
        export "$var"
    done
    
    # Copy chroot script and execute
    cp chroot_config.sh /mnt/chroot_config.sh
    arch-chroot /mnt bash /chroot_config.sh

    # --- Cleanup ---
    echo "Cleaning up..."
    rm /mnt/root_pass /mnt/user_pass /mnt/chroot_config.sh
    umount -R /mnt
    swapoff -a
    if [ "$ENCRYPT_DISK" == "yes" ]; then
        cryptsetup close cryptlvm
    fi
    
    dialog --title "Installation Complete" --msgbox "Congratulations! Arch Linux has been installed successfully.\n\nYou can now reboot your system. Remove the installation media." 10 60
    clear
}

# --- Main Logic ---

main() {
    pre_flight_checks
    show_welcome
    
    while true; do
        get_disk_selection
        get_encryption
        get_filesystem_and_swap
        get_locale_and_network
        get_user_accounts
        get_system_components
        get_graphics_and_desktop
        get_extra_software
        
        if confirm_settings; then
            break
        fi
    done
    
    # Create the chroot script dynamically
    cat <<'CHROOT_SCRIPT_EOF' > chroot_config.sh
#!/bin/bash
set -eo pipefail

# --- Environment Setup (variables are passed by arch-chroot) ---

# --- System Configuration ---
echo "Configuring system locale and time..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i '/en_US.UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "Configuring network..."
echo "$HOSTNAME" > /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF
systemctl enable NetworkManager

echo "Configuring users and passwords..."
cat /root_pass | chpasswd
if [ "$CREATE_USER" == "yes" ]; then
    useradd -m -G wheel -s "/usr/bin/$USER_SHELL" "$USERNAME"
    cat /user_pass | chpasswd
    sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers
fi

echo "Installing microcode..."
CPU_VENDOR=$(grep -m 1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
if [ "$CPU_VENDOR" == "GenuineIntel" ]; then
    pacman -S --noconfirm intel-ucode
elif [ "$CPU_VENDOR" == "AuthenticAMD" ]; then
    pacman -S --noconfirm amd-ucode
fi

# --- Initramfs & Bootloader ---
echo "Configuring initramfs..."
HOOKS_LINE="HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block"
if [ "$ENCRYPT_DISK" == "yes" ]; then
    HOOKS_LINE+=" encrypt lvm2"
fi
if [ "$FILESYSTEM" == "btrfs" ]; then
    HOOKS_LINE+=" filesystems"
else
    HOOKS_LINE+=" filesystems fsck"
fi
HOOKS_LINE+=")"
sed -i "s/^HOOKS=.*/$HOOKS_LINE/" /etc/mkinitcpio.conf
mkinitcpio -P

echo "Installing and configuring bootloader..."
if [ "$BOOTLOADER_CHOICE" == "systemd-boot" ]; then
    bootctl --path=/boot install
    local root_uuid=$(blkid -s UUID -o value $(findmnt -n -o SOURCE /))
    cat <<EOF > /boot/loader/loader.conf
default  arch.conf
timeout  3
console-mode max
editor   no
EOF
    cat <<EOF > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-$KERNEL
initrd  /intel-ucode.img # or amd-ucode.img
initrd  /initramfs-$KERNEL.img
options root=UUID=$root_uuid rw
EOF
else # GRUB
    if [ "$ENCRYPT_DISK" == "yes" ]; then
        local luks_uuid=$(blkid -s UUID -o value $(lsblk -no pkname $(findmnt -n -o SOURCE /) | xargs -I{} /dev/{}))
        sed -i "s/GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$luks_uuid:cryptlvm root=\/dev\/vg0\/root\"/" /etc/default/grub
    fi
    if [ "$BOOT_MODE" == "UEFI" ]; then
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    else
        grub-install --target=i386-pc $DISK
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# --- Additional Software ---
echo "Installing graphical environment..."
if [ "$DE_CHOICE" != "none" ] && [ "$DE_CHOICE" != "Server" ]; then
    local de_pkgs="xorg-server pipewire pipewire-pulse pipewire-jack wireplumber"
    if [ "$ENABLE_BLUETOOTH" == "yes" ]; then
        de_pkgs+=" bluez bluez-utils"
        systemctl enable bluetooth
    fi
    case "$DE_CHOICE" in
        "GNOME") de_pkgs+=" gnome gdm" ;;
        "Plasma") de_pkgs+=" plasma-meta sddm" ;;
        "XFCE") de_pkgs+=" xfce4 xfce4-goodies lightdm lightdm-gtk-greeter" ;;
        "Cinnamon") de_pkgs+=" cinnamon lightdm lightdm-gtk-greeter" ;;
        "i3") de_pkgs+=" i3-wm i3status dmenu lightdm lightdm-gtk-greeter terminator" ;;
        "Hyprland") de_pkgs+=" hyprland kitty waybar sddm" ;;
    esac
    pacman -S --noconfirm $de_pkgs

    local dm_service=""
    case "$DE_CHOICE" in
        "GNOME") dm_service="gdm" ;;
        "Plasma"|"Hyprland") dm_service="sddm" ;;
        "XFCE"|"Cinnamon"|"i3") dm_service="lightdm" ;;
    esac
    [ -n "$dm_service" ] && systemctl enable "$dm_service"
fi

if [ "$DE_CHOICE" == "Server" ]; then
    systemctl enable sshd
fi

echo "Installing graphics drivers..."
if [ -n "$GPU_VENDOR" ]; then
    local driver_pkgs=""
    case "$GPU_VENDOR" in
        "NVIDIA") driver_pkgs="nvidia-dkms nvidia-utils" ;;
        "AMD") driver_pkgs="mesa xf86-video-amdgpu" ;;
        "Intel") driver_pkgs="mesa xf86-video-intel" ;;
        "VMware/VirtualBox") driver_pkgs="virtualbox-guest-utils xf86-video-vmware" ;;
    esac
    pacman -S --noconfirm $driver_pkgs
fi

if [ "$ENABLE_FIREWALL" == "yes" ]; then
    pacman -S --noconfirm ufw
    systemctl enable ufw
    ufw enable
fi

if [ -n "$ADDITIONAL_SOFTWARE" ]; then
    pacman -S --noconfirm $(echo "$ADDITIONAL_SOFTWARE" | sed 's/yay//')
fi

if [[ "$ADDITIONAL_SOFTWARE" == *"yay"* ]] && [ "$CREATE_USER" == "yes" ]; then
    pacman -S --noconfirm git
    sudo -u $USERNAME bash -c "cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm"
fi

if [ -n "$DOTFILES_URL" ] && [ "$CREATE_USER" == "yes" ]; then
    sudo -u $USERNAME bash -c "cd /home/$USERNAME && git clone $DOTFILES_URL dotfiles"
fi

echo "Chroot configuration complete."
CHROOT_SCRIPT_EOF

    run_installation
}

# --- Execute Script ---
main
