#!/bin/bash

# This script will surely destroy all your data.
# this script will maybe install debian on your computer
# do not run it if there is any storage device with important data present.
# script will enroll decryption key in EUFI TPM2
# script will modify EUFI EFI variables
# only use to install debian on the copmputer on which the script is executed

set -euo pipefail
# -e: exit on error
# -u: exit on undefined variables
# -o pipefail: exit if any command in a pipeline fails


# edit this:
readonly DISK=/dev/sdb
readonly USER_FULL_NAME="User User"
readonly USERNAME=user
readonly USER_PASSWORD=user2

readonly LOCALE=en_CA.UTF-8
readonly KEYMAP=us
readonly TIMEZONE=America/Montreal

readonly DEBIAN_VERSION=trixie
readonly HOSTNAME=trixie-rescue
readonly BACKPORTS_VERSION=${DEBIAN_VERSION}  # TODO append "-backports" when available

# Only if you must, sudo is largely prefered
#readonly ROOT_PASSWORD=root2

readonly USE_LUKS=true
readonly LUKS_PASSWORD=luks2
readonly USE_TPM_TO_UNLOCK_LUKS=true
readonly LUKS_TPM_KEYFILE=luks_tpm.key

#readonly ENABLE_POPCON=false

#readonly NVIDIA_PACKAGE=
#readonly SSH_PUBLIC_KEY=
#readonly AFTER_INSTALLED_CMD=

readonly TARGET=/target

readonly BTRFS_FSFLAGS="compress=zstd:1"
readonly BTRFS_ADMIN_MOUNT=/mnt/btrfs_admin_mount

g_kernel_params="rw quiet splash"
g_fstab_content=""
# g_tpm_available
# g_swap_size
g_luks_root_partition=

function notify ()
{
    echo -e "\033[32m$@\033[0m"
}

function check_tpm()
{
    if tpm2_getcap properties-fixed 2>/dev/null | grep -q TPM2_PT_FAMILY_INDICATOR; then
        notify "TPM is available"
        g_tpm_available=true
    else
        notify "TPM not available"
        g_tpm_available=false
    fi
}


function setup_host()
{
    notify "install required packages"
    apt update -y
    apt install -y cryptsetup debootstrap uuid-runtime btrfs-progs dosfstools pv gdisk parted systemd-container systemd-cryptsetup tpm2-tools tpm-udev
    # check the host capabilities
    # TPM

    check_tpm

    # Make the swap equal to RAM + 1
    g_swap_size=$(($(free --giga | awk '/^Mem:/ {print $2}') + 1))
}

function prepare_installation_disk()
{
    local installation_disk=$1

    notify "setting up installation disk ${installation_disk}"
    wipefs -a ${installation_disk}

    # alternatively the disk can be overwritten with a random pattern which is very slow

    # single-pass random overwrite, adequate for most cases
    # dd if=/dev/urandom of=${installation_disk} bs=1M status=progress

    # multiple-pass overwrite using shred:
    # shred -vfz -n 3 ${installation_disk}

    # NIST 800-88 compliant (chatbot claim) single pass (recommended for modern drives):
    # dd if=/dev/zero of=${installation_disk} bs=1M status=progress

    # for SSDs specifically, use secure erase if supported:
    # hdparm --user-master u --security-set-pass p ${installation_disk}
    # hdparm --user-master u --security-erase p ${installation_disk}
}


function setup_system_partition()
{
    local installation_disk=$1
    local efi_system_partition_uuid=$(uuidgen)
    local efi_system_partition_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

    notify "creating system partition with uuid ${efi_system_partition_uuid} on ${installation_disk}"
    sgdisk  --new=1:2048:+1G --typecode=1:${efi_system_partition_type} \
            --change-name=1:"EFI system partition" \
            --partition-guid=1:${efi_system_partition_uuid} ${installation_disk}

    # sync & reread partition tables
    partprobe
    udevadm settle

    notify "formatting ${efi_system_partition_uuid}"
    local efi_system_partition=/dev/disk/by-partuuid/${efi_system_partition_uuid}
    ls ${efi_system_partition}
    mkfs.vfat ${efi_system_partition}

    g_fstab_content+="PARTUUID=${efi_system_partition_uuid} /boot/efi vfat defaults,umask=077 0 2"
    g_fstab_content+=$'\n'

    # return efi_system_partition_uuid
    g_efi_system_partition_uuid=${efi_system_partition_uuid}
}

