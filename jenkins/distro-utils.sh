#!/bin/bash -xue

# Ripoff devstack utility functions.

# Distro Functions
# ================

# Determine OS Vendor, Release and Update
# Tested with OS/X, Ubuntu, RedHat, CentOS, Fedora
# Returns results in global variables:
# ``os_VENDOR`` - vendor name: ``Ubuntu``, ``Fedora``, etc
# ``os_RELEASE`` - major release: ``14.04`` (Ubuntu), ``20`` (Fedora)
# ``os_UPDATE`` - update: ex. the ``5`` in ``RHEL6.5``
# ``os_PACKAGE`` - package type: ``deb`` or ``rpm``
# ``os_CODENAME`` - vendor's codename for release: ``snow leopard``, ``trusty``
declare os_VENDOR os_RELEASE os_UPDATE os_PACKAGE os_CODENAME

# GetOSVersion
function GetOSVersion {
    if [[ -x $(which lsb_release 2>/dev/null) ]]; then
        os_VENDOR=$(lsb_release -i -s)
        os_RELEASE=$(lsb_release -r -s)
        os_UPDATE=""
        os_PACKAGE="rpm"
        if [[ "Debian,Ubuntu,LinuxMint" =~ $os_VENDOR ]]; then
            os_PACKAGE="deb"
        elif [[ "SUSE LINUX" =~ $os_VENDOR ]]; then
            lsb_release -d -s | grep -q openSUSE
            if [[ $? -eq 0 ]]; then
                os_VENDOR="openSUSE"
            fi
        elif [[ $os_VENDOR == "openSUSE project" ]]; then
            os_VENDOR="openSUSE"
        elif [[ $os_VENDOR =~ Red.*Hat ]]; then
            os_VENDOR="Red Hat"
        fi
        os_CODENAME=$(lsb_release -c -s)
    elif [[ -r /etc/redhat-release ]]; then
        # Red Hat Enterprise Linux Server release 5.5 (Tikanga)
        # Red Hat Enterprise Linux Server release 7.0 Beta (Maipo)
        # CentOS release 5.5 (Final)
        # CentOS Linux release 6.0 (Final)
        # Fedora release 16 (Verne)
        # XenServer release 6.2.0-70446c (xenenterprise)
        os_CODENAME=""
        for r in "Red Hat" CentOS Fedora XenServer; do
            os_VENDOR=$r
            if [[ -n "`grep \"$r\" /etc/redhat-release`" ]]; then
                ver=`sed -e 's/^.* \([0-9].*\) (\(.*\)).*$/\1\|\2/' /etc/redhat-release`
                os_CODENAME=${ver#*|}
                os_RELEASE=${ver%|*}
                os_UPDATE=${os_RELEASE##*.}
                os_RELEASE=${os_RELEASE%.*}
                break
            fi
            os_VENDOR=""
        done
        os_PACKAGE="rpm"
    fi
    export os_VENDOR os_RELEASE os_UPDATE os_PACKAGE os_CODENAME
}

# Translate the OS version values into common nomenclature
# Sets global ``DISTRO`` from the ``os_*`` values
declare DISTRO

function GetDistro {
    GetOSVersion
    if [[ "$os_VENDOR" =~ (Ubuntu) || "$os_VENDOR" =~ (Debian) ]]; then
        # 'Everyone' refers to Ubuntu / Debian releases by the code name adjective
        DISTRO=$os_CODENAME
    elif [[ "$os_VENDOR" =~ (Fedora) ]]; then
        # For Fedora, just use 'f' and the release
        DISTRO="f$os_RELEASE"
    elif [[ "$os_VENDOR" =~ (Red Hat) || \
        "$os_VENDOR" =~ (CentOS) || \
        "$os_VENDOR" =~ (OracleServer) ]]; then
        # Drop the . release as we assume it's compatible
        DISTRO="rhel${os_RELEASE::1}"
    else
        # Catch-all for now is Vendor + Release + Update
        DISTRO="$os_VENDOR-$os_RELEASE.$os_UPDATE"
    fi
    export DISTRO
}

# Determine if current distribution is a Fedora-based distribution
# (Fedora, RHEL, CentOS, etc).
# is_centos
function is_centos {
    if [[ -z "${os_VENDOR:-}" ]]; then
        GetOSVersion
    fi
    [ "$os_VENDOR" = "CentOS" ]
}

function is_ubuntu {
    if [[ -z "${os_VENDOR:-}" ]]; then
        GetOSVersion
    fi
    [ "$os_VENDOR" = "Ubuntu" ]
}

function distro_dispatch {
    if is_centos ; then
        $1
    elif is_ubuntu; then
        $2
    else
        echo "Unknown OS"
        return 1
    fi
}
