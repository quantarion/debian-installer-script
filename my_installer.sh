#!/bin/bash

# This script will surely destroy all your data.
# this script will maybe install debian on your computer
# do not run it if there is any storage device with important data present.
# script will enroll decryption key in EUFI TPM2
# script will modify EUFI EFI variables
# only use to install debian on the copmputer on which the script is executed

# -e: exit on error
# -u: exit on undefined variables
# -o pipefail: exit if any command in a pipeline fails

set -euo pipefail

g_kernel_params="rw quiet splash"
g_fstab_content=""
# g_tpm_available
# g_swap_size
g_luks_root_partition=

function get_parameters()
{
    echo "Original arguments: $@"

    echo "Without first argument: ${@:2}"

    eval "${@:2}"

    if [ -f my_installer_params.sh ]; then
        source my_installer_params.sh
    fi

    readonly p_disk=$DISK
    readonly p_target=$TARGET

    readonly p_user_full_name=$USER_FULL_NAME
    readonly p_username=$USERNAME
    readonly p_user_password=$USER_PASSWORD

    readonly p_locale=$LOCALE
    readonly p_keymap=$KEYMAP
    readonly p_timezone=$TIMEZONE

    readonly p_debian_version=$DEBIAN_VERSION
    readonly p_hostname=$HOSTNAME
    readonly p_backports_version=$BACKPORTS_VERSION

    #readonly p_root_password=$ROOT_PASSWORD

    readonly p_use_luks=$USE_LUKS
    readonly p_luks_password=$LUKS_PASSWORD
    readonly p_use_tpm_to_unlock_luks=$USE_TPM_TO_UNLOCK_LUKS

    readonly p_btrfs_fsflags=$BTRFS_FSFLAGS
    readonly p_btrfs_admin_mount=$BTRFS_ADMIN_MOUNT

    #readonly p_enable_popcon=$ENABLE_POPCON

    #readonly p_nvidia_package=$NVIDIA_PACKAGE
    #readonly p_ssh_public_key=$SSH_PUBLIC_KEY
    #readonly p_after_installed_cmd=$AFTER_INSTALLED_CMD
}

function notify ()
{
    echo -e "\033[32m$*\033[0m"
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
    wipefs -a "${installation_disk}"

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
    local efi_system_partition_uuid; efi_system_partition_uuid=$(uuidgen)
    local efi_system_partition_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

    notify "creating system partition with uuid ${efi_system_partition_uuid} on ${installation_disk}"
    sgdisk  --new=1:2048:+1G --typecode=1:${efi_system_partition_type} \
            --change-name=1:"EFI system partition" \
            --partition-guid=1:"${efi_system_partition_uuid}" "${installation_disk}"

    # sync & reread partition tables
    partprobe
    udevadm settle

    notify "formatting ${efi_system_partition_uuid}"
    local efi_system_partition=/dev/disk/by-partuuid/${efi_system_partition_uuid}
    ls "${efi_system_partition}"
    mkfs.vfat "${efi_system_partition}"

    g_fstab_content+="PARTUUID=${efi_system_partition_uuid} /boot/efi vfat defaults,umask=077 0 2"
    g_fstab_content+=$'\n'

    # return efi_system_partition_uuid
    g_efi_system_partition_uuid=${efi_system_partition_uuid}
}

function mount_system_partition()
{
    efi_system_partition_uuid=$1
    local efi_system_partition=/dev/disk/by-partuuid/${efi_system_partition_uuid}
    notify "mounting system partition ${efi_system_partition} on ${p_target}/boot/efi"
    mkdir -p "${p_target}"/boot/efi
    mount "${efi_system_partition}" "${p_target}"/boot/efi -o umask=077
}

function setup_root_partition()
{

    local installation_disk=$1

    local root_partition_uuid; root_partition_uuid=$(uuidgen)

    local root_partition_type="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"

    notify "creating root partition with uuid ${root_partition_uuid} on ${installation_disk}"

    sgdisk --new=2:0:0 \
           --typecode=2:${root_partition_type} \
           --change-name=2:"Root partition" \
           --partition-guid=2:"${root_partition_uuid}" \
           "$installation_disk"

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
    #echo -n "${p_luks_password}" | cryptsetup luksFormat ${root_partition} --type luks2 --key-file=-
    printf '%s' "$p_luks_password" | cryptsetup luksFormat "$root_partition" --type luks2 --batch-mode --key-file -

    notify "open luks on root"
    printf '%s' "$p_luks_password" | cryptsetup luksOpen "$root_partition" root --key-file -

    # return luks_root_partition
    g_luks_root_device=/dev/mapper/root
    g_luks_root_partition=${root_partition}
    g_root_partition=${g_luks_root_device}
}


