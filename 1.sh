#!/bin/bash

# Function to convert GiB to MiB
gib_to_mib() {
    echo $(( $1 * 1024 ))
}

# Function to convert MiB to GiB
mib_to_gib() {
    echo $(( $1 / 1024 ))
}

set -e

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root."
    exit 1
fi

echo "Available drives that are not mounted:"
lsblk -dn -o NAME | while read dev; do
    dev_path="/dev/$dev"
    if ! lsblk -no MOUNTPOINT "$dev_path" | grep -qv '^$'; then
        echo "$dev_path"
    fi
done
echo ""

while true; do
    read -p "Enter the drive path (e.g., /dev/sda): " DRIVE

    if [ ! -b "$DRIVE" ]; then
        echo "Drive $DRIVE does not exist. Please try again."
        continue
    fi

    if lsblk -no MOUNTPOINT "$DRIVE" | grep -qv '^$'; then
        echo "Drive $DRIVE is mounted to a mountpoint. Please choose another drive."
        continue
    fi

    partitions=$(ls ${DRIVE}?* 2>/dev/null)
    if [ -n "$partitions" ]; then
        echo "Warning: The drive $DRIVE has existing partitions:"
        echo "$partitions"
        read -p "Do you want to override the file structure and proceed? Type 'yes' to confirm: " CONFIRM
        if [ "$CONFIRM" != "yes" ]; then
            echo "Not confirmed. Please select another drive."
            continue
        fi
        # Wipe existing partitions table
        wipefs -a "$DRIVE"
    fi

    echo "Proceeding with drive $DRIVE..."
    break
done

DRIVE_SIZE_MIB=$(lsblk -b -dn -o SIZE "$DRIVE")
DRIVE_SIZE_MIB=$((DRIVE_SIZE_MIB / 1024 / 1024))

while true; do
    read -p "Enter the desired size for the root partition in GiB (minimum 40): " ROOT_GIB
    if [[ "$ROOT_GIB" =~ ^[0-9]+$ ]] && [ "$ROOT_GIB" -ge 40 ]; then
        break
    else
        echo "Root partition must be at least 40 GiB."
    fi
done
ROOT_MIB=$(gib_to_mib $ROOT_GIB)

while true; do
    read -p "Enter the desired size for the swap partition in GiB (minimum 2): " SWAP_GIB
    if [[ "$SWAP_GIB" =~ ^[0-9]+$ ]] && [ "$SWAP_GIB" -ge 2 ]; then
        break
    else
        echo "Swap partition must be at least 2 GiB."
    fi
done
SWAP_MIB=$(gib_to_mib $SWAP_GIB)

BOOT_MIB=1024
TOTAL_NEEDED_MIB=$((BOOT_MIB + SWAP_MIB + ROOT_MIB))

if [ "$TOTAL_NEEDED_MIB" -ge "$DRIVE_SIZE_MIB" ]; then
    echo "ERROR: Partition sizes exceed available drive space ($DRIVE_SIZE_MIB MiB)."
    exit 1
fi

HOME_MIB=$((DRIVE_SIZE_MIB - TOTAL_NEEDED_MIB))
HOME_GIB=$(mib_to_gib $HOME_MIB)

if [ "$HOME_GIB" -lt 25 ]; then
    echo "WARNING: Home partition will be less than 25 GiB ($HOME_GIB GiB)."
fi

echo ""
echo "Partition plan for $DRIVE:"
echo "  1: Boot (EFI):  1024 MiB (ef00)"
echo "  2: Swap:        ${SWAP_MIB} MiB ($SWAP_GIB GiB, 8200)"
echo "  3: Root:        ${ROOT_MIB} MiB ($ROOT_GIB GiB, 8300)"
echo "  4: Home:        ${HOME_MIB} MiB (~${HOME_GIB} GiB, 8300)"

read -p "Proceed with partitioning and formatting? Type 'yes' to confirm: " FINAL_CONFIRM
if [ "$FINAL_CONFIRM" != "yes" ]; then
    echo "Partitioning cancelled."
    exit 1
fi

echo "Partitioning drive with gdisk..."

gdisk $DRIVE <<EOF
o
Y
n
1

+${BOOT_MIB}M
ef00
n
2

+${SWAP_MIB}M
8200
n
3

+${ROOT_MIB}M
8300
n
4


8300
w
Y
EOF

echo "Waiting for kernel to update partition table..."
sleep 2
partprobe "$DRIVE"
sleep 2

# Get partition names (e.g. /dev/sda1, /dev/sda2, ...)
PART1="${DRIVE}1"
PART2="${DRIVE}2"
PART3="${DRIVE}3"
PART4="${DRIVE}4"

echo "Formatting partitions..."
mkfs.fat -F32 "$PART1"
mkswap "$PART2"
mkfs.ext4 "$PART3"
mkfs.ext4 "$PART4"

echo "Mounting partitions..."
mount "$PART3" /mnt
mkdir -p /mnt/boot
mount "$PART1" /mnt/boot
swapon "$PART2"
mkdir -p /mnt/home
mount "$PART4" /mnt/home

echo "All partitions created, formatted, and mounted:"
echo "  Boot:  $PART1 -> /mnt/boot"
echo "  Swap:  $PART2 -> activated"
echo "  Root:  $PART3 -> /mnt"
echo "  Home:  $PART4 -> /mnt/home"