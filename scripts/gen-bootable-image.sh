#!/usr/bin/env bash
set -e

function test-command() {
    command -v $1 >/dev/null 2>&1 || { echo >&2 "The command \"$1\" is required.  Try \"apt-get install $2\"."; exit 1; }
}

test-command debootstrap debootstrap
test-command arch-chroot arch-install-scripts
test-command genfstab arch-install-scripts
test-command parted parted

# Download the debs to be used to install debian
if [ ! -e "debs.tar.gz" ]; then
    debootstrap --verbose \
        --make-tarball=debs.tar.gz \
	    --include=linux-image-amd64,grub2 \
	    stable rootfs https://deb.debian.org/debian
fi

# Create our hard disk
rm -rf boot.img
truncate -s 20G boot.img
parted -s boot.img \
        mklabel msdos \
        mkpart primary 0% 2GiB \
        mkpart primary 2GiB 2.5GiB \
        mkpart primary 2.5GiB 3GiB \
        mkpart primary 3GiB 100%

# Partition layout:
# 1. The base recovery os
# 2. Darch configuration (/etc/darch)
# 3. Home directory
# 3. Darch stage/images

# Mount the newly created drive
loop_device=`losetup --partscan --show --find boot.img`

# Format the partitions
mkfs.ext4 ${loop_device}p1
mkfs.ext4 ${loop_device}p2
mkfs.ext4 ${loop_device}p3
mkfs.ext4 ${loop_device}p4

# Mount the new partitions
rm -rf rootfs && mkdir rootfs
mount ${loop_device}p1 rootfs
mkdir -p rootfs/etc/darch
mount ${loop_device}p2 rootfs/etc/darch
mkdir rootfs/home
mount ${loop_device}p3 rootfs/home
mkdir -p rootfs/var/lib/darch
mount ${loop_device}p4 rootfs/var/lib/darch

# Generate the rootfs
debootstrap --verbose \
    --unpack-tarball=$(pwd)/debs.tar.gz \
    --include=linux-image-amd64,grub2 \
    stable rootfs https://deb.debian.org/debian

# Generate fstab (removing comments and whitespace)
genfstab -U -p rootfs | sed -e 's/#.*$//' -e '/^$/d' > rootfs/etc/fstab

# Set the computer name
echo "darch-demo" > rootfs/etc/hostname

# Script to install everything
cat <<EOF > rootfs/runme
#!/bin/sh

# Update all the packages
apt-get update

# Install network manager for networking and SSH
apt-get -y install network-manager openssh-server 

# Install GRUB
/sbin/grub-install ${loop_device}
/sbin/grub-mkconfig -o /boot/grub/grub.cfg

# Create the default users
apt-get -y install sudo
/usr/bin/bash -c 'echo -en "root\nroot" | passwd'
/sbin/useradd -m -G users,sudo -s /usr/bin/bash darch
/usr/bin/bash -c 'echo -en "darch\ndarch" | passwd darch'

# Install Darch
apt-get -y install curl gnupg software-properties-common
/bin/bash -c "curl -L https://raw.githubusercontent.com/godarch/debian-repo/master/key.pub | apt-key add -"
add-apt-repository 'deb https://raw.githubusercontent.com/godarch/debian-repo/master/darch testing main'
apt-get update
apt-get -y install darch
mkdir -p /etc/containerd
echo "root = \"/var/lib/darch/containerd\"" > /etc/containerd/config.toml
systemctl enable containerd

# Setup the fstab hooks for Darch
cat /etc/fstab | tail -n +2 > /etc/darch/hooks/default_fstab
echo "*=default_fstab" > /etc/darch/hooks/fstab.config

# Run grub-mkconfig again to ensure it loads the Darch grub config file
grub-mkconfig -o /boot/grub/grub.cfg

# Clone our examples repo
apt-get -y install git
git clone https://github.com/godarch/example-recipes.git /home/darch/example-recipes
mkdir /home/darch/Desktop
ln -s /home/darch/example-recipes /home/darch/Desktop/Recipes
chown -R darch:darch /home/darch/

EOF
chmod +x rootfs/runme
arch-chroot rootfs /runme

# Clean up
umount rootfs/etc/darch
umount rootfs/var/lib/darch
umount rootfs/home
umount rootfs
losetup -d ${loop_device}

echo "------------------------"
echo "Finished creating the boot.img file."
echo "This file bootable drive that could be dd'd directly to a drive, or converted to a virtual machine."
echo ""
echo "Commands for VMs"
echo "     VirtualBox:   qemu-img convert -O vdi boot.img boot.vdi"
echo "     VMWare:       qemu-img convert -O vmdk boot.img boot.vmdk"
echo ""
echo "NOTE: Ensure your VM has at least 4G of RAM allocated."
echo ""
echo "Please follow further instructions here:"
echo "https://pknopf.com/post/2018-11-09-give-ubuntu-darch-a-quick-ride-in-a-virtual-machine/"
echo "------------------------"
