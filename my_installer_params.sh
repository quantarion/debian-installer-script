# edit this:
readonly DISK=/dev/sdb
readonly USER_FULL_NAME="User User"
readonly USERNAME=user
readonly USER_PASSWORD=user2

readonly LOCALE=C.UTF-8
readonly KEYMAP=us
readonly TIMEZONE=UTC

readonly DEBIAN_VERSION=trixie
readonly HOSTNAME=trixie
readonly BACKPORTS_VERSION=${DEBIAN_VERSION}  # TODO append "-backports" when available

# Only if you must, sudo is prefered
#readonly ROOT_PASSWORD=root2

readonly USE_LUKS=true
readonly LUKS_PASSWORD=luks2
readonly USE_TPM_TO_UNLOCK_LUKS=true

#readonly ENABLE_POPCON=false

#readonly NVIDIA_PACKAGE=
#readonly SSH_PUBLIC_KEY=
#readonly AFTER_INSTALLED_CMD=

readonly TARGET=/target