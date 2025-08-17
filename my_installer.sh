#!/bin/bash
set -euo pipefail

# -e: exit on error
# -u: exit on undefined variables
# -o pipefail: exit if any command in a pipeline fails


# edit this:
readonly DISK=/dev/sdb
readonly USERNAME=user
readonly USER_FULL_NAME="Debian User"
readonly USER_PASSWORD=hunter2
# Only if you must, sudo is largely prefered
readonly ROOT_PASSWORD=changeme
readonly DISABLE_LUKS=false
readonly LUKS_PASSWORD=luke
readonly ENABLE_TPM=true
readonly HOSTNAME=debian13
# Make the swap equal to RAM + 1
readonly SWAP_SIZE=$(($(free --giga | awk '/^Mem:/ {print $2}') + 1))
readonly NVIDIA_PACKAGE=
readonly ENABLE_POPCON=false
readonly LOCALE=en_CA.UTF-8
readonly KEYMAP=us
readonly TIMEZONE=America/Montreal
readonly SSH_PUBLIC_KEY=
readonly AFTER_INSTALLED_CMD=

readonly LUKS_KEYFILE=luks.key

readonly DEBIAN_VERSION=trixie
readonly BACKPORTS_VERSION=${DEBIAN_VERSION}  # TODO append "-backports" when available
# see https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html#--tpm2-pcrs=PCR
readonly TPM_PCRS="7+14"
readonly BTRFS_FSFLAGS="compress=zstd:1"
readonly DEBIAN_FRONTEND=noninteractive

btrfs_admin_mount=/mnt/btrfs_admin_mount
target=/target
g_kernel_params="rw quiet splash"
g_fstab_content=""



function notify () {
    echo -e "\033[32m$@\033[0m"
}

function wait_for_file {
    filename="$1"
    while [ ! -e $filename ]
    do
        echo waiting for $filename to be created
        sleep 3
    done
}

function setup_host()
{
    notify "install required packages"
    apt-get update -y
    apt-get install -y cryptsetup debootstrap uuid-runtime btrfs-progs dosfstools pv gdisk parted systemd-container
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
    notify "mounting system partition ${efi_system_partition} on ${target}/boot/efi"
    mkdir -p ${target}/boot/efi
    mount ${efi_system_partition} ${target}/boot/efi -o umask=077
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

    notify "creating luks key and saving it in ${LUKS_KEYFILE}"

    dd if=/dev/random of=${LUKS_KEYFILE} bs=512 count=1

    cryptsetup luksFormat ${root_partition} --type luks2 --batch-mode --key-file $LUKS_KEYFILE

    echo -n "${LUKS_PASSWORD}" | cryptsetup --key-file=${LUKS_KEYFILE} luksAddKey ${root_partition}

    notify "open luks on root"
    cryptsetup luksOpen ${root_partition} root --key-file ${LUKS_KEYFILE}

    g_kernel_params="rd.luks.options=tpm2-device=auto ${g_kernel_params}"

    # return luks_root_partition
    g_luks_root_partition=/dev/mapper/root
    g_root_partition=${g_luks_root_partition}
}

