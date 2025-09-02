#!/bin/bash

# Function to convert GiB to MiB
gib_to_mib() {
    echo $(( $1 * 1024 ))
}

# Function to convert MiB to GiB
mib_to_gib() {
    echo $(( $1 / 1024 ))
}

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
echo "  Boot:  1024 MiB (EFI System Partition, type ef00)"
echo "  Swap:  ${SWAP_MIB} MiB ($SWAP_GIB GiB, type 8200)"
echo "  Root:  ${ROOT_MIB} MiB ($ROOT_GIB GiB, type 8300)"
echo "  Home:  ${HOME_MIB} MiB (~${HOME_GIB} GiB, type 8300)"

read -p "Proceed with partitioning? Type 'yes' to confirm: " FINAL_CONFIRM
if [ "$FINAL_CONFIRM" != "yes" ]; then
    echo "Partitioning cancelled."
    exit 1
fi

# Partition start/end calculations
PART_BOOT_START=2048         # Start after 1MiB (usually sector 2048)
PART_BOOT_END=$((PART_BOOT_START + BOOT_MIB * 2048 / 1024 - 1))

PART_SWAP_START=$((PART_BOOT_END + 1))
PART_SWAP_END=$((PART_SWAP_START + SWAP_MIB * 2048 / 1024 - 1))

PART_ROOT_START=$((PART_SWAP_END + 1))
PART_ROOT_END=$((PART_ROOT_START + ROOT_MIB * 2048 / 1024 - 1))

PART_HOME_START=$((PART_ROOT_END + 1))
PART_HOME_END=                # Use the rest of the space

# Uncomment to actually run the partitioning (DANGEROUS: erases all data on drive!)
gdisk $DRIVE <<EOF
o
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