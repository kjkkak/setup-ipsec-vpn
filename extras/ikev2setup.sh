#!/bin/bash
#
# Script to set up IKEv2 on Ubuntu, Debian, CentOS/RHEL and Amazon Linux 2
#
# The latest version of this script is available at:
# https://github.com/hwdsl2/setup-ipsec-vpn
#
# Copyright (C) 2020-2021 Lin Song <linsongui@gmail.com>
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 3.0
# Unported License: http://creativecommons.org/licenses/by-sa/3.0/
#
# Attribution required: please include my name in any derivative and let me
# know how you have improved it!

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

exiterr() { echo "Error: $1" >&2; exit 1; }
bigecho() { echo; echo "## $1"; echo; }
bigecho2() { echo; echo "## $1"; }

check_ip() {
  IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

check_dns_name() {
  FQDN_REGEX='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$FQDN_REGEX"
}

check_run_as_root() {
  if [ "$(id -u)" != 0 ]; then
    exiterr "Script must be run as root. Try 'sudo bash $0'"
  fi
}

check_os_type() {
  os_arch=$(uname -m | tr -dc 'A-Za-z0-9_-')
  if grep -qs -e "release 7" -e "release 8" /etc/redhat-release; then
    os_type=centos
    if grep -qs "Red Hat" /etc/redhat-release; then
      os_type=rhel
    fi
    if grep -qs "release 7" /etc/redhat-release; then
      os_ver=7
    elif grep -qs "release 8" /etc/redhat-release; then
      os_ver=8
    fi
  elif grep -qs "Amazon Linux release 2" /etc/system-release; then
    os_type=amzn
    os_ver=2
  else
    os_type=$(lsb_release -si 2>/dev/null)
    [ -z "$os_type" ] && [ -f /etc/os-release ] && os_type=$(. /etc/os-release && printf '%s' "$ID")
    case $os_type in
      [Uu]buntu)
        os_type=ubuntu
        ;;
      [Dd]ebian)
        os_type=debian
        ;;
      [Rr]aspbian)
        os_type=raspbian
        ;;
      *)
        exiterr "This script only supports Ubuntu, Debian, CentOS/RHEL 7/8 and Amazon Linux 2."
        exit 1
        ;;
    esac
    os_ver=$(sed 's/\..*//' /etc/debian_version | tr -dc 'A-Za-z0-9')
  fi
}

check_swan_install() {
  ipsec_ver=$(/usr/local/sbin/ipsec --version 2>/dev/null)
  swan_ver=$(printf '%s' "$ipsec_ver" | sed -e 's/Linux //' -e 's/Libreswan //' -e 's/ (netkey).*//')
  if ( ! grep -qs "hwdsl2 VPN script" /etc/sysctl.conf && ! grep -qs "hwdsl2" /opt/src/run.sh ) \
    || ! printf '%s' "$ipsec_ver" | grep -q "Libreswan" \
    || [ ! -f /etc/ppp/chap-secrets ] || [ ! -f /etc/ipsec.d/passwd ]; then
cat 1>&2 <<'EOF'
Error: Your must first set up the IPsec VPN server before setting up IKEv2.
       See: https://github.com/hwdsl2/setup-ipsec-vpn
EOF
    exit 1
  fi

  case $swan_ver in
    3.19|3.2[01235679]|3.3[12]|4.*)
      true
      ;;
    *)
cat 1>&2 <<EOF
Error: Libreswan version '$swan_ver' is not supported.
       This script requires one of these versions:
       3.19-3.23, 3.25-3.27, 3.29, 3.31-3.32 or 4.x
       To update Libreswan, see:
       https://github.com/hwdsl2/setup-ipsec-vpn#upgrade-libreswan
EOF
      exit 1
      ;;
  esac
}

check_utils_exist() {
  command -v certutil >/dev/null 2>&1 || exiterr "'certutil' not found. Abort."
  command -v pk12util >/dev/null 2>&1 || exiterr "'pk12util' not found. Abort."
}

check_container() {
  in_container=0
  if grep -qs "hwdsl2" /opt/src/run.sh; then
    in_container=1
  fi
}

show_usage() {
  if [ -n "$1" ]; then
    echo "Error: $1" >&2;
  fi
cat 1>&2 <<EOF
Usage: bash $0 [options]

Options:
  --auto                        run IKEv2 setup in auto mode using default options (for initial IKEv2 setup only)
  --addclient [client name]     add a new IKEv2 client using default options (after IKEv2 setup)
  --exportclient [client name]  export an existing IKEv2 client using default options (after IKEv2 setup)
  --listclients                 list the names of existing IKEv2 clients (after IKEv2 setup)
  --removeikev2                 remove IKEv2 and delete all certificates and keys from the IPsec database
  -h, --help                    show this help message and exit

To customize IKEv2 or client options, run this script without arguments.
EOF
  exit 1
}