function setup_btrfs()
{
    local btrfs_root_partition=$1

    local btrfs_uuid; btrfs_uuid=$(uuidgen)
    notify "create root filesystem on ${btrfs_root_partition}"
    mkfs.btrfs -U "${btrfs_uuid}" "${btrfs_root_partition}"

    notify "mount btrfs admin subvolume on ${p_btrfs_admin_mount}"
    mkdir -p "${p_btrfs_admin_mount}"
    mount "${btrfs_root_partition}" "${p_btrfs_admin_mount}" -o rw,"${p_btrfs_fsflags}",subvolid=5,skip_balance

    notify "create @ subvolume on ${p_btrfs_admin_mount}"
    btrfs subvolume create "${p_btrfs_admin_mount}"/@

    notify "create @home subvolume on ${p_btrfs_admin_mount}"
    btrfs subvolume create "${p_btrfs_admin_mount}"/@home

    notify "create @swap subvolume for swap file on ${p_btrfs_admin_mount}"
    btrfs subvolume create "${p_btrfs_admin_mount}"/@swap
    chmod 700 "${p_btrfs_admin_mount}"/@swap

    notify "mount root and home subvolume on ${p_target}"
    mkdir -p "${p_target}"
    mount "${btrfs_root_partition}" "${p_target}" -o "${p_btrfs_fsflags}",subvol=@
    mkdir -p "${p_target}"/home
    mount "${btrfs_root_partition}" "${p_target}"/home -o "${p_btrfs_fsflags}",subvol=@home

    notify "mount swap subvolume on ${p_target}"
    mkdir -p "${p_target}"/swap
    mount "${btrfs_root_partition}" "${p_target}"/swap -o noatime,subvol=@swap

    notify "make swap file at ${p_target}/swap/swapfile"
    btrfs filesystem mkswapfile --size ${g_swap_size}G "${p_target}"/swap/swapfile

    # this would let host kernel use the swap file on the ${p_target}, we don't want that
    # swapon ${p_target}/swap/swapfile

    notify "cleanup administrative mount"
    umount "${p_btrfs_admin_mount}"
    rmdir "${p_btrfs_admin_mount}"

    swapfile_offset=$(btrfs inspect-internal map-swapfile -r "${p_target}"/swap/swapfile)

    g_kernel_params="${g_kernel_params} rootfstype=btrfs rootflags=${p_btrfs_fsflags},subvol=@ resume=${btrfs_root_partition} resume_offset=${swapfile_offset}"

    # this should go with dracut, but not a biggie
    g_kernel_params="${g_kernel_params} rd.auto=1"

    g_fstab_content+="UUID=${btrfs_uuid} / btrfs defaults,subvol=@,${p_btrfs_fsflags} 0 1"
    g_fstab_content+=$'\n'
    g_fstab_content+="UUID=${btrfs_uuid} /home btrfs defaults,subvol=@home,${p_btrfs_fsflags} 0 1"
    g_fstab_content+=$'\n'
    g_fstab_content+="UUID=${btrfs_uuid} /swap btrfs defaults,subvol=@swap,noatime,${p_btrfs_fsflags} 0 0"
    g_fstab_content+=$'\n'
    g_fstab_content+="/swap/swapfile none swap defaults 0 0"
    g_fstab_content+=$'\n'

    # return btrfs_uuid
    # g_btrfs_uuid=${btrfs_uuid}
}


function do_debootstrap()
{
    notify "install debian on ${p_target}"
    debootstrap --include=locales "${p_debian_version}" "${p_target}" http://deb.debian.org/debian
}

setup_fstab()
{
    notify "writing fstab"
    echo -e "${g_fstab_content}"
    echo "${g_fstab_content}" > "${p_target}"/etc/fstab
}

