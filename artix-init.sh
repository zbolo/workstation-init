#!/bin/bash

# Load vars.
. "$(pwd)/.env"
[ -z "$LUKS_PASSWORD" ] && echo "No LUKS password specified." && exit
[ -z "$USER_NAME" ] && echo "No username specified." && exit
[ -z "$ROOT_PASSWD" ] && echo "No root password specified." && exit
[ -z "$USER_PASSWD" ] && echo "No user password specified." && exit
[ -z "$HOSTNAME" ] && echo "No hostname specified." && exit

# Some vars.
target_disk=/dev/nvme0n1
lv_name=gringott

# Reset/init.
pacman -Sy --noconfirm parted
swapoff /dev/$lv_name/swap 2>/dev/null
umount -R /mnt 2>/dev/null
vgchange -a n 2>/dev/null
cryptsetup close cryptlvm 2>/dev/null
killall -s 9 cryptsetup 2>/dev/null

# Enable exectued commands print and enforce inited vars.
set -xe

# Partition the disk.
parted -s -a optimal $target_disk mklabel gpt
parted -s -a optimal $target_disk mkpart "BOOT" fat32 0% 512MiB
parted -s -a optimal $target_disk set 1 esp on
parted -s -a optimal $target_disk mkpart "CRYPT" ext4 512MiB 100%

# Set up LUKS encrypted container.
echo -ne "$LUKS_PASSWORD" | cryptsetup luksFormat ${target_disk}p2 -d -
echo -ne "$LUKS_PASSWORD" | cryptsetup open ${target_disk}p2 cryptlvm -d -

# Create logical volumes.
pvcreate /dev/mapper/cryptlvm
vgcreate $lv_name /dev/mapper/cryptlvm
lvcreate -L 12G $lv_name -n swap
lvcreate -l 100%FREE $lv_name -n root

# Make filesystems.
mkfs.fat -F32 ${target_disk}p1
mkswap -f /dev/$lv_name/swap
mkfs.ext4 -qF /dev/$lv_name/root

# Mount filesystems.
mount /dev/$lv_name/root /mnt
mkdir /mnt/boot
mount ${target_disk}p1 /mnt/boot
swapon /dev/$lv_name/swap

# Basestrap the system and install lvm hooks.
basestrap /mnt runit elogind-runit base base-devel networkmanager networkmanager-runit vi
basestrap /mnt linux linux-firmware
fstabgen -U /mnt > /mnt/etc/fstab
sed -s 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block \
encrypt keyboard keymap lvm2 resume filesystems fsck)/g' -i /mnt/etc/mkinitcpio.conf
basestrap /mnt cryptsetup lvm2 mkinitcpio grub efibootmgr

# Install grub.
cryptuuid=$(blkid -s UUID -o value ${target_disk}p2)
swapuuid=$(blkid -s UUID -o value /dev/$lv_name/swap)
sed -s "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"\
cryptdevice=UUID=$cryptuuid:lvm-system loglevel=3 quiet resume=UUID=$swapuuid net.ifnames=0\"/g" \
	-i /mnt/etc/default/grub
sed -s 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/g' -i /mnt/etc/default/grub
artix-chroot /mnt sh -c 'grub-install --target=x86_64-efi --efi-directory=/boot \
--bootloader-id=grub && grub-mkconfig -o /boot/grub/grub.cfg'

# Set root password and sudoers.
artix-chroot /mnt sh -c "echo root:${ROOT_PASSWD} | chpasswd"
sed -s 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL \
Defaults rootpw,pwfeedback/g' -i /mnt/etc/sudoers

# Set hosts and link NetworkManager.
echo "${HOSTNAME}" > /mnt/etc/hostname
echo "127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}" >> /mnt/etc/hosts
artix-chroot /mnt sh -c 'ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default'

# Set locale and default timezone.
echo 'LANG="en_US.UTF-8"
LC_COLLATE="C"' > /mnt/etc/locale.conf
sed -s 's/#en_US/en_US/g' -i /mnt/etc/locale.gen
artix-chroot /mnt sh -c 'locale-gen'
artix-chroot /mnt sh -c 'ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime && hwclock -w'

# Create personal user.
artix-chroot /mnt sh -c "useradd -m ${USER_NAME}"
artix-chroot /mnt sh -c "echo root:${USER_PASSWD} | chpasswd"
artix-chroot /mnt sh -c "usermod -a -G wheel ${USER_NAME}"

# Perform cleanups.
swapoff /dev/$lv_name/swap
umount -R /mnt
vgchange -a n
cryptsetup close cryptlvm

# Disable exectued commands print.
set +x

echo "Artix installed :)"