check_arguments() {
  if [ "$use_defaults" = "1" ]; then
    if grep -qs "conn ikev2-cp" /etc/ipsec.conf || [ -f /etc/ipsec.d/ikev2.conf ]; then
      echo "Warning: Ignoring parameter '--auto', which is valid for initial IKEv2 setup only." >&2
      echo "         Use '-h' for usage information." >&2
      echo >&2
    fi
  fi
  if [ "$((add_client_using_defaults + export_client_using_defaults + list_clients))" -gt 1 ]; then
    show_usage "Invalid parameters. Specify only one of '--addclient', '--exportclient' or '--listclients'."
  fi
  if [ "$add_client_using_defaults" = "1" ]; then
    if ! grep -qs "conn ikev2-cp" /etc/ipsec.conf && [ ! -f /etc/ipsec.d/ikev2.conf ]; then
      exiterr "You must first set up IKEv2 before adding a new client."
    fi
    if [ -z "$client_name" ] || [ "${#client_name}" -gt "64" ] \
      || printf '%s' "$client_name" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
      || case $client_name in -*) true;; *) false;; esac; then
      exiterr "Invalid client name. Use one word only, no special characters except '-' and '_'."
    elif certutil -L -d sql:/etc/ipsec.d -n "$client_name" >/dev/null 2>&1; then
      exiterr "Invalid client name. Client '$client_name' already exists."
    fi
  fi
  if [ "$export_client_using_defaults" = "1" ]; then
    if ! grep -qs "conn ikev2-cp" /etc/ipsec.conf && [ ! -f /etc/ipsec.d/ikev2.conf ]; then
      exiterr "You must first set up IKEv2 before exporting a client configuration."
    fi
    get_server_address
    if [ -z "$client_name" ] || [ "${#client_name}" -gt "64" ] \
      || printf '%s' "$client_name" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
      || [ "$client_name" = "IKEv2 VPN CA" ] || [ "$client_name" = "$server_addr" ] \
      || case $client_name in -*) true;; *) false;; esac \
      || ! certutil -L -d sql:/etc/ipsec.d -n "$client_name" >/dev/null 2>&1; then
      exiterr "Invalid client name, or client does not exist."
    fi
  fi
  if [ "$list_clients" = "1" ]; then
    if ! grep -qs "conn ikev2-cp" /etc/ipsec.conf && [ ! -f /etc/ipsec.d/ikev2.conf ]; then
      exiterr "You must first set up IKEv2 before listing clients."
    fi
  fi
  if [ "$remove_ikev2" = "1" ]; then
    if ! grep -qs "conn ikev2-cp" /etc/ipsec.conf && [ ! -f /etc/ipsec.d/ikev2.conf ]; then
      exiterr "Cannot remove IKEv2 because it has not been set up on this server."
    fi
    if [ "$((add_client_using_defaults + export_client_using_defaults + list_clients + use_defaults))" -gt 0 ]; then
      show_usage "Invalid parameters. '--removeikev2' cannot be specified with other parameters."
    fi
  fi
}

check_ca_cert_exists() {
  if certutil -L -d sql:/etc/ipsec.d -n "IKEv2 VPN CA" >/dev/null 2>&1; then
    exiterr "Certificate 'IKEv2 VPN CA' already exists."
  fi
}

check_server_cert_exists() {
  if certutil -L -d sql:/etc/ipsec.d -n "$server_addr" >/dev/null 2>&1; then
    echo "Error: Certificate '$server_addr' already exists." >&2
    echo "Abort. No changes were made." >&2
    exit 1
  fi
}

check_client_cert_exists() {
  if certutil -L -d sql:/etc/ipsec.d -n "$client_name" >/dev/null 2>&1; then
    echo "Error: Client '$client_name' already exists." >&2
    echo "Abort. No changes were made." >&2
    exit 1
  fi
}

check_swan_ver() {
  if [ "$in_container" = "0" ]; then
    swan_ver_url="https://dl.ls20.com/v1/$os_type/$os_ver/swanverikev2?arch=$os_arch&ver=$swan_ver&auto=$use_defaults"
  else
    swan_ver_url="https://dl.ls20.com/v1/docker/$os_arch/swanverikev2?ver=$swan_ver&auto=$use_defaults"
  fi
  swan_ver_latest=$(wget -t 3 -T 15 -qO- "$swan_ver_url")
}

select_swan_update() {
  if printf '%s' "$swan_ver_latest" | grep -Eq '^([3-9]|[1-9][0-9])\.([0-9]|[1-9][0-9])$' \
    && [ "$swan_ver" != "$swan_ver_latest" ]; then
    echo "Note: A newer version of Libreswan ($swan_ver_latest) is available."
    echo "It is recommended to update Libreswan before setting up IKEv2."
    if [ "$in_container" = "0" ]; then
      echo "To update, exit this script and run:"
      update_url=vpnupgrade
      if [ "$os_type" = "centos" ] || [ "$os_type" = "rhel" ]; then
        update_url=vpnupgrade-centos
      elif [ "$os_type" = "amzn" ]; then
        update_url=vpnupgrade-amzn
      fi
      echo "  wget https://git.io/$update_url -O vpnupgrade.sh"
      echo "  sudo sh vpnupgrade.sh"
    else
      echo "To update this Docker image, see: https://git.io/updatedockervpn"
    fi
    echo
    printf "Do you want to continue anyway? [y/N] "
    read -r response
    case $response in
      [yY][eE][sS]|[yY])
        echo
        ;;
      *)
        echo "Abort. No changes were made."
        exit 1
        ;;
    esac
  fi
}

show_welcome_message() {
  clear
cat <<'EOF'
Welcome! Use this script to set up IKEv2 after setting up your own IPsec VPN server.
Alternatively, you may manually set up IKEv2. See: https://git.io/ikev2

I need to ask you a few questions before starting setup.
You can use the default options and just press enter if you are OK with them.

EOF
}