get_sources_list()
{
    # per https://wiki.debian.org/SourcesList
    echo "Types: deb"
    echo "URIs: http://deb.debian.org/debian/"
    echo "Suites: ${p_debian_version} ${p_debian_version}-updates ${p_debian_version}-backports"
    echo "Components: main contrib non-free non-free-firmware"
    echo "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
    echo
    echo "Types: deb"
    echo "URIs: http://security.debian.org/debian-security/"
    echo "Suites: ${p_debian_version}-security"
    echo "Components: main contrib non-free non-free-firmware"
    echo "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
}

function setup_sources_list()
{
    notify "setup sources list"
    rm -f "${p_target}"/etc/apt/sources.list
    get_sources_list > "${p_target}"/etc/apt/sources.list.d/debian.sources
}

function setup_firstboot()
{
    notify "setup locale, keymap, timezone, hostname, root password, kernel command line"

    systemd-firstboot --locale="${p_locale}" \
                      --keymap="${p_keymap}" \
                      --timezone="${p_timezone}" \
                      --hostname="${p_hostname}" \
                      --kernel-command-line="${g_kernel_params}" \
                      --root="${p_target}" \
                      --force

    # damn thing will not generate locales, nor set hosts
    echo "127.0.1.1   $p_hostname" >> "${p_target}"/etc/hosts
    # don't like sed option
    sed -i "s/# $p_locale/$p_locale/" "${p_target}"/etc/locale.gen
}

function target_code()
{
    export DEBIAN_FRONTEND=noninteractive

    notify "generating locales"
    locale-gen

    notify "set up user ${p_username} user"
    adduser --disabled-password --gecos "${p_user_full_name}" "${p_username}"
    adduser "${p_username}" sudo
    echo "${p_username}":"${p_user_password}" | chpasswd

    notify "install standard packages"
    apt update -y
    apt install -y dctrl-tools
    standard_packages=$(echo "$(grep-dctrl -n -s Package -F Priority standard /var/lib/apt/lists/*_Packages)" | xargs)
 
    echo apt install -y "$standard_packages"

    notify "install kernel and related packages"
    apt-cache policy linux-image-amd64
    apt-mark showhold

    apt install -y -t "${p_backports_version}" linux-image-amd64 firmware-linux plymouth-theme-hamara dracut
    apt full-upgrade -t "${p_debian_version}"-security -y

    notify "install systemd packages"
    apt install -y -t "${p_backports_version}" systemd systemd-boot systemd-cryptsetup cryptsetup

    notify "install more packages"
    apt install -y tasksel network-manager sudo
    apt install -y -t "${p_backports_version}" btrfs-progs btrfsmaintenance

    bootctl install

    notify "configuring dracut"
    echo 'add_dracutmodules+=" systemd btrfs "' > /etc/dracut.conf.d/89-btrfs.conf
    # not needed, firstboot sets kernel params and takes precedence
    # echo "kernel_cmdline=\"${g_kernel_params}\"" >> /etc/dracut.conf.d/89-btrfs.conf
    if [ "${p_use_luks}" = "true" ]; then
        echo 'add_dracutmodules+=" crypt "' > /etc/dracut.conf.d/90-luks.conf

        if [ "${p_use_tpm_to_unlock_luks}" = "true" ]; then
            apt install -y tpm2-tools

            check_tpm

            if [ "${g_tpm_available}" = "true" ]; then

                notify "creating luks key for tpm enrollment"

                # Create a secure temporary file
                tmp_key_file=$(mktemp /tmp/safe.XXXXXX)

                # Set restrictive permissions (optional, but recommended for sensitive data)
                chmod 600 "$tmp_key_file"

                # Write random data to the temporary file
                dd if=/dev/random of="$tmp_key_file" bs=512 count=1 status=none

                notify "adding tpm key to luks"

                printf '%s' "$p_luks_password" | cryptsetup luksAddKey --batch-mode --key-file - "$LUKS_ROOT_PARTITION" "${tmp_key_file}"

                notify "enrolling luks key in tpm"

                systemd-cryptenroll --unlock-key-file="${tmp_key_file}" --tpm2-device=auto "${LUKS_ROOT_PARTITION}" --tpm2-pcrs="7+14"

                # If we reach here, all operations succeeded; securely delete the file
                shred -u "$tmp_key_file"

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

#    if [ ! -z "${p_nvidia_package}" ]; then
#      # TODO the debian page says to do this instead:
#      # echo "options nvidia-drm modeset=1" >> /etc/modprobe.d/nvidia-options.conf
#      # g_kernel_params="${g_kernel_params} nvidia-drm.modeset=1"
#    fi

#    if [ "$p_enable_popcon" = true ] ; then
#        notify enabling popularity-contest
#        echo "popularity-contest      popularity-contest/participate  boolean true" | debconf-set-selections
#        apt install -y popularity-contest
#    fi

#    if [ ! -z "${p_ssh_public_key}" ]; then
#        notify adding ssh public key to user and root authorized_keys file
#        mkdir -p /root/.ssh
#        chmod 700 /root/.ssh
#        echo "${p_ssh_public_key}" > /root/.ssh/authorized_keys
#        chmod 600 /root/.ssh/authorized_keys
#
#        if [ ! -z "${p_username}" ]; then
#            mkdir -p /home/${p_username}/.ssh
#            chmod 700 /home/${p_username}/.ssh
#            echo "${p_ssh_public_key}" > ${p_target}/home/${p_username}/.ssh/authorized_keys
#            chmod 600 /home/${p_username}/.ssh/authorized_keys
#            chown -R ${p_username} /home/${p_username}/.ssh
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

#    if [ ! -z "${p_nvidia_package}" ]; then
#        notify installing ${p_nvidia_package}
#        # XXX dracut-install: ERROR: installing nvidia-blacklists-nouveau.conf nvidia.conf
#        echo 'install_items+=" /etc/modprobe.d/nvidia-blacklists-nouveau.conf /etc/modprobe.d/nvidia.conf /etc/modprobe.d/nvidia-options.conf "' > ${p_target}/etc/dracut.conf.d/10-nvidia.conf
#        chroot ${p_target}/ apt install -t ${p_backports_version} -y "${p_nvidia_package}" nvidia-driver-libs:i386 linux-headers-amd64
#    fi
    notify "done"
}


