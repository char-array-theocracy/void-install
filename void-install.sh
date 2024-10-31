#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root."
    exit 1
fi

echo "Void Linux Automated Installation Script"

# Display available disks
echo "Available disks:"
lsblk -d -e 7,11 -o NAME,SIZE,TYPE | grep disk
read -p "Enter the disk to install Void Linux on (e.g., sda or nvme0n1): " DISK

# Confirm disk selection
read -p "You have chosen /dev/$DISK. All data on this disk will be erased. Are you sure? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Installation aborted."
    exit 1
fi

# Determine partition prefix
if [[ $DISK =~ [0-9]$ ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="$DISK"
fi

# Partition the disk
echo "Partitioning /dev/$DISK..."
echo -e "g\nn\n\n\n+200M\nt\n1\nn\n\n\n+10G\nt\n2\n20\nn\n\n\n\nw" | fdisk /dev/$DISK
echo "Partitioning completed."

# Create filesystems
echo "Creating filesystems..."
mkfs.vfat -nBOOT -F32 /dev/${PART_PREFIX}1
mkfs.ext2 -L grub /dev/${PART_PREFIX}2

# Setup LUKS encryption
echo "Setting up LUKS encryption..."
cryptsetup luksFormat --type=luks -s 512 /dev/${PART_PREFIX}3
cryptsetup open /dev/${PART_PREFIX}3 cryptroot

# Create Btrfs filesystem
echo "Creating Btrfs filesystem..."
mkfs.btrfs -L void /dev/mapper/cryptroot

# Mount and create subvolumes
echo "Mounting and creating Btrfs subvolumes..."
BTRFS_OPTS="rw,noatime,compress=zstd,commit=120,lazytime"
mount -o $BTRFS_OPTS /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

# Mount subvolumes
echo "Mounting subvolumes..."
mount -o $BTRFS_OPTS,subvol=@ /dev/mapper/cryptroot /mnt
mkdir /mnt/home && mount -o $BTRFS_OPTS,subvol=@home /dev/mapper/cryptroot /mnt/home
mkdir /mnt/.snapshots && mount -o $BTRFS_OPTS,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots

# Create additional subvolumes
echo "Creating additional subvolumes..."
mkdir -p /mnt/var/cache
btrfs subvolume create /mnt/var/cache/xbps
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/srv
btrfs subvolume create /mnt/var/swap

# Mount EFI and boot partitions
echo "Mounting EFI and boot partitions..."
mkdir /mnt/efi && mount -o rw,noatime /dev/${PART_PREFIX}1 /mnt/efi
mkdir /mnt/boot && mount -o rw,noatime /dev/${PART_PREFIX}2 /mnt/boot

# Set repository and architecture
echo "Setting up XBPS repository and architecture..."
REPO="https://repo-default.voidlinux.org/current"

# Ask user for architecture
echo "Available architectures:"
echo "1) x86_64"
echo "2) x86_64-musl"
read -p "Enter the number corresponding to your desired architecture: " ARCH_CHOICE
case $ARCH_CHOICE in
    1)
        ARCH="x86_64"
        ;;
    2)
        ARCH="x86_64-musl"
        REPO="$REPO/musl"
        ;;
    *)
        echo "Invalid choice."
        exit 1
        ;;
esac

# Copy XBPS keys
echo "Copying XBPS keys..."
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

# Ask for additional packages to install
read -p "Enter any additional packages to install (space-separated, or leave blank for none): " ADDITIONAL_PKGS

# Install base system
echo "Installing base system..."
XBPS_ARCH=$ARCH xbps-install -S -R "$REPO" -r /mnt base-system btrfs-progs cryptsetup $ADDITIONAL_PKGS

# Bind mount necessary filesystems
echo "Binding mount filesystems..."
for dir in dev proc sys run; do
    mount --rbind /$dir /mnt/$dir
    mount --make-rslave /mnt/$dir
done

# Copy DNS configuration
echo "Copying DNS configuration..."
cp /etc/resolv.conf /mnt/etc/

# Generate /etc/fstab
echo "Generating /etc/fstab..."
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

# Enter chroot environment
echo "Entering chroot environment..."
cp /proc/mounts /mnt/etc/mtab
BTRFS_OPTS=$BTRFS_OPTS chroot /mnt /bin/bash -c "
# Configure locales
echo 'Configuring locales...'
vi /etc/default/libc-locales
vi /etc/locale.conf
xbps-reconfigure -f glibc-locales

# Set root password
echo 'Setting root password...'
passwd

# Add a new user
read -p 'Enter a username for the new user: ' USERNAME
useradd \$USERNAME
echo 'Setting password for \$USERNAME...'
passwd \$USERNAME

# Add user to groups
read -p 'Enter additional groups for \$USERNAME (comma-separated, or leave blank for default groups): ' GROUPS
if [ -z '\$GROUPS' ]; then
    usermod -aG wheel,audio,video \$USERNAME
else
    usermod -aG wheel,audio,video,\$GROUPS \$USERNAME
fi

# Set timezone
echo 'Available timezones (e.g., Europe/Berlin):'
read -p 'Enter your timezone: ' TIMEZONE
ln -sf /usr/share/zoneinfo/\$TIMEZONE /etc/localtime

# Configure dracut
echo 'Configuring dracut...'
echo 'hostonly=yes' >> /etc/dracut.conf

# Install non-free repository
echo 'Installing non-free repository...'
xbps-install -Su void-repo-nonfree

# Install GRUB
echo 'Installing GRUB bootloader...'
xbps-install grub-x86_64-efi
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=\"Void Linux\"

# Ask to install NetworkManager
read -p 'Do you want to install NetworkManager? (yes/no): ' INSTALL_NM
if [ '\$INSTALL_NM' == 'yes' ]; then
    xbps-install NetworkManager
    ln -s /etc/sv/dbus /var/service/
    ln -s /etc/sv/NetworkManager /var/service/
fi

# Reconfigure all packages
echo 'Reconfiguring all packages...'
xbps-reconfigure -fa

# Ask user to exit or reboot
read -p 'Installation complete. Do you want to exit the script and do additional modifications in chroot or reboot now? (exit/reboot): ' ACTION
if [ '\$ACTION' == 'reboot' ]; then
    exit
else
    echo 'You can now make additional modifications. Type \"exit\" when done.'
    /bin/bash
fi
"

# Ask to reboot
read -p "Installation complete. Do you want to reboot now? (yes/no): " REBOOT_CHOICE
if [ "$REBOOT_CHOICE" == "yes" ]; then
    # Unmount filesystems
    echo "Cleaning up and unmounting filesystems..."
    umount -R /mnt
    echo "System is rebooting..."
    reboot
else
    echo "You can now make additional modifications. Remember to unmount /mnt and reboot when you are done."
fi