function mount_system_partition()
{
    efi_system_partition_uuid=$1
    local efi_system_partition=/dev/disk/by-partuuid/${efi_system_partition_uuid}
    notify "mounting system partition ${efi_system_partition} on ${TARGET}/boot/efi"
    mkdir -p ${TARGET}/boot/efi
    mount ${efi_system_partition} ${TARGET}/boot/efi -o umask=077
}

function setup_root_partition()
{

    local installation_disk=$1

    local root_partition_uuid=$(uuidgen)

    local root_partition_type="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"

    notify "creating root partition with uuid ${root_partition_uuid} on ${installation_disk}"

    sgdisk --new=2:0:0 \
           --typecode=2:${root_partition_type} \
           --change-name=2:"Root partition" \
           --partition-guid=2:${root_partition_uuid} \
           $installation_disk

    # sync & reread partition tables
    partprobe
    udevadm settle

    # return root_partition_uuid and root_partition
    g_root_partition_uuid=${root_partition_uuid}
    g_root_partition="/dev/disk/by-partuuid/${root_partition_uuid}"
}

function setup_luks()
{
    local root_partition_uuid=$1

    local root_partition="/dev/disk/by-partuuid/${root_partition_uuid}"

    notify "setup luks on ${root_partition}"

    # make sure udev finished its thing
    udevadm settle

    # password is always present
    #echo -n "${LUKS_PASSWORD}" | cryptsetup luksFormat ${root_partition} --type luks2 --key-file=-
    printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat "$root_partition" --type luks2 --batch-mode --key-file -

    notify "open luks on root"
    echo "printf '%s' "$LUKS_PASSWORD" | cryptsetup luksOpen "$root_partition" root --key-file -"
    printf '%s' "$LUKS_PASSWORD" | cryptsetup luksOpen "$root_partition" root --key-file -

    # return luks_root_partition
    g_luks_root_device=/dev/mapper/root
    g_luks_root_partition=${root_partition}
    g_root_partition=${g_luks_root_device}
}