function setup_btrfs()
{
    local btrfs_root_partition=$1

    local btrfs_uuid=$(uuidgen)
    notify "create root filesystem on ${btrfs_root_partition}"
    mkfs.btrfs -U ${btrfs_uuid} ${btrfs_root_partition}

    notify "mount btrfs admin subvolume on ${btrfs_admin_mount}"
    mkdir -p ${btrfs_admin_mount}
    mount ${btrfs_root_partition} ${btrfs_admin_mount} -o rw,${FSFLAGS},subvolid=5,skip_balance

    notify "create @ subvolume on ${btrfs_admin_mount}"
    btrfs subvolume create ${btrfs_admin_mount}/@

    notify "create @home subvolume on ${btrfs_admin_mount}"
    btrfs subvolume create ${btrfs_admin_mount}/@home

    notify "create @swap subvolume for swap file on ${btrfs_admin_mount}"
    btrfs subvolume create ${btrfs_admin_mount}/@swap
    chmod 700 ${btrfs_admin_mount}/@swap

    notify "mount root and home subvolume on ${target}"
    mkdir -p ${target}
    mount ${btrfs_root_partition} ${target} -o ${FSFLAGS},subvol=@
    mkdir -p ${target}/home
    mount ${btrfs_root_partition} ${target}/home -o ${FSFLAGS},subvol=@home

    notify "mount swap subvolume on ${target}"
    mkdir -p ${target}/swap
    mount ${btrfs_root_partition} ${target}/swap -o noatime,subvol=@swap

    notify "make swap file at ${target}/swap/swapfile"
    btrfs filesystem mkswapfile --size ${SWAP_SIZE}G ${target}/swap/swapfile

    # this would let host kernel use the swap file on the ${target}, we don't want that
    # swapon ${target}/swap/swapfile

    notify "cleanup administrative mount"
    umount ${btrfs_admin_mount}
    rmdir ${btrfs_admin_mount}

    swapfile_offset=$(btrfs inspect-internal map-swapfile -r ${target}/swap/swapfile)

    g_kernel_params="${g_kernel_params} rootfstype=btrfs rootflags=${FSFLAGS},subvol=@ resume=${btrfs_root_partition} resume_offset=${swapfile_offset}"

    # this should go with dracut, but not a biggie
    g_kernel_params="${g_kernel_params} rd.auto=1"

    g_fstab_content+="UUID=${btrfs_uuid} / btrfs defaults,subvol=@,${FSFLAGS} 0 1"
    g_fstab_content+=$'\n'
    g_fstab_content+="UUID=${btrfs_uuid} /home btrfs defaults,subvol=@home,${FSFLAGS} 0 1"
    g_fstab_content+=$'\n'
    g_fstab_content+="UUID=${btrfs_uuid} /swap btrfs defaults,subvol=@swap,noatime,${FSFLAGS} 0 0"
    g_fstab_content+=$'\n'
    g_fstab_content+="/swap/swapfile none swap defaults 0 0"
    g_fstab_content+=$'\n'

    # return btrfs_uuid
    g_btrfs_uuid=${btrfs_uuid}
}


function do_debootstrap()
{
    notify "install debian on ${target}"
    debootstrap --include=locales ${DEBIAN_VERSION} ${target} http://deb.debian.org/debian
}

setup_fstab()
{
    notify "writing fstab"
    echo -e "${g_fstab_content}"
    echo "${g_fstab_content}" > ${target}/etc/fstab
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
    rm -f ${target}/etc/apt/sources.list
    get_sources_list > ${target}/etc/apt/sources.list.d/debian.sources
}

function setup_firstboot()
{
    notify "setup locale, keymap, timezone, hostname, root password, kernel command line"
    echo -e "systemd-firstboot --locale=${LOCALE} \
    --keymap=${KEYMAP} \
    --timezone=${TIMEZONE} \
    --hostname=${HOSTNAME} \
    --kernel-command-line="${g_kernel_params}" \
    --root=${target}"

    systemd-firstboot --locale=${LOCALE} \
                      --keymap=${KEYMAP} \
                      --timezone=${TIMEZONE} \
                      --hostname=${HOSTNAME} \
                      --kernel-command-line="${g_kernel_params}" \
                      --root=${target} \
                      --force

    # damn thing will not generate locales, nor set hosts
    echo "127.0.1.1   $HOSTNAME" >> ${target}/etc/hosts
    # don't like sed option
    sed -i "s/# $LOCALE/$LOCALE/" ${target}/etc/locale.gen
}