show_start_message() {
  bigecho "Starting IKEv2 setup in auto mode, using default options."
}

show_add_client_message() {
  bigecho2 "Adding a new IKEv2 client '$client_name', using default options."
}

show_export_client_message() {
  bigecho2 "Exporting existing IKEv2 client '$client_name', using default options."
}

get_export_dir() {
  export_to_home_dir=0
  if grep -qs "hwdsl2" /opt/src/run.sh; then
    export_dir="/etc/ipsec.d/"
  else
    export_dir=~/
    if [ -n "$SUDO_USER" ] && getent group "$SUDO_USER" >/dev/null 2>&1; then
      user_home_dir=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
      if [ -d "$user_home_dir" ] && [ "$user_home_dir" != "/" ]; then
        export_dir="$user_home_dir/"
        export_to_home_dir=1
      fi
    fi
  fi
}

get_server_ip() {
  echo "Trying to auto discover IP of this server..."
  public_ip=$(dig @resolver1.opendns.com -t A -4 myip.opendns.com +short)
  check_ip "$public_ip" || public_ip=$(wget -t 3 -T 15 -qO- http://ipv4.icanhazip.com)
}

get_server_address() {
  server_addr=$(grep "leftcert=" /etc/ipsec.d/ikev2.conf | cut -f2 -d=)
  [ -z "$server_addr" ] && server_addr=$(grep "leftcert=" /etc/ipsec.conf | cut -f2 -d=)
  check_ip "$server_addr" || check_dns_name "$server_addr" || exiterr "Could not get VPN server address."
}

list_existing_clients() {
  echo "Checking for existing IKEv2 client(s)..."
  certutil -L -d sql:/etc/ipsec.d | grep -v -e '^$' -e 'IKEv2 VPN CA' -e '\.' | tail -n +3 | cut -f1 -d ' '
}

enter_server_address() {
  echo "Do you want IKEv2 VPN clients to connect to this server using a DNS name,"
  printf "e.g. vpn.example.com, instead of its IP address? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      use_dns_name=1
      echo
      ;;
    *)
      use_dns_name=0
      echo
      ;;
  esac

  if [ "$use_dns_name" = "1" ]; then
    read -rp "Enter the DNS name of this VPN server: " server_addr
    until check_dns_name "$server_addr"; do
      echo "Invalid DNS name. You must enter a fully qualified domain name (FQDN)."
      read -rp "Enter the DNS name of this VPN server: " server_addr
    done
  else
    get_server_ip
    echo
    read -rp "Enter the IPv4 address of this VPN server: [$public_ip] " server_addr
    [ -z "$server_addr" ] && server_addr="$public_ip"
    until check_ip "$server_addr"; do
      echo "Invalid IP address."
      read -rp "Enter the IPv4 address of this VPN server: [$public_ip] " server_addr
      [ -z "$server_addr" ] && server_addr="$public_ip"
    done
  fi
}

enter_client_name() {
  echo
  echo "Provide a name for the IKEv2 VPN client."
  echo "Use one word only, no special characters except '-' and '_'."
  read -rp "Client name: " client_name
  while [ -z "$client_name" ] || [ "${#client_name}" -gt "64" ] \
    || printf '%s' "$client_name" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
    || case $client_name in -*) true;; *) false;; esac \
    || certutil -L -d sql:/etc/ipsec.d -n "$client_name" >/dev/null 2>&1; do
    if [ -z "$client_name" ] || [ "${#client_name}" -gt "64" ] \
      || printf '%s' "$client_name" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
      || case $client_name in -*) true;; *) false;; esac; then
      echo "Invalid client name."
    else
      echo "Invalid client name. Client '$client_name' already exists."
    fi
    read -rp "Client name: " client_name
  done
}

enter_client_name_with_defaults() {
  echo
  echo "Provide a name for the IKEv2 VPN client."
  echo "Use one word only, no special characters except '-' and '_'."
  read -rp "Client name: [vpnclient] " client_name
  [ -z "$client_name" ] && client_name=vpnclient
  while [ "${#client_name}" -gt "64" ] \
    || printf '%s' "$client_name" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
    || case $client_name in -*) true;; *) false;; esac \
    || certutil -L -d sql:/etc/ipsec.d -n "$client_name" >/dev/null 2>&1; do
      if [ "${#client_name}" -gt "64" ] \
        || printf '%s' "$client_name" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
        || case $client_name in -*) true;; *) false;; esac; then
        echo "Invalid client name."
      else
        echo "Invalid client name. Client '$client_name' already exists."
      fi
    read -rp "Client name: [vpnclient] " client_name
    [ -z "$client_name" ] && client_name=vpnclient
  done
}

enter_client_name_for_export() {
  echo
  list_existing_clients
  get_server_address
  echo
  read -rp "Enter the name of the IKEv2 client to export: " client_name
  while [ -z "$client_name" ] || [ "${#client_name}" -gt "64" ] \
    || printf '%s' "$client_name" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
    || [ "$client_name" = "IKEv2 VPN CA" ] || [ "$client_name" = "$server_addr" ] \
    || case $client_name in -*) true;; *) false;; esac \
    || ! certutil -L -d sql:/etc/ipsec.d -n "$client_name" >/dev/null 2>&1; do
    echo "Invalid client name, or client does not exist."
    read -rp "Enter the name of the IKEv2 client to export: " client_name
  done
}