function setup_btrfs()
{
    local btrfs_root_partition=$1

    local btrfs_uuid=$(uuidgen)
    notify "create root filesystem on ${btrfs_root_partition}"
    mkfs.btrfs -U ${btrfs_uuid} ${btrfs_root_partition}

    notify "mount btrfs admin subvolume on ${BTRFS_ADMIN_MOUNT}"
    mkdir -p ${BTRFS_ADMIN_MOUNT}
    mount ${btrfs_root_partition} ${BTRFS_ADMIN_MOUNT} -o rw,${BTRFS_FSFLAGS},subvolid=5,skip_balance

    notify "create @ subvolume on ${BTRFS_ADMIN_MOUNT}"
    btrfs subvolume create ${BTRFS_ADMIN_MOUNT}/@

    notify "create @home subvolume on ${BTRFS_ADMIN_MOUNT}"
    btrfs subvolume create ${BTRFS_ADMIN_MOUNT}/@home

    notify "create @swap subvolume for swap file on ${BTRFS_ADMIN_MOUNT}"
    btrfs subvolume create ${BTRFS_ADMIN_MOUNT}/@swap
    chmod 700 ${BTRFS_ADMIN_MOUNT}/@swap

    notify "mount root and home subvolume on ${TARGET}"
    mkdir -p ${TARGET}
    mount ${btrfs_root_partition} ${TARGET} -o ${BTRFS_FSFLAGS},subvol=@
    mkdir -p ${TARGET}/home
    mount ${btrfs_root_partition} ${TARGET}/home -o ${BTRFS_FSFLAGS},subvol=@home

    notify "mount swap subvolume on ${TARGET}"
    mkdir -p ${TARGET}/swap
    mount ${btrfs_root_partition} ${TARGET}/swap -o noatime,subvol=@swap

    notify "make swap file at ${TARGET}/swap/swapfile"
    btrfs filesystem mkswapfile --size ${g_swap_size}G ${TARGET}/swap/swapfile

    # this would let host kernel use the swap file on the ${TARGET}, we don't want that
    # swapon ${TARGET}/swap/swapfile

    notify "cleanup administrative mount"
    umount ${BTRFS_ADMIN_MOUNT}
    rmdir ${BTRFS_ADMIN_MOUNT}

    swapfile_offset=$(btrfs inspect-internal map-swapfile -r ${TARGET}/swap/swapfile)

    g_kernel_params="${g_kernel_params} rootfstype=btrfs rootflags=${BTRFS_FSFLAGS},subvol=@ resume=${btrfs_root_partition} resume_offset=${swapfile_offset}"

    # this should go with dracut, but not a biggie
    g_kernel_params="${g_kernel_params} rd.auto=1"

    g_fstab_content+="UUID=${btrfs_uuid} / btrfs defaults,subvol=@,${BTRFS_FSFLAGS} 0 1"
    g_fstab_content+=$'\n'
    g_fstab_content+="UUID=${btrfs_uuid} /home btrfs defaults,subvol=@home,${BTRFS_FSFLAGS} 0 1"
    g_fstab_content+=$'\n'
    g_fstab_content+="UUID=${btrfs_uuid} /swap btrfs defaults,subvol=@swap,noatime,${BTRFS_FSFLAGS} 0 0"
    g_fstab_content+=$'\n'
    g_fstab_content+="/swap/swapfile none swap defaults 0 0"
    g_fstab_content+=$'\n'

    # return btrfs_uuid
    g_btrfs_uuid=${btrfs_uuid}
}


function do_debootstrap()
{
    notify "install debian on ${TARGET}"
    debootstrap --include=locales ${DEBIAN_VERSION} ${TARGET} http://deb.debian.org/debian
}

setup_fstab()
{
    notify "writing fstab"
    echo -e "${g_fstab_content}"
    echo "${g_fstab_content}" > ${TARGET}/etc/fstab
}

get_sources_list()
{
    # per https://wiki.debian.org/SourcesList
    echo "Types: deb"
    echo "URIs: http://deb.debian.org/debian/"
    echo "Suites: ${DEBIAN_VERSION} ${DEBIAN_VERSION}-updates ${DEBIAN_VERSION}-backports"
    echo "Components: main contrib non-free non-free-firmware"
    echo "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
    echo
    echo "Types: deb"
    echo "URIs: http://security.debian.org/debian-security/"
    echo "Suites: ${DEBIAN_VERSION}-security"
    echo "Components: main contrib non-free non-free-firmware"
    echo "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
}

function setup_sources_list()
{
    notify "setup sources list"
    rm -f ${TARGET}/etc/apt/sources.list
    get_sources_list > ${TARGET}/etc/apt/sources.list.d/debian.sources
}

function setup_firstboot()
{
    notify "setup locale, keymap, timezone, hostname, root password, kernel command line"
    echo -e "systemd-firstboot --locale=${LOCALE} \
    --keymap=${KEYMAP} \
    --timezone=${TIMEZONE} \
    --hostname=${HOSTNAME} \
    --root-password=${USER_PASSWORD} \
    --kernel-command-line="${g_kernel_params}" \
    --root=${TARGET}"

    systemd-firstboot --locale=${LOCALE} \
                      --keymap=${KEYMAP} \
                      --timezone=${TIMEZONE} \
                      --hostname=${HOSTNAME} \
                      --kernel-command-line="${g_kernel_params}" \
                      --root=${TARGET} \
                      --force

    # damn thing will not generate locales, nor set hosts
    echo "127.0.1.1   $HOSTNAME" >> ${TARGET}/etc/hosts
    # don't like sed option
    sed -i "s/# $LOCALE/$LOCALE/" ${TARGET}/etc/locale.gen
}

