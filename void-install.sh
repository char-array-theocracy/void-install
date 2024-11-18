#!/bin/bash

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to handle yes/no prompts with validation
ask_yes_no() {
    local prompt="$1"
    local result_var="$2"
    local answer
    while true; do
        echo -en "${CYAN}$prompt (yes/no): ${NC}"
        read answer
        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                eval $result_var="yes"
                break
                ;;
            [Nn]|[Nn][Oo])
                eval $result_var="no"
                break
                ;;
            *)
                echo -e "${RED}Please answer yes or no.${NC}"
                ;;
        esac
    done
}

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run this script as root.${NC}"
    exit 1
fi

echo -e "${GREEN}Void Linux Automated Installation Script${NC}"

# Display available disks
echo -e "${YELLOW}Available disks:${NC}"
lsblk -d -e 7,11 -o NAME,SIZE,TYPE | grep disk
echo -en "${CYAN}Enter the disk to install Void Linux on (e.g., sda or nvme0n1): ${NC}"
read DISK

# Confirm disk selection
ask_yes_no "You have chosen /dev/$DISK. All data on this disk will be erased. Are you sure?" CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}Installation aborted.${NC}"
    exit 1
fi

# Determine partition prefix
if [[ $DISK =~ [0-9]$ ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="$DISK"
fi

# Partition the disk
echo -e "${GREEN}Partitioning /dev/$DISK...${NC}"
echo -e "g\nn\n\n\n+200M\nt\n1\nn\n\n\n+10G\nt\n2\n20\nn\n\n\n\nw" | fdisk /dev/$DISK
echo -e "${GREEN}Partitioning completed.${NC}"

# Create filesystems
echo -e "${GREEN}Creating filesystems...${NC}"
mkfs.vfat -nBOOT -F32 /dev/${PART_PREFIX}1
mkfs.ext2 -L grub /dev/${PART_PREFIX}2

# Setup LUKS encryption
echo -e "${GREEN}Setting up LUKS encryption...${NC}"
cryptsetup luksFormat --type=luks -s 512 /dev/${PART_PREFIX}3
cryptsetup open /dev/${PART_PREFIX}3 cryptroot

# Create Btrfs filesystem
echo -e "${GREEN}Creating Btrfs filesystem...${NC}"
mkfs.btrfs -L void /dev/mapper/cryptroot

# Mount and create subvolumes
echo -e "${GREEN}Mounting and creating Btrfs subvolumes...${NC}"
BTRFS_OPTS="rw,noatime,compress=zstd,commit=120,lazytime"
mount -o $BTRFS_OPTS /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

# Mount subvolumes
echo -e "${GREEN}Mounting subvolumes...${NC}"
mount -o $BTRFS_OPTS,subvol=@ /dev/mapper/cryptroot /mnt
mkdir /mnt/home && mount -o $BTRFS_OPTS,subvol=@home /dev/mapper/cryptroot /mnt/home
mkdir /mnt/.snapshots && mount -o $BTRFS_OPTS,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots

# Create additional subvolumes
echo -e "${GREEN}Creating additional subvolumes...${NC}"
mkdir -p /mnt/var/cache
btrfs subvolume create /mnt/var/cache/xbps
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/srv
btrfs subvolume create /mnt/var/swap

# Mount EFI and boot partitions
echo -e "${GREEN}Mounting EFI and boot partitions...${NC}"
mkdir /mnt/efi && mount -o rw,noatime /dev/${PART_PREFIX}1 /mnt/efi
mkdir /mnt/boot && mount -o rw,noatime /dev/${PART_PREFIX}2 /mnt/boot

# Set repository and architecture
echo -e "${GREEN}Setting up XBPS repository and architecture...${NC}"
REPO="https://repo-default.voidlinux.org/current"

# Ask user for architecture
echo -e "${YELLOW}Available architectures:${NC}"
echo -e "${CYAN}1) x86_64${NC}"
echo -e "${CYAN}2) x86_64-musl${NC}"

while true; do
    echo -en "${CYAN}Enter the number corresponding to your desired architecture: ${NC}"
    read ARCH_CHOICE
    case $ARCH_CHOICE in
        1)
            ARCH="x86_64"
            break
            ;;
        2)
            ARCH="x86_64-musl"
            REPO="$REPO/musl"
            break
            ;;
        *)
            echo -e "${RED}Invalid choice. Please enter 1 or 2.${NC}"
            ;;
    esac
done

# Copy XBPS keys
echo -e "${GREEN}Copying XBPS keys...${NC}"
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

# Ask for additional packages to install
echo -en "${CYAN}Enter any additional packages to install (space-separated, or leave blank for none): ${NC}"
read ADDITIONAL_PKGS

# Install base system
echo -e "${GREEN}Installing base system...${NC}"
XBPS_ARCH=$ARCH xbps-install -S -R "$REPO" -r /mnt base-system btrfs-progs cryptsetup $ADDITIONAL_PKGS