enter_client_cert_validity() {
  echo
  echo "Specify the validity period (in months) for this VPN client certificate."
  read -rp "Enter a number between 1 and 120: [120] " client_validity
  [ -z "$client_validity" ] && client_validity=120
  while printf '%s' "$client_validity" | LC_ALL=C grep -q '[^0-9]\+' \
    || [ "$client_validity" -lt "1" ] || [ "$client_validity" -gt "120" ] \
    || [ "$client_validity" != "$((10#$client_validity))" ]; do
    echo "Invalid validity period."
    read -rp "Enter a number between 1 and 120: [120] " client_validity
    [ -z "$client_validity" ] && client_validity=120
  done
}

enter_custom_dns() {
  echo
  echo "By default, clients are set to use Google Public DNS when the VPN is active."
  printf "Do you want to specify custom DNS servers for IKEv2? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      use_custom_dns=1
      ;;
    *)
      use_custom_dns=0
      dns_server_1=8.8.8.8
      dns_server_2=8.8.4.4
      dns_servers="8.8.8.8 8.8.4.4"
      ;;
  esac

  if [ "$use_custom_dns" = "1" ]; then
    read -rp "Enter primary DNS server: " dns_server_1
    until check_ip "$dns_server_1"; do
      echo "Invalid DNS server."
      read -rp "Enter primary DNS server: " dns_server_1
    done

    read -rp "Enter secondary DNS server (Enter to skip): " dns_server_2
    until [ -z "$dns_server_2" ] || check_ip "$dns_server_2"; do
      echo "Invalid DNS server."
      read -rp "Enter secondary DNS server (Enter to skip): " dns_server_2
    done

    if [ -n "$dns_server_2" ]; then
      dns_servers="$dns_server_1 $dns_server_2"
    else
      dns_servers="$dns_server_1"
    fi
  else
    echo "Using Google Public DNS (8.8.8.8, 8.8.4.4)."
  fi
}

check_mobike_support() {
  mobike_support=0
  case $swan_ver in
    3.2[35679]|3.3[12]|4.*)
      mobike_support=1
      ;;
  esac

  if uname -m | grep -qi -e '^arm' -e '^aarch64'; then
    modprobe -q configs
    if [ -f /proc/config.gz ]; then
      if ! zcat /proc/config.gz | grep -q "CONFIG_XFRM_MIGRATE=y"; then
        mobike_support=0
      fi
    else
      mobike_support=0
    fi
  fi

  kernel_conf="/boot/config-$(uname -r)"
  if [ -f "$kernel_conf" ]; then
    if ! grep -qs "CONFIG_XFRM_MIGRATE=y" "$kernel_conf"; then
      mobike_support=0
    fi
  fi

  # Linux kernels on Ubuntu do not support MOBIKE
  if [ "$in_container" = "0" ]; then
    if [ "$os_type" = "ubuntu" ] || uname -v | grep -qi ubuntu; then
      mobike_support=0
    fi
  else
    if uname -v | grep -qi ubuntu; then
      mobike_support=0
    fi
  fi

  echo
  echo -n "Checking for MOBIKE support... "
  if [ "$mobike_support" = "1" ]; then
    echo "available"
  else
    echo "not available"
  fi
}

select_mobike() {
  mobike_enable=0
  if [ "$mobike_support" = "1" ]; then
    echo
    echo "The MOBIKE IKEv2 extension allows VPN clients to change network attachment points,"
    echo "e.g. switch between mobile data and Wi-Fi and keep the IPsec tunnel up on the new IP."
    echo
    printf "Do you want to enable MOBIKE support? [Y/n] "
    read -r response
    case $response in
      [yY][eE][sS]|[yY]|'')
        mobike_enable=1
        ;;
      *)
        mobike_enable=0
        ;;
    esac
  fi
}

select_p12_password() {
cat <<'EOF'

Client configuration will be exported as .p12, .sswan and .mobileconfig files,
which contain the client certificate, private key and CA certificate.
To protect these files, this script can generate a random password for you,
which will be displayed when finished.

EOF

  printf "Do you want to specify your own password instead? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      use_own_password=1
      ;;
    *)
      use_own_password=0
      ;;
  esac
}

select_menu_option() {
  echo "It looks like IKEv2 has already been set up on this server."
  echo
  echo "Select an option:"
  echo "  1) Add a new client"
  echo "  2) Export configuration for an existing client"
  echo "  3) List existing clients"
  echo "  4) Remove IKEv2"
  echo "  5) Exit"
  read -rp "Option: " selected_option
  until [[ "$selected_option" =~ ^[1-5]$ ]]; do
    printf '%s\n' "$selected_option: invalid selection."
    read -rp "Option: " selected_option
  done
}

confirm_setup_options() {
cat <<EOF

Below are the IKEv2 setup options you selected.
Please double check before continuing!

================================================

VPN server address: $server_addr
VPN client name: $client_name

EOF

  if [ "$client_validity" = "1" ]; then
    echo "Client cert valid for: 1 month"
  else
    echo "Client cert valid for: $client_validity months"
  fi

  if [ "$mobike_support" = "1" ]; then
    if [ "$mobike_enable" = "1" ]; then
      echo "MOBIKE support: Enable"
    else
      echo "MOBIKE support: Disable"
    fi
  else
    echo "MOBIKE support: Not available"
  fi

cat <<EOF
DNS server(s): $dns_servers

================================================

EOF

  printf "We are ready to set up IKEv2 now. Do you want to continue? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      echo
      ;;
    *)
      echo "Abort. No changes were made."
      exit 1
      ;;
  esac
}

