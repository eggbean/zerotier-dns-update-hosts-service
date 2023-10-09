#!/bin/bash -e
#
# Install ZeroTier Update Hosts Service Script
#
#       Installs a script and service that updates files with ZeroTier member
#       IP addresses when they change, using the ZeroTier API. Works on any
#       Linux or WSL distro that uses systemd, with or without SELinux.
#
# Can be used to:
#
#       * Update Pi-Hole custom lists file, running on local machine in docker
#       container or not. It can also update any other DNS server that uses the
#       standard BIND host file format.
#
#       * Updates the local Linux host file, leaving out the local hostname.
#
#       * On Windows WSL it does the same, as well as updates the Windows
#       hosts's host file, leaving out the Windows hostname. It also adds an
#       entry for IP address of the WSL virtual machine.
#
# Usage:
#
#       First add variables below and then...
#       $ chown +x install-zt-update-hosts-service.sh
#       $ sudo ./install-zt-update-hosts-service.sh
#
# Uninstall service & script:
#
#       $ sudo ./install-zt-update-hosts-service.sh --uninstall

# VARIABLES
# (See https://bit.ly/zerotier-update-service-readme)
apikey=''
network=''
domain=''

# Polling for changes frequency
timer_interval='10min'

# Location for installed script
script_path='/srv/zt-update-hosts'

# Uncomment for Pi-Hole custom list file or any other DNS server using BIND format
# pihole_custom_list='/home/jason/docker-pihole/etc-pihole/custom.list'

# For WSL
wsl_distroname='ubuntu.wsl' # Mustn't be the same as WSL or Windows FQDN hostname
windows_hostfile='/mnt/c/Windows/System32/drivers/etc/hosts'

# NOTE: Any of the variables above can be overridden in a ${script_path}.env
# file (make sure that it can only be read by root)

# END OF VARIABLES ============================================================

# Check if root
[[ $(id -u) -ne 0 ]] && { echo "This script must be run as root" >&2; exit 1; }

# Check if system uses systemd
if ! command -v systemctl &>/dev/null; then
  { echo "This system doesn't use systemd" >&2; exit 1; }
fi

# Check for dependencies
deps=( curl gawk jq )
unset bail
for i in "${deps[@]}"; do
  command -v "$i" >/dev/null 2>&1 || \
    { bail="$?"; echo "$i" needs to be installed >&2; }
done
if [ "$bail" ]; then exit "$bail"; fi

# Check if SELinux is being used
sestatus 2>/dev/null | head -n1 | grep -q enabled && selinux=true

# Stop service if running
if systemctl is-active --quiet zt-update-hosts.service; then
  systemctl stop zt-update-hosts.{service,timer}
fi

# Uninstall function
uninstall() {
  if systemctl is-enabled --quiet zt-update-hosts.service; then
    systemctl disable zt-update-hosts.{service,timer}
  fi
  rm -f /etc/systemd/system/zt-update-hosts.{service,timer}
  rm -f "$script_path" && echo Removed \""$script_path"\".
  rm -f "${script_path}.env" && echo Removed \""$script_path".env\".
  exit
}

if [[ $1 == --uninstall ]]; then uninstall; fi

# Source variables file if exists
if [[ -e ${script_path}.env ]]; then
  source "${script_path}.env"
fi
# Write service files =========================================================
cat << EOF >/etc/systemd/system/zt-update-hosts.service
[Unit]
Description=Update ZeroTier hosts after network established
Requires=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart="$script_path"

[Install]
WantedBy=multi-user.target
EOF

cat << EOF >/etc/systemd/system/zt-update-hosts.timer
[Unit]
Description=Update ZeroTier host entries every $timer_interval

[Timer]
OnBootSec=$timer_interval
OnUnitActiveSec=$timer_interval
Persistent=True

[Install]
WantedBy=timers.target
EOF

# Write update script =========================================================
cat << EOF >"$script_path"
#!/bin/bash -e

# Variables
apikey="$apikey"
network="$network"
domain="$domain"
pihole_custom_list="$pihole_custom_list"
linux_hostfile='/etc/hosts'
wsl_distroname="$wsl_distroname"
windows_hostfile="$windows_hostfile"
EOF

cat << 'EOF' >>"$script_path"