function target_code()
{
    notify "generating locales"
    locale-gen
    notify "set up user ${USERNAME} user"
    adduser --disabled-password --gecos "${USER_FULL_NAME}" ${USERNAME}
    adduser ${USERNAME} sudo
    echo ${USERNAME}:${USER_PASSWORD} | chpasswd

    notify "install required packages"
    apt-get update -y
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y locales tasksel network-manager sudo
    apt-get install -y -t ${BACKPORTS_VERSION} systemd systemd-boot dracut btrfs-progs
    bootctl install

    notify "configuring dracut"
    echo 'add_dracutmodules+=" systemd btrfs "' > /etc/dracut.conf.d/89-btrfs.conf
    # not needed, firstboot sets kernel params and takes precedence
    # echo "kernel_cmdline=\"${g_kernel_params}\"" >> /etc/dracut.conf.d/89-btrfs.conf
    if [ "${DISABLE_LUKS}" != "true" ]; then
        echo 'add_dracutmodules+=" crypt tpm2-tss "' > /etc/dracut.conf.d/90-luks.conf
        apt-get install -y -t ${BACKPORTS_VERSION} cryptsetup tpm2-tools tpm-udev
    fi

    if [ "${DISABLE_LUKS}" != "true" -a "${ENABLE_TPM}" == "true" ]; then
        notify checking for tpm
        chmod 600 ${LUKS_KEYFILE}
        systemd-cryptenroll --tpm2-device=list > /tmp/tpm-list.txt
        if grep -qs "/dev/tpm" /tmp/tpm-list.txt ; then
            echo tpm available, enrolling
            systemd-cryptenroll --unlock-key-file=/${LUKS_KEYFILE} --tpm2-device=auto ${main_partition} --tpm2-pcrs=${TPM_PCRS}
        else
            echo tpm not available
        fi
    fi

    notify "install kernel and firmware on ${target}"
    packages=(
        btrfsmaintenance
        locales
        adduser
        passwd
        sudo
        tasksel
        network-manager
        binutils
        console-setup
        exim4-daemon-light
        kpartx
        pigz
        pkg-config
    )

    apt-get install -y "${packages[@]}"


    backports_packages=(
        linux-image-amd64
        systemd
        systemd-cryptsetup
        systemd-timesyncd
        btrfs-progs
        dosfstools
        dracut
        firmware-linux
        atmel-firmware
        bluez-firmware
        dahdi-firmware-nonfree
        firmware-amd-graphics
        firmware-ath9k-htc
        firmware-atheros
        firmware-bnx2
        firmware-bnx2x
        firmware-brcm80211
        firmware-carl9170
        firmware-cavium
        firmware-intel-misc
        firmware-intel-sound
        firmware-iwlwifi
        firmware-libertas
        firmware-misc-nonfree
        firmware-myricom
        firmware-netronome
        firmware-netxen
        firmware-qcom-soc
        firmware-qlogic
        firmware-realtek
        firmware-ti-connectivity
        firmware-zd1211
        cryptsetup
        lvm2
        mdadm
        plymouth-themes
        polkitd
        tpm2-tools
        tpm-udev
    )

    apt-get install -t ${BACKPORTS_VERSION} -y "${backports_packages[@]}"

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
#        apt-get install -y popularity-contest
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
#            echo "${SSH_PUBLIC_KEY}" > ${target}/home/${USERNAME}/.ssh/authorized_keys
#            chmod 600 /home/${USERNAME}/.ssh/authorized_keys
#            chown -R ${USERNAME} /home/${USERNAME}/.ssh
#        fi
#
#        notify installing openssh-server
#        apt-get install -y openssh-server
#    fi

#    if [ -z "${NON_INTERACTIVE}" ]; then
#        notify running tasksel
#        # XXX this does not open for some reason
#        tasksel
#    fi

#    if [ ! -z "${NVIDIA_PACKAGE}" ]; then
#        notify installing ${NVIDIA_PACKAGE}
#        # XXX dracut-install: ERROR: installing nvidia-blacklists-nouveau.conf nvidia.conf
#        echo 'install_items+=" /etc/modprobe.d/nvidia-blacklists-nouveau.conf /etc/modprobe.d/nvidia.conf /etc/modprobe.d/nvidia-options.conf "' > ${target}/etc/dracut.conf.d/10-nvidia.conf
#        chroot ${target}/ apt-get install -t ${BACKPORTS_VERSION} -y "${NVIDIA_PACKAGE}" nvidia-driver-libs:i386 linux-headers-amd64
#    fi

    apt-get autoremove -y
}


function host_cleanup()
{
    notify "cleaning up: umounting all filesystems"

    umount ${target}/boot/efi
    umount -R ${target}

    if [ "${DISABLE_LUKS}" != "true" ]; then
        notify closing luks
        cryptsetup luksClose ${g_luks_root_partition}
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
                    --directory=/target \
                    -- /my_installer.sh target

    host_cleanup

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