create_client_cert() {
  bigecho2 "Generating client certificate..."

  sleep $((RANDOM % 3 + 1))

  certutil -z <(head -c 1024 /dev/urandom) \
    -S -c "IKEv2 VPN CA" -n "$client_name" \
    -s "O=IKEv2 VPN,CN=$client_name" \
    -k rsa -g 4096 -v "$client_validity" \
    -d sql:/etc/ipsec.d -t ",," \
    --keyUsage digitalSignature,keyEncipherment \
    --extKeyUsage serverAuth,clientAuth -8 "$client_name" >/dev/null || exit 1
}

export_p12_file() {
  bigecho "Exporting .p12 file..."

  if [ "$use_own_password" = "1" ]; then
cat <<'EOF'
Enter a *secure* password to protect the client configuration files.
When importing into an iOS or macOS device, this password cannot be empty.

EOF
  else
    p12_password=$(LC_CTYPE=C tr -dc 'A-HJ-NPR-Za-km-z2-9' < /dev/urandom | head -c 16)
    [ -z "$p12_password" ] && exiterr "Could not generate a random password for .p12 file."
  fi

  p12_file="$export_dir$client_name.p12"
  if [ "$use_own_password" = "1" ]; then
    pk12util -d sql:/etc/ipsec.d -n "$client_name" -o "$p12_file" || exit 1
  else
    pk12util -W "$p12_password" -d sql:/etc/ipsec.d -n "$client_name" -o "$p12_file" || exit 1
  fi

  if [ "$export_to_home_dir" = "1" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$p12_file"
  fi
  chmod 600 "$p12_file"
}

install_base64_uuidgen() {
  if ! command -v base64 >/dev/null 2>&1 || ! command -v uuidgen >/dev/null 2>&1; then
    bigecho "Installing required packages..."

    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ] || [ "$os_type" = "raspbian" ]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get -yqq update || exiterr "'apt-get update' failed."
      apt-get -yqq install coreutils uuid-runtime || exiterr "'apt-get install' failed."
    else
      yum -yq install coreutils util-linux || exiterr "'yum install' failed."
    fi
  fi
}

