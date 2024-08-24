#!/bin/sh
# Configures a simple nftables firewall intended for
# rootless network namespaces/for rootless podman containers
# Usage:
# rootless-netns-fw.sh start|stop path/to/config.nft path/to/store/old_config
# start configures the firewall and stores the old configuration,
# and stop flushes it and restores the old configuration.
#
# This has to be run as root in the network namespace, ie. run with:
# $ podman unshare --rootless-netns rootless-netns-fw.sh start

set -o errexit

action="$1"
nft_file="${2:-${HOME}/.config/containers/firewall.nft}"
old_file="${3:-${XDG_RUNTIME_DIR}/rootless-netns-fw.old.nft}"

check_userns_root() {
    # If run as root in user namespace, the user id will be 0,
    # but the USER env var should still be that of the original user.
    # Hence here, this should ensure that this is run as root,
    # and in a user namespace of some non-root user.
    if [ "$(id -u)" != 0 ] || [ "${USER}" = "root" ]; then
        echo "This script should be run as root inside a user namespace,"
        echo "and inside the user's rootless network namespace."
        exit 1
    fi
}

start_fw() {
    if [ ! -r "${nft_file}" ]; then
        echo "Could not read nftables configuration at ${nft_file}"
        exit 1
    fi
    old_umask="$(umask)"
    umask 0007
    nft -an list ruleset > "${old_file}" 2>/dev/null
    umask "${old_umask}"
    nft -f "${nft_file}"
    echo "Firewall started successfully"
}

stop_fw() {
    nft flush ruleset
    echo "Firewall stopped successfully"
    nft -f "${old_file}"
    rm "${old_file}"
    echo "Restored previous nftables rules"
}


check_userns_root
case "${action}" in
    start)
        start_fw
        ;;
    stop)
        stop_fw
        ;;
    *)
        echo "Unknown action, a valid action is either start or stop"
        exit 1
        ;;
esac
