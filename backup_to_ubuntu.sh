#!/bin/su root

mkdir -p /mnt/ubuntu /mnt/arch/efi /mnt/arch/fs

mount /dev/sda4 /mnt/ubuntu
mount /dev/sdb1 /mnt/arch/efi
mount /dev/sdb3 /mnt/arch/fs
mkdir -p /mnt/ubuntu/home/ohrf/dr-usb
rsync -aHXAv /mnt/arch/ /mnt/ubuntu/home/ohrf/dr-usb
umount -R /mnt/ubuntu
umount -R /mnt/arch/efi
umount -R /mnt/arch/fs
umount -R /mnt/arch
umount -R /mnt