create_mobileconfig() {
  bigecho "Creating .mobileconfig for iOS and macOS..."

  [ -z "$server_addr" ] && get_server_address

  p12_base64=$(base64 -w 52 "$export_dir$client_name.p12")
  [ -z "$p12_base64" ] && exiterr "Could not encode .p12 file."

  ca_base64=$(certutil -L -d sql:/etc/ipsec.d -n "IKEv2 VPN CA" -a | grep -v CERTIFICATE)
  [ -z "$ca_base64" ] && exiterr "Could not encode IKEv2 VPN CA certificate."

  uuid1=$(uuidgen)
  [ -z "$uuid1" ] && exiterr "Could not generate UUID value."

  mc_file="$export_dir$client_name.mobileconfig"

cat > "$mc_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>IKEv2</key>
      <dict>
        <key>AuthenticationMethod</key>
        <string>Certificate</string>
        <key>ChildSecurityAssociationParameters</key>
        <dict>
          <key>DiffieHellmanGroup</key>
          <integer>14</integer>
          <key>EncryptionAlgorithm</key>
          <string>AES-256-GCM</string>
          <key>LifeTimeInMinutes</key>
          <integer>1410</integer>
        </dict>
        <key>DeadPeerDetectionRate</key>
        <string>Medium</string>
        <key>DisableRedirect</key>
        <true/>
        <key>EnableCertificateRevocationCheck</key>
        <integer>0</integer>
        <key>EnablePFS</key>
        <integer>0</integer>
        <key>IKESecurityAssociationParameters</key>
        <dict>
          <key>DiffieHellmanGroup</key>
          <integer>14</integer>
          <key>EncryptionAlgorithm</key>
          <string>AES-256</string>
          <key>IntegrityAlgorithm</key>
          <string>SHA2-256</string>
          <key>LifeTimeInMinutes</key>
          <integer>1410</integer>
        </dict>
        <key>LocalIdentifier</key>
        <string>$client_name</string>
        <key>PayloadCertificateUUID</key>
        <string>$uuid1</string>
        <key>OnDemandEnabled</key>
        <integer>0</integer>
        <key>OnDemandRules</key>
        <array>
          <dict>
          <key>Action</key>
          <string>Connect</string>
          </dict>
        </array>
        <key>RemoteAddress</key>
        <string>$server_addr</string>
        <key>RemoteIdentifier</key>
        <string>$server_addr</string>
        <key>UseConfigurationAttributeInternalIPSubnet</key>
        <integer>0</integer>
      </dict>
      <key>IPv4</key>
      <dict>
        <key>OverridePrimary</key>
        <integer>1</integer>
      </dict>
      <key>PayloadDescription</key>
      <string>Configures VPN settings</string>
      <key>PayloadDisplayName</key>
      <string>VPN</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.vpn.managed.$(uuidgen)</string>
      <key>PayloadType</key>
      <string>com.apple.vpn.managed</string>
      <key>PayloadUUID</key>
      <string>$(uuidgen)</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>Proxies</key>
      <dict>
        <key>HTTPEnable</key>
        <integer>0</integer>
        <key>HTTPSEnable</key>
        <integer>0</integer>
      </dict>
      <key>UserDefinedName</key>
      <string>$server_addr</string>
      <key>VPNType</key>
      <string>IKEv2</string>
    </dict>
    <dict>
      <key>PayloadCertificateFileName</key>
      <string>$client_name</string>
      <key>PayloadContent</key>
      <data>
$p12_base64
      </data>
      <key>PayloadDescription</key>
      <string>Adds a PKCS#12-formatted certificate</string>
      <key>PayloadDisplayName</key>
      <string>$client_name</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.security.pkcs12.$(uuidgen)</string>
      <key>PayloadType</key>
      <string>com.apple.security.pkcs12</string>
      <key>PayloadUUID</key>
      <string>$uuid1</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
    <dict>
      <key>PayloadContent</key>
      <data>
$ca_base64
      </data>
      <key>PayloadCertificateFileName</key>
      <string>ikev2vpnca</string>
      <key>PayloadDescription</key>
      <string>Adds a CA root certificate</string>
      <key>PayloadDisplayName</key>
      <string>Certificate Authority (CA)</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.security.root.$(uuidgen)</string>
      <key>PayloadType</key>
      <string>com.apple.security.root</string>
      <key>PayloadUUID</key>
      <string>$(uuidgen)</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>IKEv2 VPN configuration ($server_addr)</string>
  <key>PayloadIdentifier</key>
  <string>com.apple.vpn.managed.$(uuidgen)</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>$(uuidgen)</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
EOF

  if [ "$export_to_home_dir" = "1" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$mc_file"
  fi
  chmod 600 "$mc_file"
}

create_android_profile() {
  bigecho "Creating client profile for Android..."

  [ -z "$server_addr" ] && get_server_address

  p12_base64_oneline=$(base64 -w 52 "$export_dir$client_name.p12" | sed 's/$/\\n/' | tr -d '\n')
  [ -z "$p12_base64_oneline" ] && exiterr "Could not encode .p12 file."

  uuid2=$(uuidgen)
  [ -z "$uuid2" ] && exiterr "Could not generate UUID value."

  sswan_file="$export_dir$client_name.sswan"

cat > "$sswan_file" <<EOF
{
  "uuid": "$uuid2",
  "name": "IKEv2 VPN profile ($server_addr)",
  "type": "ikev2-cert",
  "remote": {
    "addr": "$server_addr"
  },
  "local": {
    "p12": "$p12_base64_oneline",
    "rsa-pss": "true"
  },
  "ike-proposal": "aes256-sha256-modp2048",
  "esp-proposal": "aes256gcm16"
}
EOF

  if [ "$export_to_home_dir" = "1" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$sswan_file"
  fi
  chmod 600 "$sswan_file"
}

create_ca_cert() {
  bigecho2 "Generating CA certificate..."

  certutil -z <(head -c 1024 /dev/urandom) \
    -S -x -n "IKEv2 VPN CA" \
    -s "O=IKEv2 VPN,CN=IKEv2 VPN CA" \
    -k rsa -g 4096 -v 120 \
    -d sql:/etc/ipsec.d -t "CT,," -2 >/dev/null <<ANSWERS || exit 1
y

N
ANSWERS
}

create_server_cert() {
  bigecho2 "Generating VPN server certificate..."

  sleep $((RANDOM % 3 + 1))

  if [ "$use_dns_name" = "1" ]; then
    certutil -z <(head -c 1024 /dev/urandom) \
      -S -c "IKEv2 VPN CA" -n "$server_addr" \
      -s "O=IKEv2 VPN,CN=$server_addr" \
      -k rsa -g 4096 -v 120 \
      -d sql:/etc/ipsec.d -t ",," \
      --keyUsage digitalSignature,keyEncipherment \
      --extKeyUsage serverAuth \
      --extSAN "dns:$server_addr" >/dev/null || exit 1
  else
    certutil -z <(head -c 1024 /dev/urandom) \
      -S -c "IKEv2 VPN CA" -n "$server_addr" \
      -s "O=IKEv2 VPN,CN=$server_addr" \
      -k rsa -g 4096 -v 120 \
      -d sql:/etc/ipsec.d -t ",," \
      --keyUsage digitalSignature,keyEncipherment \
      --extKeyUsage serverAuth \
      --extSAN "ip:$server_addr,dns:$server_addr" >/dev/null || exit 1
  fi
}

add_ikev2_connection() {
  bigecho "Adding a new IKEv2 connection..."

  if ! grep -qs '^include /etc/ipsec\.d/\*\.conf$' /etc/ipsec.conf; then
    echo >> /etc/ipsec.conf
    echo 'include /etc/ipsec.d/*.conf' >> /etc/ipsec.conf
  fi

cat > /etc/ipsec.d/ikev2.conf <<EOF

conn ikev2-cp
  left=%defaultroute
  leftcert=$server_addr
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  leftrsasigkey=%cert
  right=%any
  rightid=%fromcert
  rightaddresspool=192.168.43.10-192.168.43.250
  rightca=%same
  rightrsasigkey=%cert
  narrowing=yes
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
  auto=add
  ikev2=insist
  rekey=no
  pfs=no
  fragmentation=yes
  ike=aes256-sha2,aes128-sha2,aes256-sha1,aes128-sha1,aes256-sha2;modp1024,aes128-sha1;modp1024
  phase2alg=aes_gcm-null,aes128-sha1,aes256-sha1,aes128-sha2,aes256-sha2
  ikelifetime=24h
  salifetime=24h
  encapsulation=yes
EOF

  if [ "$use_dns_name" = "1" ]; then
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  leftid=@$server_addr
EOF
  else
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  leftid=$server_addr
EOF
  fi

  case $swan_ver in
    3.2[35679]|3.3[12]|4.*)
      if [ -n "$dns_server_2" ]; then
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  modecfgdns="$dns_servers"
EOF
      else
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  modecfgdns=$dns_server_1
EOF
      fi
      if [ "$mobike_enable" = "1" ]; then
        echo "  mobike=yes" >> /etc/ipsec.d/ikev2.conf
      else
        echo "  mobike=no" >> /etc/ipsec.d/ikev2.conf
      fi
      ;;
    3.19|3.2[012])
      if [ -n "$dns_server_2" ]; then
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  modecfgdns1=$dns_server_1
  modecfgdns2=$dns_server_2
EOF
      else
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  modecfgdns1=$dns_server_1
EOF
      fi
      ;;
  esac
}