function host_cleanup()
{
    notify "cleaning up: umounting all filesystems"

    umount "${p_target}"/boot/efi
    umount -R "${p_target}"

    if [ "${p_use_luks}" = "true" ]; then
        notify closing luks
        cryptsetup luksClose "${g_luks_root_device}"
    fi
}




function host_code
{
    setup_host
    prepare_installation_disk "${p_disk}"
    setup_system_partition "${p_disk}"
    setup_root_partition "${p_disk}"
    setup_luks "${g_root_partition_uuid}"
    setup_btrfs ${g_root_partition}
    mount_system_partition "${g_efi_system_partition_uuid}"

    do_debootstrap
    setup_fstab
    setup_sources_list

    setup_firstboot

    params_for_target=$(set | grep '^p_.*=')

    systemd-nspawn  --bind=my_installer.sh:/my_installer.sh \
                    --bind="${p_disk}" \
                    --bind=/sys/firmware/efi/efivars:/sys/firmware/efi/efivars \
                    --bind=/dev/tpm0 \
                    --bind=/dev/tpmrm0 \
                    --bind=/sys/class/tpm \
                    --bind="$(realpath "${g_luks_root_partition}")" \
                    --setenv=LUKS_ROOT_PARTITION="$(realpath "${g_luks_root_partition}")" \
                    --directory="${p_target}"\
                    -- /my_installer.sh target "$params_for_target"

    systemd-nspawn  --bind=my_installer.sh:/my_installer.sh \
                    --bind=/dev/tpm0 \
                    --bind=/dev/tpmrm0 \
                    --bind=/sys/class/tpm \
                    --bind="$(realpath "${g_luks_root_partition}")"  \
                    --setenv=LUKS_ROOT_PARTITION="$(realpath "${g_luks_root_partition}")" \
                    --machine="${p_hostname}" \
                    --bind="${p_disk}" \
                    --bind=/sys/firmware/efi/efivars:/sys/firmware/efi/efivars \
                    --directory="${p_target}"


    notify "INSTALLATION FINISHED"
}



notify "Starting"

if [ $# -lt 1 ]; then
    echo "Error: Code side argument required. Use host or target"
    exit 1
fi

if [[ "$1" != "host" && "$1" != "target" ]]; then
    echo "Error: First argument must be 'host' or 'target', got '$1'"
    exit 1
fi

if [ "$1" = "host" ]; then
    get_parameters "$@"
    host_code
fi

# has to be "target" not just different than "host"
if [ "$1" = "target" ]; then

    echo "${@:2}"
    
    eval "${@:2}"
    target_code
fi