function target_code()
{
    export DEBIAN_FRONTEND=noninteractive

    notify "generating locales"
    locale-gen

    notify "set up user ${USERNAME} user"
    adduser --disabled-password --gecos "${USER_FULL_NAME}" ${USERNAME}
    adduser ${USERNAME} sudo
    echo ${USERNAME}:${USER_PASSWORD} | chpasswd

    notify "install standard packages"
    apt update -y
    apt install -y dctrl-tools
    apt install -y $(grep-dctrl -n -s Package -F Priority standard /var/lib/apt/lists/*_Packages)

    notify "install kernel and related packages"
    apt-cache policy linux-image-amd64
    apt-mark showhold

    apt install -y -t ${BACKPORTS_VERSION} linux-image-amd64 firmware-linux plymouth-theme-hamara dracut
    apt full-upgrade -t ${DEBIAN_VERSION}-security -y

    notify "install systemd packages"
    apt install -y -t ${BACKPORTS_VERSION} systemd systemd-boot systemd-cryptsetup cryptsetup

    notify "install more packages"
    apt install -y tasksel network-manager sudo
    apt install -y -t ${BACKPORTS_VERSION} btrfs-progs btrfsmaintenance

    bootctl install

    notify "configuring dracut"
    echo 'add_dracutmodules+=" systemd btrfs "' > /etc/dracut.conf.d/89-btrfs.conf
    # not needed, firstboot sets kernel params and takes precedence
    # echo "kernel_cmdline=\"${g_kernel_params}\"" >> /etc/dracut.conf.d/89-btrfs.conf
    if [ "${USE_LUKS}" = "true" ]; then
        echo 'add_dracutmodules+=" crypt "' > /etc/dracut.conf.d/90-luks.conf

        if [ "${USE_TPM_TO_UNLOCK_LUKS}" = "true" ]; then
            apt install -y tpm2-tools

            check_tpm

            if [ "${g_tpm_available}" = "true" ]; then

                notify "creating luks key for tpm enrollment"

                dd if=/dev/random of=${LUKS_TPM_KEYFILE} bs=512 count=1
                chmod 600 ${LUKS_TPM_KEYFILE}

                notify "adding tpm key to luks"

                printf '%s' "$LUKS_PASSWORD" | cryptsetup luksAddKey --batch-mode --key-file - "$LUKS_ROOT_PARTITION" "${LUKS_TPM_KEYFILE}"

                notify "enrolling luks key in tpm"

                systemd-cryptenroll --unlock-key-file=${LUKS_TPM_KEYFILE} --tpm2-device=auto ${LUKS_ROOT_PARTITION} --tpm2-pcrs="7+14"

                sudo sed -i 's/$/ rd.luks.options=tpm2-device=auto/' /etc/kernel/cmdline

                echo 'add_dracutmodules+=" tpm2-tss "' > /etc/dracut.conf.d/90-tpm.conf
            fi
        fi
    fi

    notify "removing unused packages"

    apt autoremove -y

    #bootctl update

#    export DEBIAN_FRONTEND=noninteractive
#
#    systemctl disable systemd-networkd.service  # seems to fight with NetworkManager
#    systemctl disable systemd-networkd.socket
#    systemctl disable systemd-networkd-wait-online.service

#    if [ ! -z "${NVIDIA_PACKAGE}" ]; then
#      # TODO the debian page says to do this instead:
#      # echo "options nvidia-drm modeset=1" >> /etc/modprobe.d/nvidia-options.conf
#      # g_kernel_params="${g_kernel_params} nvidia-drm.modeset=1"
#    fi

#    if [ "$ENABLE_POPCON" = true ] ; then
#        notify enabling popularity-contest
#        echo "popularity-contest      popularity-contest/participate  boolean true" | debconf-set-selections
#        apt install -y popularity-contest
#    fi

#    if [ ! -z "${SSH_PUBLIC_KEY}" ]; then
#        notify adding ssh public key to user and root authorized_keys file
#        mkdir -p /root/.ssh
#        chmod 700 /root/.ssh
#        echo "${SSH_PUBLIC_KEY}" > /root/.ssh/authorized_keys
#        chmod 600 /root/.ssh/authorized_keys
#
#        if [ ! -z "${USERNAME}" ]; then
#            mkdir -p /home/${USERNAME}/.ssh
#            chmod 700 /home/${USERNAME}/.ssh
#            echo "${SSH_PUBLIC_KEY}" > ${TARGET}/home/${USERNAME}/.ssh/authorized_keys
#            chmod 600 /home/${USERNAME}/.ssh/authorized_keys
#            chown -R ${USERNAME} /home/${USERNAME}/.ssh
#        fi
#
#        notify installing openssh-server
#        apt install -y openssh-server
#    fi

#    if [ -z "${NON_INTERACTIVE}" ]; then
#        notify running tasksel
#        # XXX this does not open for some reason
#        tasksel
#    fi

#    if [ ! -z "${NVIDIA_PACKAGE}" ]; then
#        notify installing ${NVIDIA_PACKAGE}
#        # XXX dracut-install: ERROR: installing nvidia-blacklists-nouveau.conf nvidia.conf
#        echo 'install_items+=" /etc/modprobe.d/nvidia-blacklists-nouveau.conf /etc/modprobe.d/nvidia.conf /etc/modprobe.d/nvidia-options.conf "' > ${TARGET}/etc/dracut.conf.d/10-nvidia.conf
#        chroot ${TARGET}/ apt install -t ${BACKPORTS_VERSION} -y "${NVIDIA_PACKAGE}" nvidia-driver-libs:i386 linux-headers-amd64
#    fi
}


function host_cleanup()
{
    notify "cleaning up: umounting all filesystems"

    umount ${TARGET}/boot/efi
    umount -R ${TARGET}

    if [ "${USE_LUKS}" = "true" ]; then
        notify closing luks
        cryptsetup luksClose ${g_luks_root_device}
    fi
}


if [ "$1" = "host" ]; then
    setup_host
    prepare_installation_disk ${DISK}
    setup_system_partition ${DISK}
    setup_root_partition ${DISK}
    setup_luks ${g_root_partition_uuid}
    setup_btrfs ${g_root_partition}
    mount_system_partition ${g_efi_system_partition_uuid}

    do_debootstrap
    setup_fstab
    setup_sources_list
    setup_firstboot

    systemd-nspawn  --bind=my_installer.sh:/my_installer.sh \
                    --bind=${DISK} \
                    --bind=/sys/firmware/efi/efivars:/sys/firmware/efi/efivars \
                    --bind=/dev/tpm0 \
                    --bind=/dev/tpmrm0 \
                    --bind=/sys/class/tpm \
                    --bind=$(realpath ${g_luks_root_partition})  \
                    --setenv=LUKS_ROOT_PARTITION=$(realpath ${g_luks_root_partition}) \
                    --directory=${TARGET}\
                    -- /my_installer.sh target

    systemd-nspawn  --bind=my_installer.sh:/my_installer.sh \
                    --bind=/dev/tpm0 \
                    --bind=/dev/tpmrm0 \
                    --bind=/sys/class/tpm \
                    --bind=$(realpath ${g_luks_root_partition})  \
                    --setenv=LUKS_ROOT_PARTITION=$(realpath ${g_luks_root_partition}) \
                    --machine=${HOSTNAME} \
                    --bind=${DISK} \
                    --bind=/sys/firmware/efi/efivars:/sys/firmware/efi/efivars \
                    --directory=${TARGET}


    notify "INSTALLATION FINISHED"
fi

# has to be "target" not just different than "host"
if [ "$1" = "target" ]; then
    target_code
fi

#if [ ! -z "${AFTER_INSTALLED_CMD}" ]; then
#  notify running ${AFTER_INSTALLED_CMD}
#  sh -c "${AFTER_INSTALLED_CMD}"
#fi