apply_ubuntu1804_nss_fix() {
  if [ "$os_type" = "ubuntu" ] && [ "$os_ver" = "bustersid" ] && [ "$os_arch" = "x86_64" ]; then
    bigecho "Applying fix for NSS bug on Ubuntu 18.04..."

    nss_url1="https://mirrors.kernel.org/ubuntu/pool/main/n/nss"
    nss_url2="https://mirrors.kernel.org/ubuntu/pool/universe/n/nss"
    nss_deb1="libnss3_3.49.1-1ubuntu1.5_amd64.deb"
    nss_deb2="libnss3-dev_3.49.1-1ubuntu1.5_amd64.deb"
    nss_deb3="libnss3-tools_3.49.1-1ubuntu1.5_amd64.deb"
    if wget -t 3 -T 30 -nv -O "/tmp/$nss_deb1" "$nss_url1/$nss_deb1" \
      && wget -t 3 -T 30 -nv -O "/tmp/$nss_deb2" "$nss_url1/$nss_deb2" \
      && wget -t 3 -T 30 -nv -O "/tmp/$nss_deb3" "$nss_url2/$nss_deb3"; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get -yqq update
      apt-get -yqq install "/tmp/$nss_deb1" "/tmp/$nss_deb2" "/tmp/$nss_deb3"
    fi
    /bin/rm -f "/tmp/$nss_deb1" "/tmp/$nss_deb2" "/tmp/$nss_deb3"
  fi
}

restart_ipsec_service() {
  bigecho "Restarting IPsec service..."

  mkdir -p /run/pluto
  service ipsec restart
}

print_client_added_message() {
cat <<EOF

===============================================================

New IKEv2 VPN client "$client_name" added!

VPN server address: $server_addr
VPN client name: $client_name

EOF
}

print_client_exported_message() {
cat <<EOF

===============================================================

IKEv2 VPN client "$client_name" configuration exported!

VPN server address: $server_addr
VPN client name: $client_name

EOF
}

show_swan_update_info() {
  if printf '%s' "$swan_ver_latest" | grep -Eq '^([3-9]|[1-9][0-9])\.([0-9]|[1-9][0-9])$' \
    && [ "$swan_ver" != "$swan_ver_latest" ]; then
    echo
    echo "Note: A newer version of Libreswan ($swan_ver_latest) is available."
    if [ "$in_container" = "0" ]; then
      echo "To update to the new version, run:"
      update_url=vpnupgrade
      if [ "$os_type" = "centos" ] || [ "$os_type" = "rhel" ]; then
        update_url=vpnupgrade-centos
      elif [ "$os_type" = "amzn" ]; then
        update_url=vpnupgrade-amzn
      fi
      echo "  wget https://git.io/$update_url -O vpnupgrade.sh"
      echo "  sudo sh vpnupgrade.sh"
    else
      echo "To update this Docker image, see: https://git.io/updatedockervpn"
    fi
  fi
}

print_setup_complete_message() {
cat <<EOF

===============================================================

IKEv2 VPN setup is now complete!

VPN server address: $server_addr
VPN client name: $client_name

EOF
}

print_client_info() {
cat <<EOF
Client configuration is available at:

$export_dir$client_name.p12 (for Windows)
$export_dir$client_name.sswan (for Android)
$export_dir$client_name.mobileconfig (for iOS & macOS)
EOF

  if [ "$use_own_password" = "0" ]; then
cat <<EOF

*IMPORTANT* Password for client config files:
$p12_password
Write this down, you'll need it to import to your device!
EOF
  fi

cat <<'EOF'

Next steps: Configure IKEv2 VPN clients. See:
https://git.io/ikev2clients

To add more IKEv2 VPN clients, run this script again.

===============================================================

EOF
}

check_ipsec_conf() {
  if grep -qs "conn ikev2-cp" /etc/ipsec.conf; then
    echo "Error: IKEv2 configuration section found in /etc/ipsec.conf." >&2
    echo "       This script cannot automatically remove IKEv2 from this server." >&2
    echo "       To manually remove IKEv2, see https://git.io/ikev2" >&2
    echo "Abort. No changes were made." >&2
    exit 1
  fi
}

