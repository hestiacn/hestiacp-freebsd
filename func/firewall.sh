#!/bin/sh

#===========================================================================#
#                                                                           #
# Hestia Control Panel - Firewall Function Library                          #
#                                                                           #
#===========================================================================#

heal_iptables_links() {
    packages="pfctl"
    for package in $packages; do
        if [ ! -e "/sbin/${package}" ]; then
            if command -v ${package}; then
                ln -s "$(command -v ${package})" /sbin/${package}
            elif [ -e "/usr/sbin/${package}" ]; then
                ln -s /usr/sbin/${package} /sbin/${package}
            fi
        fi
    done
}