# Bind mount necessary filesystems
echo -e "${GREEN}Binding mount filesystems...${NC}"
for dir in dev proc sys run; do
    mount --rbind /$dir /mnt/$dir
    mount --make-rslave /mnt/$dir
done

# Copy DNS configuration
echo -e "${GREEN}Copying DNS configuration...${NC}"
cp /etc/resolv.conf /mnt/etc/

# Generate /etc/fstab
echo -e "${GREEN}Generating /etc/fstab...${NC}"
UEFI_UUID=$(blkid -s UUID -o value /dev/${PART_PREFIX}1)
GRUB_UUID=$(blkid -s UUID -o value /dev/${PART_PREFIX}2)
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
cat <<EOF > /mnt/etc/fstab
UUID=$ROOT_UUID / btrfs $BTRFS_OPTS,subvol=@ 0 1
UUID=$UEFI_UUID /efi vfat defaults,noatime 0 2
UUID=$GRUB_UUID /boot ext2 defaults,noatime 0 2
UUID=$ROOT_UUID /home btrfs $BTRFS_OPTS,subvol=@home 0 2
UUID=$ROOT_UUID /.snapshots btrfs $BTRFS_OPTS,subvol=@snapshots 0 2
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF

# Create setup script inside chroot
cat <<'EOT' > /mnt/root/setup.sh
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ask_yes_no() {
    local prompt="$1"
    local result_var="$2"
    local answer
    while true; do
        echo -en "${CYAN}$prompt (yes/no): ${NC}"
        read answer
        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                eval $result_var="yes"
                break
                ;;
            [Nn]|[Nn][Oo])
                eval $result_var="no"
                break
                ;;
            *)
                echo -e "${RED}Please answer yes or no.${NC}"
                ;;
        esac
    done
}

echo -e "${GREEN}Configuring locales...${NC}"
vi /etc/default/libc-locales
vi /etc/locale.conf
xbps-reconfigure -f glibc-locales

echo -e "${GREEN}Setting root password...${NC}"
passwd

echo -en "${CYAN}Enter a username for the new user: ${NC}"
read USERNAME
useradd $USERNAME
echo -e "${GREEN}Setting password for $USERNAME...${NC}"
passwd $USERNAME

echo -en "${CYAN}Enter additional groups for $USERNAME (comma-separated, or leave blank for default groups): ${NC}"
read GROUPS
if [ -z "$GROUPS" ]; then
    usermod -aG wheel,audio,video,input,dialout $USERNAME
else
    usermod -aG wheel,audio,video,input,dialout,$GROUPS $USERNAME
fi

echo -en "${CYAN}Enter the hostname for this system: ${NC}"
read HOSTNAME
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1   localhost" > /etc/hosts
echo "127.0.1.1   $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

echo -en "${CYAN}Enter your timezone (e.g., Europe/Berlin): ${NC}"
read TIMEZONE
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime

echo -e "${GREEN}Configuring dracut...${NC}"
echo 'hostonly=yes' >> /etc/dracut.conf

echo -e "${GREEN}Installing non-free repository...${NC}"
xbps-install -Su void-repo-nonfree

echo -e "${GREEN}Installing GRUB bootloader...${NC}"
xbps-install grub-x86_64-efi
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void Linux"

ask_yes_no 'Do you want to install NetworkManager?' INSTALL_NM

if [ "$INSTALL_NM" == "yes" ]; then
    xbps-install NetworkManager
    ln -s /etc/sv/dbus /var/service/
    ln -s /etc/sv/NetworkManager /var/service/
fi

echo -e "${GREEN}Reconfiguring all packages...${NC}"
xbps-reconfigure -fa

while true; do
    echo -en "${CYAN}Installation complete. Do you want to exit the script and do additional modifications in chroot or reboot now? (exit/reboot): ${NC}"
    read ACTION
    case "$ACTION" in
        [Ee][Xx][Ii][Tt])
            echo -e "${GREEN}You can now make additional modifications. Type \"exit\" when done.${NC}"
            /bin/bash
            break
            ;;
        [Rr][Ee][Bb][Oo][Oo][Tt])
            break
            ;;
        *)
            echo -e "${RED}Please enter \"exit\" or \"reboot\".${NC}"
            ;;
    esac
done
EOT

chmod +x /mnt/root/setup.sh

# Enter chroot environment and run setup script
echo -e "${GREEN}Entering chroot environment...${NC}"
chroot /mnt /root/setup.sh

# Ask to reboot
ask_yes_no "Installation complete. Do you want to reboot now?" REBOOT_CHOICE
if [ "$REBOOT_CHOICE" == "yes" ]; then
    echo -e "${GREEN}Cleaning up and unmounting filesystems...${NC}"
    umount -R /mnt
    cryptsetup close cryptroot
    echo -e "${GREEN}System is rebooting...${NC}"
    reboot
else
    echo -e "${YELLOW}You can now make additional modifications. Remember to unmount /mnt and reboot when you are done.${NC}"
fi