# Source variables file if it exists (same name as script with .env extension),
# so that they can be left out of your git repository
if [[ -e $(dirname "$0")/${0##*/}.env ]]; then
  source "$(dirname "$0")/${0##*/}.env"
fi

# Check if WSL
if grep -qi microsoft /proc/version; then
  is_wsl=true
fi

# Function to get ZeroTier members
members() {
  curl -s -H "Authorization: Bearer $apikey" \
    -H "Content-Type: application/json" \
    https://my.zerotier.com/api/network/$network/member | \
    jq -r '.[] | "\(.name)***\(.config.id)***\(.config.ipAssignments[0])"' | \
    column -t -s "***" | sort
}

# Function to make host entries
hosts() {
  curl -s -H "Authorization: Bearer $apikey" \
    -H "Content-Type: application/json" \
    https://my.zerotier.com/api/network/$network/member | \
    jq --arg domain $domain -r '.[] | "\(.config.ipAssignments[0])***\(.name).\($domain)***\(.name)***#ZeroTier"' | \
    column -t -s "***" | sort
}

# Write WSL virtual machine IP address to WSL and Windows hosts files
if [[ $is_wsl ]]; then
  if grep -wq $wsl_distroname $windows_hostfile; then
    linux_host=$(awk -v var="$wsl_distroname" 'BEGIN { p=1; prev_blank=0 } NF { p=1; prev_blank=0 } /^$/ { prev_blank=1 } $0 ~ var { if (prev_blank == 0) p=0 } p' < $linux_hostfile)
    printf "%s\n" "$linux_host" > $linux_hostfile
    windows_host=$(awk -v RS='\r\n' -v ORS='\r\n' -v var="$wsl_distroname" 'BEGIN { p=1; prev_blank=0 } NF { p=1; prev_blank=0 } /^$/ { prev_blank=1 } $0 ~ var { if (prev_blank == 0) p=0 } p' < $windows_hostfile)
    printf "%s\r\n" "$windows_host" > $windows_hostfile
  fi
  eth0_ip=$(ip addr | grep -Ew '^\s*inet.*eth0$' | awk '{print $2}' | cut -d"/" -f1)
  printf "\n%s\n%s\n" "# WSL2 $wsl_distroname host" "$eth0_ip  $wsl_distroname  #WSL" >> $linux_hostfile
  printf "\r\n%s\r\n%s\r\n" "# WSL2 $wsl_distroname host" "$eth0_ip  $wsl_distroname  #WSL" >> $windows_hostfile
fi

# Make array of ZeroTier host file entries
mapfile -t hostentries < <(hosts)

# Remove ZeroTier null entries from array
for k in "${!hostentries[@]}"; do [[ " ${hostentries[k]} " == *' null '* ]] && unset -v 'hostentries[k]'; done

# Remove any existing ZeroTier host entries from Pi-Hole custom list
if [[ $pihole_custom_list ]]; then
  if grep -wq ZeroTier "$pihole_custom_list"; then
    pihole_zthosts=$(awk 'BEGIN { p=1; prev_blank=0 } NF { p=1; prev_blank=0 } /^$/ { prev_blank=1 } /ZeroTier/ { if (prev_blank == 0) p=0 } p' < "$pihole_custom_list")
    printf "%s\n" "$pihole_zthosts" > "$pihole_custom_list"
  fi
fi

# Write ZeroTier entries to Pi-Hole custom list file
if [[ $pihole_custom_list ]]; then
  printf "\n%s\n" "# ZeroTier Network" >> "$pihole_custom_list";
  for e in "${dnsentries[@]}"; do { printf "%s\n" "$e" | column -t >> "$pihole_custom_list"; }; done
fi

# Remove any existing ZeroTier entries from Linux host file
if grep -wq ZeroTier $linux_hostfile; then
  linux_zthosts=$(awk 'BEGIN { p=1; prev_blank=0 } NF { p=1; prev_blank=0 } /^$/ { prev_blank=1 } /ZeroTier/ { if (prev_blank == 0) p=0 } p' < $linux_hostfile)
  printf "%s\n" "$linux_zthosts" > $linux_hostfile
fi

# Remove ZeroTier entry for Linux/WSL localhost hostname from array
for h in "${!hostentries[@]}"; do [[ " ${hostentries[h]} " == *" $(hostname -s) "* ]] && unset -v 'hostentries[h]'; done

# Write ZeroTier entries to Linux host file
printf "\n%s\n" "# ZeroTier Network" >> $linux_hostfile
for m in "${hostentries[@]}"; do { printf "%s\n" "$m" | column -t >> $linux_hostfile; }; done

# Remove any existing ZeroTier entries from Windows host file
if [[ $is_wsl ]] && [[ $wsl_distroname ]]; then
  if grep -wq ZeroTier $windows_hostfile; then
    windows_zthosts=$(awk -v RS='\r\n' -v ORS='\r\n' 'BEGIN { p=1; prev_blank=0 } NF { p=1; prev_blank=0 } /^$/ { prev_blank=1 } /ZeroTier/ { if (prev_blank == 0) p=0 } p' < $windows_hostfile)
    printf "%s\n" "$windows_zthosts" > $windows_hostfile
  fi
fi

# Write ZeroTier entries to Windows host file
if [[ $is_wsl ]]; then
  printf "\r\n%s\r\n" "# ZeroTier Network" >> $windows_hostfile
  # Remove ZeroTier entry for Windows host hostname from array
  for s in "${!hostentries[@]}"; do [[ " ${hostentries[s]} " == *" $(/mnt/c/Windows/System32/HOSTNAME.EXE) "* ]] && unset -v 'hostentries[k]'; done
  for t in "${hostentries[@]}"; do { printf "%s\r\n" "$t" | column -t >> $windows_hostfile; }; done
fi

members
EOF
# =============================================================================

# Restore SELinux security context for service files, if required
if [[ $selinux ]]; then
  restorecon /etc/systemd/system/zt-update-hosts.{service,timer}
fi

# Set execute bit and security context for script
chmod +x "$script_path"
if [[ $selinux ]]; then
  chcon -R -t shell_exec_t "$script_path"
fi

# Secure secrets
chown root:root "$script_path"*
chmod 700 "$script_path"
if [[ -e ${script_path}.env ]]; then
  chmod 600 "${script_path}.env"
fi

# Start service
systemctl daemon-reload
systemctl enable zt-update-hosts.{service,timer}
systemctl start zt-update-hosts.{service,timer}
systemctl status zt-update-hosts.{service,timer}