confirm_remove_ikev2() {
  echo
  echo "WARNING: This option will remove IKEv2 from this VPN server, but keep the IPsec/L2TP"
  echo "         and IPsec/XAuth (\"Cisco IPsec\") modes. All IKEv2 configuration including"
  echo "         certificates and keys will be permanently deleted."
  echo "         This *cannot be undone*! "
  echo
  printf "Are you sure you want to remove IKEv2? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      echo
      ;;
    *)
      echo "Abort. No changes were made."
      exit 1
      ;;
  esac
}

delete_ikev2_conf() {
  bigecho2 "Deleting /etc/ipsec.d/ikev2.conf..."
  /bin/rm -f /etc/ipsec.d/ikev2.conf
}

delete_certificates() {
  bigecho "Deleting certificates and keys from the IPsec database..."
  certutil -L -d sql:/etc/ipsec.d | grep -v -e '^$' -e 'IKEv2 VPN CA' | tail -n +3 | cut -f1 -d ' ' | while read -r line; do
    certutil -F -d sql:/etc/ipsec.d -n "$line"
    certutil -D -d sql:/etc/ipsec.d -n "$line" 2>/dev/null
  done
  certutil -F -d sql:/etc/ipsec.d -n "IKEv2 VPN CA"
  certutil -D -d sql:/etc/ipsec.d -n "IKEv2 VPN CA" 2>/dev/null
}

print_ikev2_removed_message() {
  echo "IKEv2 removed!"
}

ikev2setup() {
  check_run_as_root
  check_os_type
  check_swan_install
  check_utils_exist
  check_container

  use_defaults=0
  add_client_using_defaults=0
  export_client_using_defaults=0
  list_clients=0
  remove_ikev2=0
  while [ "$#" -gt 0 ]; do
    case $1 in
      --auto)
        use_defaults=1
        shift
        ;;
      --addclient)
        add_client_using_defaults=1
        client_name="$2"
        shift
        shift
        ;;
      --exportclient)
        export_client_using_defaults=1
        client_name="$2"
        shift
        shift
        ;;
      --listclients)
        list_clients=1
        shift
        ;;
      --removeikev2)
        remove_ikev2=1
        shift
        ;;
      -h|--help)
        show_usage
        ;;
      *)
        show_usage "Unknown parameter: $1"
        ;;
    esac
  done

  check_arguments
  get_export_dir

  if [ "$add_client_using_defaults" = "1" ]; then
    show_add_client_message
    client_validity=120
    use_own_password=0
    create_client_cert
    export_p12_file
    install_base64_uuidgen
    create_mobileconfig
    create_android_profile
    print_client_added_message
    print_client_info
    exit 0
  fi

  if [ "$export_client_using_defaults" = "1" ]; then
    show_export_client_message
    use_own_password=0
    export_p12_file
    install_base64_uuidgen
    create_mobileconfig
    create_android_profile
    print_client_exported_message
    print_client_info
    exit 0
  fi

  if [ "$list_clients" = "1" ]; then
    list_existing_clients
    exit 0
  fi

  if [ "$remove_ikev2" = "1" ]; then
    check_ipsec_conf
    confirm_remove_ikev2
    delete_ikev2_conf
    restart_ipsec_service
    delete_certificates
    print_ikev2_removed_message
    exit 0
  fi

  if grep -qs "conn ikev2-cp" /etc/ipsec.conf || [ -f /etc/ipsec.d/ikev2.conf ]; then
    select_menu_option
    case $selected_option in
      1)
        enter_client_name
        enter_client_cert_validity
        select_p12_password
        create_client_cert
        export_p12_file
        install_base64_uuidgen
        create_mobileconfig
        create_android_profile
        print_client_added_message
        print_client_info
        exit 0
        ;;
      2)
        enter_client_name_for_export
        select_p12_password
        export_p12_file
        install_base64_uuidgen
        create_mobileconfig
        create_android_profile
        print_client_exported_message
        print_client_info
        exit 0
        ;;
      3)
        echo
        list_existing_clients
        exit 0
        ;;
      4)
        check_ipsec_conf
        confirm_remove_ikev2
        delete_ikev2_conf
        restart_ipsec_service
        delete_certificates
        print_ikev2_removed_message
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
  fi

  check_ca_cert_exists
  check_swan_ver

  if [ "$use_defaults" = "0" ]; then
    select_swan_update
    show_welcome_message
    enter_server_address
    check_server_cert_exists
    enter_client_name_with_defaults
    enter_client_cert_validity
    enter_custom_dns
    check_mobike_support
    select_mobike
    select_p12_password
    confirm_setup_options
  else
    show_start_message
    use_dns_name=0
    get_server_ip
    check_ip "$public_ip" || exiterr "Cannot detect this server's public IP."
    server_addr="$public_ip"
    check_server_cert_exists
    client_name=vpnclient
    check_client_cert_exists
    client_validity=120
    use_custom_dns=0
    dns_server_1=8.8.8.8
    dns_server_2=8.8.4.4
    dns_servers="8.8.8.8 8.8.4.4"
    check_mobike_support
    mobike_enable="$mobike_support"
    use_own_password=0
  fi

  apply_ubuntu1804_nss_fix
  create_ca_cert
  create_server_cert
  create_client_cert
  export_p12_file
  install_base64_uuidgen
  create_mobileconfig
  create_android_profile
  add_ikev2_connection
  restart_ipsec_service

  if [ "$use_defaults" = "1" ]; then
    show_swan_update_info
  fi

  print_setup_complete_message
  print_client_info
}

## Defer setup until we have the complete script
ikev2setup "$@"

exit 0
