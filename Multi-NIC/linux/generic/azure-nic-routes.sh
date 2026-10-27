#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
declare -A simple_owners=()

simple_fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
simple_root() { ((EUID == 0)) || simple_fail 'Root is required for --apply.'; }
simple_usage() {
    printf 'Usage: bash %s [--apply] [--persist] [--metric NUMBER] --map NIC_CIDR=DEST1[,DEST2] ...\n' "${0##*/}"
    printf '       bash %s --rollback [--metric NUMBER] [--apply]\n' "${0##*/}"
    printf '       bash %s --reset [--apply]\n' "${0##*/}"
    printf '%s\n' \
        'Azure Linux IPv4 routes. Default: read-only preview.' \
        '  --map NIC_CIDR=DEST1,DEST2  Repeatable; unmatched selectors warn and skip.' \
        '    Use a containing subnet or /32 for an exact assigned local IPv4 address.' \
        '    The actual NIC prefix still controls gateway discovery and validation.' \
        '    Example: --map 10.0.0.0/16=10.0.0.0/8,172.20.0.0/16' \
        '  --gateway NIC_CIDR=IP      Optional subnet-gateway override; repeatable.' \
        '  --apply                    Perform reviewed route changes; root required.' \
        '  --persist                  With --apply, save native NM/Netplan routes.' \
        '  --metric NUMBER            Positive IPv4 route metric; default 42762.' \
        '  --rollback                 Remove custom routes with the selected metric.' \
        '  --reset                    Remove custom routes with any metric.' \
        '    Cleanup includes saved routes on active managed Ethernet NICs; defaults stay.' \
        '    No profile deletion/reactivation. Use a console for cleanup --apply.' \
        '    Netplan cleanup changes reserved route-only overlays; external saved' \
        '    routes require manual review. Native networkd/ifupdown are not implemented.' \
        '  --help                     Show this help.'
}

simple_os_release() (
    local release_file=${1:-/etc/os-release} ID='' ID_LIKE='' VERSION_ID=''
    [[ -f $release_file && -r $release_file ]] || simple_fail 'Cannot read OS metadata.'
    . "$release_file" || simple_fail 'Cannot load OS metadata.'
    [[ -n $ID ]] || simple_fail 'OS metadata has no ID.'
    printf '%s\n' "$ID" "$ID_LIKE" "$VERSION_ID"
)
simple_check_os() {
    local metadata family
    local -a families=() metadata_lines=()
    metadata=$(simple_os_release) || simple_fail 'Cannot determine the supported OS/version.'
    mapfile -t metadata_lines <<< "$metadata"
    printf 'OS: ID=%s VERSION_ID=%s ID_LIKE=%s\n' "${metadata_lines[0]}" "${metadata_lines[2]:-(not set)}" "${metadata_lines[1]:-(not set)}"
    case ${metadata_lines[0]} in
        debian) [[ ${metadata_lines[2]:-} == 13 ]] && return; simple_fail 'This development version targets Debian 13 only.' ;;
        ubuntu) [[ ${metadata_lines[2]:-} == 26.04 ]] && return; simple_fail 'This development version targets Ubuntu 26.04 LTS only.' ;;
    esac
    read -r -a families <<< "${metadata_lines[0]} ${metadata_lines[1]:-}"
    for family in "${families[@]}"; do
        case $family in rhel|centos|fedora|rocky|almalinux|ol) return ;; esac
    done
    simple_fail "Unsupported OS: ${metadata//$'\n'/ }. Targets Debian 13, Ubuntu 26.04 LTS and RHEL/Fedora-derived distributions."
}

simple_number() {
    local address=$1 octet number=0
    local -a octets=()
    [[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [[ ${#octet} -le 3 && ( $octet == 0 || $octet != 0* ) ]] || return 1
        ((10#$octet <= 255)) || return 1
        number=$(((number << 8) | 10#$octet))
    done
    printf '%s\n' "$number"
}
simple_cidr() {
    local address=$1 prefix number network
    prefix=${address#*/}
    [[ $address == */* && $prefix =~ ^(0|[1-9]|[12][0-9]|3[0-2])$ ]] || return 1
    number=$(simple_number "${address%/*}") || return 1
    network=$((number & ((0xffffffff << (32-prefix)) & 0xffffffff)))
    printf '%s %s %s\n' "$number" "$prefix" "$network"
}
simple_canonical() {
    local number prefix network
    read -r number prefix network < <(simple_cidr "$1") || simple_fail "Invalid CIDR: $1"
    ((prefix > 0 && number == network)) || simple_fail "Use a canonical, non-default CIDR: $1"
}
simple_contains() {
    local number prefix network target
    read -r number prefix network < <(simple_cidr "$1") || return 1
    target=$(simple_number "$2") || return 1
    (( (target & ((0xffffffff << (32-prefix)) & 0xffffffff)) == network ))
}
simple_field() {
    local previous='' token
    for token in $1; do
        if [[ $previous == "$2" ]]; then printf '%s\n' "$token"; return; fi
        previous=$token
    done
}
simple_select() {
    local selector=$1 index selected=-1
    simple_canonical "$selector"
    for index in "${!simple_addresses[@]}"; do
        if (( ${selector#*/} == 32 || ${simple_addresses[index]#*/} >= ${selector#*/} )) && simple_contains "$selector" "${simple_addresses[index]%/*}"; then
            ((selected < 0)) || simple_fail "Multiple local addresses match $selector; resolve the ambiguity."
            selected=$index
        fi
    done
    ((selected >= 0)) || return 2
    printf '%s\n' "$selected"
}
simple_inventory() {
    local output device address rest line priority from origin lookup table primary=''
    simple_devices=(); simple_addresses=()
    output=$(ip -o -4 address show scope global) || simple_fail 'Cannot read IPv4 addresses.'
    while read -r _ device _ address rest; do
        [[ -n ${device:-} ]] || continue
        device=${device%%@*}
        [[ $device =~ ^[a-zA-Z0-9_.:-]+$ ]] || simple_fail 'Unsupported interface name.'
        simple_cidr "$address" >/dev/null || simple_fail 'Invalid configured NIC prefix.'
        [[ $rest != *tentative* && $rest != *dadfailed* ]] || continue
        simple_devices+=("$device"); simple_addresses+=("$address")
        printf 'NIC %s %s\n' "$device" "$address"
    done <<< "$output"
    ((${#simple_addresses[@]})) || simple_fail 'No usable global IPv4 addresses.'
    simple_routes=$(ip -N -4 -o route show table main) || simple_fail 'Cannot read routes.'
    output=$(ip -4 -o rule show) || simple_fail 'Cannot read policy rules.'
    while read -r priority from origin lookup table rest; do
        [[ $from == from && $origin == all && $lookup == lookup && -z $rest ]] || simple_fail 'Custom policy routing requires manual review.'
        case "$priority$table" in 0:local|0:255|32766:main|32766:254|32767:default|32767:253) ;; *) simple_fail 'Custom policy routing requires manual review.' ;; esac
    done <<< "$output"
    while IFS= read -r line; do
        [[ $line == default\ * ]] || continue
        device=$(simple_field "$line" dev)
        [[ -n $device && $line != *nexthop* && ( -z $primary || $primary == "$device" ) ]] || simple_fail 'Ambiguous primary default-route interface; review guest routing.'
        primary=$device
    done <<< "$simple_routes"
    [[ -n $primary && " ${simple_devices[*]} " == *" $primary "* ]] || simple_fail 'No usable primary default-route interface.'
    printf 'PRIMARY %s (guest default-route evidence)\n' "$primary"
}
simple_gateway() {
    local index=$1 device=${simple_devices[$1]} candidate='' evidence='' record selected value line number prefix network other gateway
    local -a values=()
    for record in "${simple_overrides[@]}"; do
        [[ $record == *=* ]] || simple_fail 'Invalid gateway override.'
        selected=$(simple_select "${record%%=*}") || simple_fail 'Invalid gateway selector.'
        value=${record#*=}; simple_number "$value" >/dev/null || simple_fail 'Invalid gateway IP.'
        [[ ${simple_devices[selected]} == "$device" ]] || continue
        [[ -z $candidate ]] || simple_fail 'Duplicate gateway overrides for one NIC.'
        candidate=$value; evidence=override
    done
    if [[ -z $candidate ]]; then
        while IFS= read -r line; do
            if [[ $line == default\ * && $(simple_field "$line" dev) == "$device" ]]; then
                value=$(simple_field "$line" via); [[ -z $value ]] || values+=("$value|installed-default")
            fi
        done <<< "$simple_routes"
        value=$(simple_gateway_evidence "$device") || simple_fail 'Cannot inspect backend gateway evidence.'
        while IFS= read -r line; do [[ -z $line ]] || values+=("$line"); done <<< "$value"
        for record in "${values[@]}"; do
            value=${record%%|*}
            [[ -z $candidate || $candidate == "$value" ]] || simple_fail "Conflicting gateway evidence for $device; use --gateway."
            candidate=$value; evidence+="${record#*|},"
        done
    fi
    read -r number prefix network < <(simple_cidr "${simple_addresses[index]}") || simple_fail 'Invalid actual prefix.'
    if [[ -z $candidate ]]; then
        ((prefix >= 2 && prefix <= 29)) || simple_fail 'Azure gateway calculation requires an actual /2 through /29 prefix.'
        gateway=$((network+1))
        printf -v candidate '%d.%d.%d.%d' "$(((gateway >> 24) & 255))" "$(((gateway >> 16) & 255))" "$(((gateway >> 8) & 255))" "$((gateway & 255))"
        evidence="Azure-subnet-plus-one(${simple_addresses[index]})"
    fi
    gateway=$(simple_number "$candidate") || simple_fail 'Invalid discovered gateway.'
    simple_contains "${simple_addresses[index]}" "$candidate" || simple_fail 'Gateway is outside the actual NIC subnet.'
    for other in "${simple_addresses[@]}"; do [[ ${other%/*} != "$candidate" ]] || simple_fail 'Gateway cannot be a local address.'; done
    if ((prefix < 31)); then ((gateway != network && gateway != (network | (0xffffffff >> prefix)))) || simple_fail 'Gateway is network/broadcast.'; fi
    printf '%s|%s\n' "$candidate" "$evidence"
}
simple_nm_gateway_evidence() {
    local device=$1 value line record
    command -v nmcli >/dev/null || return 0
    value=$(nmcli --escape no -g IP4.GATEWAY device show "$device" 2>/dev/null || true)
    while IFS= read -r line; do [[ -z $line || $line == -- ]] || printf '%s|NetworkManager\n' "$line"; done <<< "$value"
    value=$(nmcli --escape no -g DHCP4.OPTION device show "$device" 2>/dev/null || true)
    while IFS= read -r line; do
        if [[ $line =~ ^routers[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            for record in ${BASH_REMATCH[1]}; do printf '%s|DHCP\n' "$record"; done
        fi
    done <<< "${value// | /$'\n'}"
}
simple_gateway_evidence() {
    local device=$1 target=${simple_owners[$1]:-} identifier file output line record gateway metric attributes
    if [[ $target != netplan:* ]]; then simple_nm_gateway_evidence "$device"; return; fi
    identifier=${target#netplan:}; file="$simple_np_work/current/run/systemd/network/10-netplan-$identifier.network"
    output=$(awk '/^\[/ { section=$0 } section == "[Network]" && /^Gateway=/ { print substr($0,9) }' "$file") || simple_fail 'Cannot inspect configured Netplan gateways.'
    while IFS= read -r line; do [[ -z $line || $line == *:* ]] || printf '%s|Netplan-config\n' "$line"; done <<< "$output"
    output=$(simple_netplan_routes "$identifier") || simple_fail 'Cannot inspect Netplan default routes.'
    while read -r record gateway metric attributes; do
        [[ $record != 0.0.0.0/0 || " $attributes " != *' table=254 '* || $gateway == 0.0.0.0 ]] || printf '%s|Netplan-config\n' "$gateway"
    done <<< "$output"
    output=$(simple_netplan ip leases "$device" 2>/dev/null || true)
    while IFS= read -r line; do
        case $line in ROUTER=*|ROUTERS=*) for record in ${line#*=}; do printf '%s|Netplan-DHCP\n' "$record"; done ;; esac
    done <<< "$output"
}
simple_link_mac() {
    local device=$1 address
    [[ $device =~ ^[a-zA-Z0-9_.:-]+$ ]] || simple_fail 'Unsupported interface name.'
    read -r address < "/sys/class/net/$device/address" || simple_fail 'Cannot read interface MAC address.'
    [[ $address =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || simple_fail 'Unsupported interface MAC address.'
    printf '%s\n' "${address,,}"
}
simple_netplan() {
    local executable
    if executable=$(command -v netplan); then "$executable" "$@"
    elif [[ -x /usr/sbin/netplan ]]; then /usr/sbin/netplan "$@"
    elif [[ -x /sbin/netplan ]]; then /sbin/netplan "$@"
    else simple_fail 'The installed Netplan CLI is required; no packages will be installed.'; fi
}
simple_netplan_executable() {
    local name=$1 directory
    for directory in /usr/libexec/netplan /usr/lib/netplan /lib/netplan; do
        if [[ -x $directory/$name ]]; then printf '%s/%s\n' "$directory" "$name"; return; fi
    done
    return 1
}
simple_netplan_generator() {
    local executable argument mapping=false
    [[ -z ${SNAP:-} && -z ${NETPLAN_PARSER_IGNORE_ERRORS:-} ]] || simple_fail 'Unsupported Netplan execution environment.'
    for argument in "$@"; do
        case $argument in --mapping|--mapping=*) mapping=true ;; esac
    done
    if ! $mapping && executable=$(simple_netplan_executable configure); then
        SYSTEMD_OFFLINE=1 "$executable" "$@"
        return
    fi
    executable=$(simple_netplan_executable generate) || simple_fail 'An installed native Netplan configure/generate executable is required; no packages will be installed.'
    SYSTEMD_OFFLINE=1 "$executable" "$@"
}
simple_netplan_mapping() {
    local device=$1 root=${2:-} output identifier backend renamed matched mac driver address
    local -a arguments=(--mapping "$1")
    [[ -z $root ]] || arguments=(--root-dir "$root" "${arguments[@]}")
    output=$(simple_netplan_generator "${arguments[@]}") || simple_fail 'Cannot uniquely map the interface through Netplan.'
    [[ $output != *$'\n'* ]] || simple_fail 'Ambiguous Netplan mapping output.'
    IFS=, read -r identifier backend renamed matched mac driver <<< "$output"
    [[ $identifier == id=* && $backend == ' backend=networkd' && $renamed == ' set_name='* && $matched == ' match_name='* && $mac == ' match_mac='* && $driver == ' match_driver='* ]] || simple_fail 'Unsupported Netplan mapping or renderer.'
    identifier=${identifier#id=}; renamed=${renamed#' set_name='}; mac=${mac#' match_mac='}
    [[ $identifier =~ ^[a-zA-Z0-9_.-]+$ && $identifier != .* ]] || simple_fail 'Unsupported Netplan definition ID.'
    [[ $renamed == '(null)' || -z $renamed || $renamed == "$device" ]] || simple_fail 'Netplan rename does not match the live interface.'
    [[ $mac =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || simple_fail 'Netplan ownership requires an exact MAC match.'
    address=$(simple_link_mac "$device") || simple_fail 'Cannot establish interface identity.'
    [[ ${mac,,} == "$address" ]] || simple_fail 'Netplan MAC does not match the live interface.'
    printf '%s\n' "$identifier"
}
simple_networkd_routes() {
    awk '
        function route() {
            if (section != "Route" || destination == "" || destination ~ /:/) return
            if (destination == "default") destination = "0.0.0.0/0"
            if (gateway == "") gateway = "0.0.0.0"
            if (metric == "") metric = "0"
            if (table == "" || table == "main") table = "254"
            printf "%s %s %s", destination, gateway, metric
            if (source != "") printf " src=%s", source
            printf " table=%s", table
            if (type != "" && type != "unicast") printf " type=%s", type
            if (scope != "" && scope != "global") printf " scope=%s", scope
            if (extra) printf " unsupported=yes"
            printf "\n"
        }
        /^[[:space:]]*([#;]|$)/ { next }
        /^\[/ {
            route()
            section = substr($0, 2, length($0) - 2)
            destination = gateway = metric = table = source = type = scope = ""
            extra = 0
            delete seen
            next
        }
        section == "Route" {
            separator = index($0, "=")
            if (!separator) { extra = 1; next }
            key = substr($0, 1, separator - 1)
            value = substr($0, separator + 1)
            if (seen[key]++) extra = 1
            if (key == "Destination") destination = value
            else if (key == "Gateway") gateway = value
            else if (key == "Metric") metric = value
            else if (key == "Table") table = value
            else if (key == "PreferredSource") source = value
            else if (key == "Type") type = value
            else if (key == "Scope") scope = value
            else extra = 1
        }
        END { route() }
    ' "$1" || simple_fail 'Cannot inspect generated networkd route records.'
}
simple_netplan_render() {
    local identifier=$1 rows=$2 entry cidr gateway metric source table remainder
    [[ $identifier =~ ^[a-zA-Z0-9_.-]+$ && $identifier != .* ]] || simple_fail 'Unsupported Netplan definition ID.'
    printf 'network:\n  version: 2\n  ethernets:\n    "%s":\n      routes:' "$identifier"
    if [[ -z $rows ]]; then printf ' []\n'; return; fi
    printf '\n'
    while IFS= read -r entry; do
        [[ -n $entry ]] || continue
        read -r cidr gateway metric source table remainder <<< "$entry"
        simple_canonical "$cidr"
        simple_number "$gateway" >/dev/null || simple_fail 'Invalid overlay gateway.'
        [[ $metric =~ ^[1-9][0-9]{0,9}$ ]] && ((10#$metric <= 4294967295)) || simple_fail 'Invalid overlay metric.'
        if [[ $source == table=254 && -z $table ]]; then source=''
        else
            [[ $source == src=* && $table == table=254 && -z $remainder ]] || simple_fail 'Unsupported overlay route attributes.'
            source=${source#src=}; simple_number "$source" >/dev/null || simple_fail 'Invalid overlay preferred source.'
        fi
        printf '        - to: %s\n          via: %s\n          metric: %s\n          table: 254\n' "$cidr" "$gateway" "$metric"
        [[ -z $source ]] || printf '          from: %s\n' "$source"
    done <<< "$rows"
}
simple_system_root() { printf '/\n'; }
simple_netplan_trust() {
    local path=$1 details owner mode
    [[ ! -L $path && -r $path ]] || simple_fail "Unreadable or symlinked Netplan configuration: $path"
    details=$(stat -c '%u %a' -- "$path") || simple_fail 'Cannot inspect Netplan file ownership.'
    read -r owner mode <<< "$details"
    [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0022) == 0 )) || simple_fail 'Netplan configuration must be root-owned and not group/world writable.'
}
simple_netplan_manifest() {
    local relative file name digest
    for relative in lib/netplan etc/netplan run/netplan; do
        [[ ! -d $simple_np_source/$relative ]] || simple_netplan_trust "$simple_np_source/$relative"
        for file in "$simple_np_source/$relative/"*.yaml; do
            [[ -e $file || -L $file ]] || continue
            name=${file##*/}
            [[ -f $file && $name =~ ^[a-zA-Z0-9_.-]+\.yaml$ ]] || simple_fail 'Unsupported Netplan source filename.'
            simple_netplan_trust "$file"
            digest=$(sha256sum -- "$file") || simple_fail 'Cannot snapshot Netplan configuration.'
            printf '%s/%s|%s\n' "$relative" "$name" "${digest%% *}"
        done
    done
}
simple_netplan_clone() {
    local destination=$1 relative file
    for relative in lib/netplan etc/netplan run/netplan; do
        mkdir -p -- "$destination/$relative" || simple_fail 'Cannot create private Netplan validation tree.'
        for file in "$simple_np_source/$relative/"*.yaml; do
            [[ -f $file ]] || continue
            cp -- "$file" "$destination/$relative/" || simple_fail 'Cannot read Netplan sources; preview needs access to their contents.'
            chmod 600 -- "$destination/$relative/${file##*/}" || simple_fail 'Cannot secure temporary Netplan sources.'
        done
    done
}
simple_netplan_refresh() {
    local current after
    current=$(simple_netplan_manifest) || simple_fail 'Cannot snapshot Netplan sources.'
    rm -rf -- "$simple_np_work/current"
    simple_netplan_clone "$simple_np_work/current"
    simple_netplan_generator --root-dir "$simple_np_work/current" || simple_fail 'Native Netplan validation failed.'
    after=$(simple_netplan_manifest) || simple_fail 'Cannot recheck Netplan sources.'
    [[ $after == "$current" ]] || simple_fail 'Netplan sources changed during validation.'
    simple_np_snapshot=$current
}
simple_netplan_prepare() {
    local tool
    [[ -z ${simple_np_work:-} ]] || return 0
    for tool in awk stat sha256sum mktemp cp chmod mkdir rm cmp mv; do command -v "$tool" >/dev/null || simple_fail "Missing installed prerequisite: $tool"; done
    simple_np_source=$(simple_system_root) || simple_fail 'Cannot locate system configuration.'
    simple_np_source=${simple_np_source%/}
    simple_np_work=$(mktemp -d "${TMPDIR:-/var/tmp}/multinic-routes.XXXXXXXX") || simple_fail 'Cannot create private validation directory.'
    simple_netplan_refresh
}
simple_networkd_settings() {
    awk '/^[[:space:]]*([#;]|$)/ { next } /^\[/ { section=$0 } section != "[Route]" { print }' "$1" || simple_fail 'Cannot inspect non-route networkd settings.'
}
simple_netplan_routes() {
    local identifier=$1 file="$simple_np_work/current/run/systemd/network/10-netplan-$1.network"
    [[ $identifier =~ ^[a-zA-Z0-9_.-]+$ && -f $file ]] || simple_fail 'Netplan definition has no supported networkd configuration.'
    simple_networkd_routes "$file"
}
simple_netplan_owned() {
    local identifier=$1 file="$simple_np_source/etc/netplan/90-multinic-$1.yaml" directory rows
    [[ $identifier =~ ^[a-zA-Z0-9_.-]+$ && $identifier != .* ]] || simple_fail 'Unsupported Netplan overlay ID.'
    [[ ! -e $simple_np_source/run/netplan/90-multinic-$identifier.yaml && ! -L $simple_np_source/run/netplan/90-multinic-$identifier.yaml && ! -e $simple_np_source/lib/netplan/90-multinic-$identifier.yaml && ! -L $simple_np_source/lib/netplan/90-multinic-$identifier.yaml ]] || simple_fail 'Reserved route overlay filename is shadowed or already used outside /etc.'
    [[ -e $file || -L $file ]] || return 0
    simple_netplan_trust "$file"
    directory="$simple_np_work/owned-$identifier"
    mkdir -p -- "$directory/etc/netplan" || simple_fail 'Cannot inspect route overlay.'
    cp -- "$file" "$directory/etc/netplan/overlay.yaml" || simple_fail 'Cannot read route overlay.'
    simple_netplan_generator --root-dir "$directory" || simple_fail 'Cannot compile route overlay.'
    [[ -f $directory/run/systemd/network/10-netplan-$identifier.network ]] || simple_fail 'Route overlay uses an unsupported definition.'
    rows=$(simple_networkd_routes "$directory/run/systemd/network/10-netplan-$identifier.network") || simple_fail 'Cannot inspect owned saved routes.'
    simple_netplan_render "$identifier" "$rows" > "$directory/expected" || simple_fail 'Unsupported owned route overlay.'
    cmp -s -- "$file" "$directory/expected" || simple_fail 'Reserved overlay contains other settings, comments or formatting; review it manually.'
    printf '%s\n' "$rows"
}
simple_netplan_saved_spec() {
    local cidr device gateway source target identifier file method address found=false
    IFS='|' read -r cidr device gateway source target <<< "$1"
    identifier=${target#netplan:}; file="$simple_np_work/current/run/systemd/network/10-netplan-$identifier.network"
    [[ -f $file ]] || simple_fail 'Missing compiled Netplan definition.'
    method=$(awk '/^\[/ { section=$0 } section == "[Network]" && /^DHCP=/ { print substr($0,6) }' "$file") || simple_fail 'Cannot inspect Netplan DHCP mode.'
    printf '%s %s %s' "$cidr" "$gateway" "$simple_metric"
    case $method in
        yes|ipv4) ;;
        ''|no|ipv6)
            while IFS= read -r address; do [[ ${address%/*} != "$source" ]] || found=true; done < <(awk '/^\[/ { section=$0 } (section == "[Network]" || section == "[Address]") && /^Address=/ { print substr($0,9) }' "$file")
            $found || simple_fail 'Selected source is not backed by a static Netplan address.'
            printf ' src=%s' "$source" ;;
        *) simple_fail 'Unsupported Netplan IPv4 method.' ;;
    esac
    printf ' table=254\n'
}
simple_netplan_saved() {
    local record=$1 cidr device gateway source target identifier spec rows owned entry count=0
    IFS='|' read -r cidr device gateway source target <<< "$record"
    identifier=${target#netplan:}
    spec=$(simple_netplan_saved_spec "$record") || simple_fail 'Cannot establish Netplan saved route format.'
    rows=$(simple_netplan_routes "$identifier") || simple_fail 'Cannot inspect merged Netplan routes.'
    owned=$(simple_netplan_owned "$identifier") || simple_fail 'Cannot inspect route overlay ownership.'
    while IFS= read -r entry; do
        [[ ${entry%% *} == "$cidr" ]] || continue
        [[ " $entry " != *' table='* || " $entry " == *' table=254 '* ]] || continue
        [[ $entry == "$spec" && $'\n'"$owned"$'\n' == *$'\n'"$entry"$'\n'* ]] || simple_fail "Saved Netplan route collision for $cidr; external routes are never adopted or overwritten."
        count=$((count+1))
    done <<< "$rows"
    ((count <= 1)) || simple_fail 'Duplicate saved Netplan routes require review.'
    if ((count)); then printf 'present\n'; else printf 'absent\n'; fi
}
simple_netplan_commit() {
    local destination=$1 candidate=$2 temporary
    if [[ -z $candidate ]]; then
        rm -- "$destination" || simple_fail 'Removing the route-only overlay failed; partial changes may remain.'
        return
    fi
    temporary=$(mktemp "${destination%/*}/.multinic-routes.XXXXXXXX") || simple_fail 'Cannot stage the route-only overlay.'
    if ! cp -- "$candidate" "$temporary" || ! chmod 600 -- "$temporary" || ! mv -T -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        simple_fail 'Saving the route-only overlay failed; partial changes may remain.'
    fi
}
simple_netplan_change() {
    local identifier=$1 rows=$2 destination="$simple_np_source/etc/netplan/90-multinic-$1.yaml" current candidate after entry compiled before_settings after_settings
    current=$(simple_netplan_manifest) || simple_fail 'Cannot recheck Netplan configuration before mutation.'
    [[ $current == "$simple_np_snapshot" ]] || simple_fail 'Netplan configuration changed since planning; rerun the preview.'
    current=$(simple_netplan_owned "$identifier") || simple_fail 'Cannot recheck overlay ownership.'
    [[ $current != "$rows" ]] || return 0
    rm -rf -- "$simple_np_work/next"
    simple_netplan_clone "$simple_np_work/next"
    candidate="$simple_np_work/next/etc/netplan/90-multinic-$identifier.yaml"
    if [[ -n $rows ]]; then
        simple_netplan_render "$identifier" "$rows" > "$candidate" || simple_fail 'Cannot render the route-only overlay.'
        chmod 600 -- "$candidate" || simple_fail 'Cannot secure the proposed route-only overlay.'
    else
        rm -- "$candidate" || simple_fail 'Cannot stage overlay removal.'
    fi
    simple_netplan_generator --root-dir "$simple_np_work/next" || simple_fail 'Proposed Netplan configuration is invalid; no changes made.'
    compiled="$simple_np_work/next/run/systemd/network/10-netplan-$identifier.network"
    [[ -f $compiled ]] || simple_fail 'Proposed configuration lost the mapped networkd definition.'
    before_settings=$(simple_networkd_settings "$simple_np_work/current/run/systemd/network/10-netplan-$identifier.network") || simple_fail 'Cannot snapshot interface settings.'
    after_settings=$(simple_networkd_settings "$compiled") || simple_fail 'Cannot validate interface settings.'
    [[ $before_settings == "$after_settings" ]] || simple_fail 'Proposed overlay changes non-route interface settings.'
    after=$(simple_networkd_routes "$compiled") || simple_fail 'Cannot verify proposed saved routes.'
    while IFS= read -r entry; do
        [[ -z $entry || $'\n'"$after"$'\n' == *$'\n'"$entry"$'\n'* ]] || simple_fail 'Native Netplan did not retain the exact proposed route attributes.'
    done <<< "$rows"
    after=$(simple_netplan_manifest) || simple_fail 'Cannot recheck Netplan configuration before commit.'
    [[ $after == "$simple_np_snapshot" ]] || simple_fail 'Netplan configuration changed during validation; no changes made.'
    [[ -d ${destination%/*} && -w ${destination%/*} ]] || simple_fail 'The existing /etc/netplan directory must be writable for --apply.'
    if [[ -n $rows ]]; then simple_netplan_commit "$destination" "$candidate" || simple_fail 'Saving the route-only overlay failed; partial changes may remain.'
    else simple_netplan_commit "$destination" '' || simple_fail 'Removing the route-only overlay failed; partial changes may remain.'; fi
    simple_netplan_refresh
    after=$(simple_netplan_owned "$identifier") || simple_fail 'Cannot verify the saved route-only overlay.'
    [[ $after == "$rows" ]] || simple_fail 'Saved route-only overlay verification failed.'
}
simple_networkd_configuration() {
    local device=$1 index reply signature resolved_index path extra state
    command -v systemctl >/dev/null || return 0
    systemctl is-active --quiet systemd-networkd || return 0
    command -v busctl >/dev/null && command -v networkctl >/dev/null || simple_fail 'Active networkd requires its installed busctl and networkctl tools.'
    read -r index < "/sys/class/net/$device/ifindex" || simple_fail 'Cannot read interface index.'
    [[ $index =~ ^[1-9][0-9]*$ ]] || simple_fail 'Invalid interface index.'
    reply=$(busctl --system --auto-start=no call org.freedesktop.network1 /org/freedesktop/network1 org.freedesktop.network1.Manager GetLinkByName s "$device") || simple_fail 'Cannot resolve the networkd interface object.'
    read -r signature resolved_index path extra <<< "$reply"
    [[ $reply != *$'\n'* && $signature == io && $resolved_index == "$index" && -z $extra && $path =~ ^\"(/org/freedesktop/network1/link/[a-zA-Z0-9_]+)\"$ ]] || simple_fail 'Invalid or changed networkd interface identity.'
    path=${BASH_REMATCH[1]}
    state=$(busctl --system --auto-start=no get-property org.freedesktop.network1 "$path" org.freedesktop.network1.Link AdministrativeState) || simple_fail 'Cannot inspect per-interface networkd ownership.'
    case $state in
        's "unmanaged"') return 0 ;;
        's "configured"') networkctl --no-pager cat "@$device" || simple_fail 'Cannot inspect the active networkd configuration.' ;;
        *) simple_fail 'Interface networkd configuration is not stable; retry after it is configured.' ;;
    esac
}
simple_prepare_backends() {
    local device uuid configuration first identifier line before after compiler
    simple_owners=()
    for device in "${simple_devices[@]}"; do
        [[ -z ${simple_owners[$device]:-} ]] || continue
        uuid=''
        if command -v nmcli >/dev/null; then uuid=$(nmcli --escape no -g GENERAL.CON-UUID device show "$device" 2>/dev/null || true); fi
        configuration=$(simple_networkd_configuration "$device") || simple_fail 'Cannot establish the active networking owner.'
        if [[ $uuid =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
            [[ -z $configuration ]] || simple_fail 'NetworkManager and networkd both claim the same interface.'
            simple_owners[$device]=$uuid
            printf 'BACKEND %s: NetworkManager; tool=nmcli\n' "$device"
        elif [[ -n $configuration ]]; then
            first=${configuration%%$'\n'*}
            [[ $first == '# /run/systemd/network/10-netplan-'*.network ]] || simple_fail 'Only native NetworkManager and Netplan/networkd ownership are implemented.'
            simple_netplan_prepare
            identifier=$(simple_netplan_mapping "$device" "$simple_np_work/current") || simple_fail 'Cannot establish authoritative Netplan ownership.'
            [[ $first == "# /run/systemd/network/10-netplan-$identifier.network" ]] || simple_fail 'Active networkd file differs from the authoritative Netplan mapping.'
            while IFS= read -r line; do [[ $line != '# /'* || $line == "$first" ]] || simple_fail 'Additional networkd configuration/drop-ins require manual review.'; done <<< "$configuration"
            printf '%s\n' "$configuration" > "$simple_np_work/active-$identifier.network"
            before=$(simple_networkd_settings "$simple_np_work/active-$identifier.network") || simple_fail 'Cannot inspect active interface settings.'
            after=$(simple_networkd_settings "$simple_np_work/current/run/systemd/network/10-netplan-$identifier.network") || simple_fail 'Cannot inspect saved interface settings.'
            [[ $before == "$after" ]] || simple_fail 'Active and saved non-route interface settings differ; manual review required.'
            simple_owners[$device]="netplan:$identifier"
            simple_netplan_owned "$identifier" >/dev/null || simple_fail 'Cannot safely inspect the reserved route overlay.'
            compiler=$(simple_netplan_executable configure || simple_netplan_executable generate || true)
            printf 'BACKEND %s: Netplan -> systemd-networkd; compiler=%s\n' "$device" "${compiler##*/}"
        else
            simple_owners[$device]=unknown
            printf 'BACKEND %s: unknown; no supported owner detected\n' "$device"
        fi
    done
}
simple_profile() {
    local target=${simple_owners[$1]:-unknown}
    if [[ $target == netplan:* ]]; then printf '%s\n' "$target"
    elif [[ $target == unknown ]]; then simple_fail 'Interface has no supported authoritative networking owner.'
    else simple_nm_profile "$1"; fi
}
simple_recheck_backends() {
    local device target uuid configuration identifier before after current line
    if [[ -n ${simple_np_work:-} ]]; then
        current=$(simple_netplan_manifest) || simple_fail 'Cannot recheck saved configuration.'
        [[ $current == "$simple_np_snapshot" ]] || simple_fail 'Netplan sources changed since planning; rerun the preview.'
    fi
    for device in "${!simple_owners[@]}"; do
        target=${simple_owners[$device]}; [[ $target != unknown ]] || continue
        uuid=''
        if command -v nmcli >/dev/null; then uuid=$(nmcli --escape no -g GENERAL.CON-UUID device show "$device" 2>/dev/null || true); fi
        configuration=$(simple_networkd_configuration "$device") || simple_fail 'Cannot recheck networking ownership.'
        if [[ $target == netplan:* ]]; then
            [[ ! $uuid =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] || simple_fail 'NetworkManager started managing a Netplan/networkd interface.'
            identifier=$(simple_netplan_mapping "$device" "$simple_np_work/current") || simple_fail 'Netplan interface identity changed.'
            [[ $target == "netplan:$identifier" && ${configuration%%$'\n'*} == "# /run/systemd/network/10-netplan-$identifier.network" ]] || simple_fail 'Active Netplan ownership changed since planning.'
            while IFS= read -r line; do [[ $line != '# /'* || $line == "# /run/systemd/network/10-netplan-$identifier.network" ]] || simple_fail 'A networkd drop-in appeared after planning.'; done <<< "$configuration"
            printf '%s\n' "$configuration" > "$simple_np_work/recheck-$identifier.network"
            before=$(simple_networkd_settings "$simple_np_work/active-$identifier.network") || simple_fail 'Cannot read planned interface settings.'
            after=$(simple_networkd_settings "$simple_np_work/recheck-$identifier.network") || simple_fail 'Cannot recheck interface settings.'
            [[ $before == "$after" ]] || simple_fail 'Active interface settings changed since planning.'
        else
            [[ $uuid == "$target" && -z $configuration ]] || simple_fail 'Active NetworkManager ownership changed since planning.'
        fi
    done
}
simple_netplan_preflight() {
    local file identifier entries routed gateway metric attributes record cidr device source target expected rows before after
    local -A proposed=()
    [[ -n ${simple_np_work:-} ]] || return 0
    for file in "$simple_np_work/current/run/systemd/network/"*.network; do
        [[ -f $file ]] || continue
        if grep -q '^\[RoutingPolicyRule\]' "$file"; then simple_fail 'Pending Netplan policy routing requires manual review.'; fi
        identifier=${file##*/10-netplan-}; identifier=${identifier%.network}
        entries=$(simple_networkd_routes "$file") || simple_fail 'Cannot inspect pending Netplan routes.'
        while read -r routed gateway metric attributes; do
            [[ -n $routed && $routed != 0.0.0.0/0 && " $attributes " == *' table=254 '* ]] || continue
            simple_cidr "$routed" >/dev/null || simple_fail 'Unsupported pending Netplan route destination.'
            for record in "${simple_plan_rows[@]}"; do
                IFS='|' read -r cidr device gateway source target <<< "$record"
                if [[ $routed == "$cidr" ]]; then
                    [[ ${simple_owners[$device]} == "netplan:$identifier" ]] || simple_fail 'A pending saved route belongs to another interface.'
                    simple_netplan_saved "${record%|*}|netplan:$identifier" >/dev/null || simple_fail 'Pending saved route conflicts with the plan.'
                elif (( ${routed#*/} > ${cidr#*/} )) && simple_contains "$cidr" "${routed%/*}"; then
                    simple_fail 'A more-specific pending Netplan route conflicts with the plan.'
                fi
            done
        done <<< "$entries"
    done
    $simple_persist || return 0
    rm -rf -- "$simple_np_work/preflight" || simple_fail 'Cannot prepare Netplan preflight.'
    simple_netplan_clone "$simple_np_work/preflight"
    for record in "${simple_plan_rows[@]}"; do
        target=${record##*|}; [[ $target == netplan:* ]] || continue
        identifier=${target#netplan:}
        if [[ -z ${proposed[$identifier]+defined} ]]; then proposed[$identifier]=$(simple_netplan_owned "$identifier") || simple_fail 'Cannot inspect the existing route-only overlay.'; fi
        expected=$(simple_netplan_saved_spec "$record") || simple_fail 'Cannot plan the exact native saved route.'
        [[ $'\n'"${proposed[$identifier]}"$'\n' == *$'\n'"$expected"$'\n'* ]] || proposed[$identifier]+="${proposed[$identifier]:+$'\n'}$expected"
        simple_netplan_render "$identifier" "${proposed[$identifier]}" > "$simple_np_work/preflight/etc/netplan/90-multinic-$identifier.yaml" || simple_fail 'Cannot stage Netplan preflight.'
    done
    simple_netplan_generator --root-dir "$simple_np_work/preflight" || simple_fail 'Native Netplan preflight failed; no changes made.'
    for record in "${simple_plan_rows[@]}"; do
        target=${record##*|}; [[ $target == netplan:* ]] || continue
        identifier=${target#netplan:}; file="$simple_np_work/preflight/run/systemd/network/10-netplan-$identifier.network"
        expected=$(simple_netplan_saved_spec "$record") || simple_fail 'Cannot validate the planned route format.'
        rows=$(simple_networkd_routes "$file") || simple_fail 'Cannot verify native Netplan preflight output.'
        [[ $'\n'"$rows"$'\n' == *$'\n'"$expected"$'\n'* ]] || simple_fail 'Native Netplan cannot retain the requested route attributes/metric.'
        before=$(simple_networkd_settings "$simple_np_work/current/run/systemd/network/10-netplan-$identifier.network") || simple_fail 'Cannot snapshot interface settings.'
        after=$(simple_networkd_settings "$file") || simple_fail 'Cannot inspect proposed interface settings.'
        [[ $before == "$after" ]] || simple_fail 'Native Netplan preflight changed non-route settings.'
    done
}
simple_saved_spec() {
    if [[ ${1##*|} == netplan:* ]]; then simple_netplan_saved_spec "$1"; else simple_nm_saved_spec "$1"; fi
}
simple_saved() {
    if [[ ${1##*|} == netplan:* ]]; then simple_netplan_saved "$1"; else simple_nm_saved "$1"; fi
}
simple_profile_routes() {
    local rows
    if [[ $1 == netplan:* ]]; then
        rows=$(simple_netplan_routes "${1#netplan:}") || simple_fail 'Cannot inspect saved Netplan routes.'
        printf '%s\n' "${rows//$'\n'/,}"
    else simple_nm_profile_routes "$1"; fi
}
simple_saved_add() {
    local record=$1 spec target=${1##*|} rows
    spec=$(simple_saved_spec "$record") || simple_fail 'Cannot establish saved route format.'
    if [[ $target == netplan:* ]]; then
        rows=$(simple_netplan_owned "${target#netplan:}") || simple_fail 'Cannot inspect the existing route-only overlay.'
        simple_netplan_change "${target#netplan:}" "${rows:+$rows$'\n'}$spec"
    else nmcli connection modify uuid "$target" +ipv4.routes "$spec" || simple_fail 'Saving failed; partial changes may remain.'; fi
}
simple_saved_remove() {
    local target=$1 entry=$2 rows current remaining='' found=false
    if [[ $target == netplan:* ]]; then
        rows=$(simple_netplan_owned "${target#netplan:}") || simple_fail 'Cannot inspect saved route ownership.'
        while IFS= read -r current; do
            [[ -n $current ]] || continue
            if [[ $current == "$entry" ]]; then found=true; else remaining+="${remaining:+$'\n'}$current"; fi
        done <<< "$rows"
        $found || simple_fail 'External saved routes must be reviewed manually; no removal performed.'
        simple_netplan_change "${target#netplan:}" "$remaining"
    else nmcli connection modify uuid "$target" -ipv4.routes "$entry" || simple_fail 'Saved route removal failed; partial changes may remain.'; fi
}
simple_nm_profile() {
    local device=$1 uuid files file_uuid filename matches=0 stored='' value
    command -v nmcli >/dev/null || simple_fail '--persist requires active NetworkManager and nmcli.'
    uuid=$(nmcli --escape no -g GENERAL.CON-UUID device show "$device") || simple_fail 'Cannot read active profile.'
    [[ $uuid =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] || simple_fail 'NIC has no unique active NetworkManager profile.'
    files=$(nmcli --terse --escape no -f UUID,FILENAME connection show) || simple_fail 'Cannot inspect profile storage.'
    while IFS=: read -r file_uuid filename; do
        [[ $file_uuid != "$uuid" ]] || { matches=$((matches+1)); stored=$filename; }
    done <<< "$files"
    [[ $matches == 1 && $stored == /etc/* ]] || simple_fail 'Persistence requires a disk-backed profile under /etc.'
    value=$(nmcli --escape no -g connection.autoconnect connection show uuid "$uuid") || simple_fail 'Cannot read autoconnect.'
    [[ $value == yes || $value == true ]] || simple_fail 'Profile must already autoconnect.'
    value=$(nmcli --escape no -g connection.permissions connection show uuid "$uuid") || simple_fail 'Cannot read profile permissions.'
    [[ -z $value || $value == -- ]] || simple_fail 'User-restricted profile cannot guarantee boot activation.'
    printf '%s\n' "$uuid"
}
simple_live() {
    local cidr device gateway source uuid line preferred
    IFS='|' read -r cidr device gateway source uuid <<< "$1"
    line=$(ip -N -4 -o route show table main exact "$cidr") || simple_fail 'Cannot inspect route.'
    if [[ -z $line ]]; then printf 'absent\n'; return; fi
    [[ $line != *$'\n'* && $line != *nexthop* && $(simple_field "$line" dev) == "$device" ]] || simple_fail "Route collision for $cidr."
    if [[ -z $(simple_field "$line" via) && $(simple_field "$line" scope) =~ ^(link|253)$ ]]; then printf 'direct\n'; return; fi
    preferred=$(simple_field "$line" src)
    [[ $(simple_field "$line" via) == "$gateway" && ( -z $preferred || $preferred == "$source" ) && $(simple_field "$line" metric) == "$simple_metric" && $(simple_field "$line" proto) =~ ^(4|static)$ ]] || simple_fail "Conflicting route for $cidr; inspect or reset first."
    printf 'present\n'
}
simple_nm_saved_spec() {
    local cidr device gateway source uuid method spec
    IFS='|' read -r cidr device gateway source uuid <<< "$1"
    method=$(nmcli --escape no -g ipv4.method connection show uuid "$uuid") || simple_fail 'Cannot read profile IPv4 method.'
    spec="$cidr $gateway $simple_metric"
    case $method in
        auto) ;;
        manual) spec+=" src=$source" ;;
        *) simple_fail 'Persistence requires an auto or manual IPv4 profile.' ;;
    esac
    printf '%s table=254\n' "$spec"
}
simple_nm_saved() {
    local cidr device gateway source uuid raw entry spec count=0
    local -a entries=() fields=()
    IFS='|' read -r cidr device gateway source uuid <<< "$1"
    spec=$(simple_nm_saved_spec "$1") || simple_fail 'Cannot establish saved route format.'
    raw=$(nmcli --escape no -g ipv4.routes connection show uuid "$uuid") || simple_fail 'Cannot read saved routes.'
    [[ $raw != -- ]] || raw=''
    IFS=, read -r -a entries <<< "${raw//$'\n'/,}"
    for entry in "${entries[@]}"; do
        read -r -a fields <<< "$entry"; ((${#fields[@]})) || continue
        simple_cidr "${fields[0]}" >/dev/null || simple_fail 'Unsupported nmcli route output.'
        [[ ${fields[0]} == "$cidr" ]] || continue
        if [[ $spec == "$cidr $gateway $simple_metric table=254" ]]; then
            [[ ${#fields[@]} == 4 && ${fields[1]} == "$gateway" && ${fields[2]} == "$simple_metric" && ${fields[3]} == table=254 ]] || simple_fail "Saved route collision for $cidr; preview --rollback --metric $simple_metric before reapplying."
        else
            [[ ${#fields[@]} == 5 && ${fields[1]} == "$gateway" && ${fields[2]} == "$simple_metric" && ( "${fields[3]} ${fields[4]}" == "src=$source table=254" || "${fields[3]} ${fields[4]}" == "table=254 src=$source" ) ]] || simple_fail "Saved route collision for $cidr."
        fi
        count=$((count+1))
    done
    ((count <= 1)) || simple_fail 'Duplicate saved routes require manual cleanup.'
    if ((count)); then printf 'present\n'; else printf 'absent\n'; fi
}
simple_plan() {
    local group selector destinations previous selected device gateway evidence uuid destination index record status line routed pair remote source lookup
    local -a selectors=() destination_list=() all_destinations=()
    simple_plan_rows=()
    for group in "${simple_maps[@]}"; do
        [[ $group == *=* ]] || simple_fail 'Map must be NIC_CIDR=DEST1,DEST2.'
        selector=${group%%=*}; destinations=${group#*=}; simple_canonical "$selector"
        [[ -n $destinations && $destinations != ,* && $destinations != *, && $destinations != *,,* ]] || simple_fail 'Empty map destination.'
        for previous in "${selectors[@]}"; do
            if simple_contains "$selector" "${previous%/*}" || simple_contains "$previous" "${selector%/*}"; then simple_fail 'Overlapping NIC selectors.'; fi
        done
        selectors+=("$selector")
        IFS=, read -r -a destination_list <<< "$destinations"
        for destination in "${destination_list[@]}"; do
            simple_canonical "$destination"
            for previous in "${all_destinations[@]}"; do
                if simple_contains "$destination" "${previous%/*}" || simple_contains "$previous" "${destination%/*}"; then simple_fail 'Overlapping destination mappings.'; fi
            done
            all_destinations+=("$destination")
        done
        if selected=$(simple_select "$selector"); then
            :
        else
            status=$?
            [[ $status == 2 ]] || simple_fail 'Cannot select NIC.'
            printf 'WARNING: No actual NIC subnet matches %s; skipping map %s.\n' "$selector" "$group" >&2
            continue
        fi
        device=${simple_devices[selected]}; evidence=$(simple_gateway "$selected") || simple_fail 'Cannot establish gateway.'
        gateway=${evidence%%|*}; evidence=${evidence#*|}; uuid=-
        if $simple_persist; then uuid=$(simple_profile "$device") || simple_fail 'Cannot establish persistent profile.'; fi
        for destination in "${destination_list[@]}"; do
            for index in "${!simple_addresses[@]}"; do
                if [[ ${simple_devices[index]} != "$device" ]] && simple_contains "$destination" "${simple_addresses[index]%/*}"; then simple_fail 'Destination contains another local NIC.'; fi
            done
            record="$destination|$device|$gateway|${simple_addresses[selected]%/*}|$uuid"
            status=$(simple_live "$record") || simple_fail 'Cannot safely plan runtime routes.'
            [[ $status != direct ]] || { printf 'DIRECT %s stays on %s; no gateway route needed.\n' "$destination" "$device"; continue; }
            if [[ $uuid != - ]]; then
                for previous in "${simple_plan_rows[@]}"; do
                    pair=${previous#*|}; pair=${pair%%|*}
                    [[ ${previous##*|} != "$uuid" || $pair == "$device" ]] || simple_fail 'One profile is shared by multiple NICs.'
                done
                status=$(simple_saved "$record") || simple_fail 'Cannot safely plan saved routes.'
            fi
            while IFS= read -r line; do
                [[ -n $line && $line != default\ * ]] || continue
                routed=${line%% *}; [[ $routed == */* ]] || routed+='/32'
                simple_cidr "$routed" >/dev/null || simple_fail 'Unsupported main-table route.'
                if (( ${routed#*/} > ${destination#*/} )) && simple_contains "$destination" "${routed%/*}"; then
                    [[ $(simple_field "$line" dev) == "$device" && -z $(simple_field "$line" via) && $(simple_field "$line" scope) =~ ^(link|253)$ ]] || simple_fail "More-specific route conflicts with $destination."
                    printf 'DIRECT %s remains more specific than %s.\n' "$routed" "$destination"
                fi
            done <<< "$simple_routes"
            if [[ -n ${SSH_CONNECTION:-} ]]; then
                read -r remote _ source _ <<< "$SSH_CONNECTION"
                if simple_number "$remote" >/dev/null && simple_number "$source" >/dev/null && simple_contains "$destination" "$remote"; then
                    lookup=$(ip -4 route get "$remote" from "$source") || simple_fail 'Cannot inspect SSH path.'
                    [[ $(simple_field "$lookup" dev) == "$device" && ( $(simple_field "$lookup" via) == "$gateway" || -z $(simple_field "$lookup" via) ) ]] || simple_fail 'Plan changes the SSH path; review from Serial Console.'
                fi
            fi
            simple_plan_rows+=("$record")
            printf 'MAP %s -> %s source=%s gateway=%s evidence=%s profile=%s metric=%s\n' "$destination" "$device" "${simple_addresses[selected]}" "$gateway" "$evidence" "$uuid" "$simple_metric"
        done
    done
}
simple_add() {
    local record cidr device gateway source uuid status
    simple_recheck_backends
    for record in "${simple_plan_rows[@]}"; do
        IFS='|' read -r cidr device gateway source uuid <<< "$record"
        if [[ $uuid != - ]]; then
            status=$(simple_saved "$record") || simple_fail 'Saved routes changed during apply.'
            if [[ $status == absent ]]; then
                simple_saved_add "$record"
            fi
            [[ $(simple_saved "$record") == present ]] || simple_fail 'Saved route verification failed.'
        fi
        status=$(simple_live "$record") || simple_fail 'Runtime routes changed during apply.'
        if [[ $status == absent ]]; then ip -4 route add "$cidr" via "$gateway" dev "$device" src "$source" proto static metric "$simple_metric" || simple_fail 'Route addition failed; partial changes may remain.'; fi
        [[ $(simple_live "$record") == present ]] || simple_fail 'Runtime route verification failed.'
    done
    [[ $(ip -N -4 -o route show table main default) == "$(printf '%s\n' "$simple_routes" | grep '^default ' || true)" ]] || simple_fail 'Default routes changed; inspect concurrent configuration.'
    printf 'Applied. Persistence=%s. No profiles were reactivated.\n' "$simple_persist"
}
simple_nm_profile_routes() {
    local raw
    raw=$(nmcli --escape no -g ipv4.routes connection show uuid "$1") || simple_fail 'Cannot inspect saved routes.'
    [[ $raw != -- ]] || raw=''
    printf '%s\n' "${raw//$'\n'/,}"
}
simple_cleanup_targets() {
    local device uuid profile_table
    local -a visited=()
    for device in "${simple_devices[@]}"; do
        [[ " ${visited[*]} " != *" $device "* ]] || continue
        visited+=("$device")
        uuid=$(simple_profile "$device") || simple_fail 'Cannot establish a persistent cleanup owner.'
        if [[ $uuid == netplan:* ]]; then printf '%s|%s|254\n' "$device" "$uuid"; continue; fi
        profile_table=$(nmcli --escape no -g ipv4.route-table connection show uuid "$uuid") || simple_fail 'Cannot inspect profile route table.'
        [[ $profile_table =~ ^[0-9]+$ ]] || simple_fail 'Unsupported profile route table.'
        [[ $profile_table != 0 ]] || profile_table=254
        printf '%s|%s|%s\n' "$device" "$uuid" "$profile_table"
    done
}
simple_cleanup() {
    local mode=$1 output device uuid previous raw entry cidr metric table profile_table attribute route_type line protocol gateway source index current
    local -a targets=() uuids=() snapshots=() saved_rows=() live_rows=() entries=() fields=() arguments=()
    simple_inventory
    simple_prepare_backends
    output=$(simple_cleanup_targets) || simple_fail 'Cannot establish cleanup configuration owners.'
    while IFS='|' read -r device uuid profile_table; do
        [[ -n $device ]] || continue
        for previous in "${uuids[@]}"; do [[ $previous != "$uuid" ]] || simple_fail 'Cleanup profile is shared by multiple devices.'; done
        targets+=("$device"); uuids+=("$uuid")
        raw=$(simple_profile_routes "$uuid") || simple_fail 'Cannot plan saved route removal.'
        snapshots+=("$raw"); entries=()
        IFS=, read -r -a entries <<< "$raw"
        for entry in "${entries[@]}"; do
            read -r entry <<< "$entry"; read -r -a fields <<< "$entry"
            ((${#fields[@]})) || continue
            cidr=${fields[0]}; simple_cidr "$cidr" >/dev/null || simple_fail 'Unsupported saved route output.'
            [[ ${cidr#*/} != 0 ]] || continue
            metric=${fields[2]:--1}; table=$profile_table; route_type=unicast
            [[ $metric =~ ^(-1|[0-9]+)$ ]] || simple_fail 'Unsupported saved route metric.'
            for attribute in "${fields[@]:3}"; do
                case $attribute in
                    table=*) [[ ${attribute#*=} == 0 ]] || table=${attribute#*=} ;;
                    type=*) route_type=${attribute#*=} ;;
                esac
            done
            [[ $table == 254 && $route_type == unicast ]] || continue
            [[ $mode != rollback || $metric == "$simple_metric" ]] || continue
            if [[ $uuid == netplan:* ]]; then
                current=$(simple_netplan_owned "${uuid#netplan:}") || simple_fail 'Cannot inspect saved route ownership.'
                [[ $'\n'"$current"$'\n' == *$'\n'"$entry"$'\n'* ]] || simple_fail 'Matching external Netplan saved routes require manual removal; cleanup has made no changes.'
            fi
            saved_rows+=("$uuid|$entry")
            printf 'REMOVE saved device=%s profile=%s route=%s\n' "$device" "$uuid" "$entry"
        done
    done <<< "$output"
    ((${#targets[@]})) || simple_fail 'No active managed Ethernet profiles to inspect.'
    while IFS= read -r line; do
        [[ -n $line && $line != default\ * && $line != 0.0.0.0/0\ * ]] || continue
        device=$(simple_field "$line" dev); protocol=$(simple_field "$line" proto)
        [[ " ${targets[*]} " == *" $device "* && -n $device && $protocol =~ ^(4|static|3|boot)$ ]] || continue
        metric=$(simple_field "$line" metric); metric=${metric:-0}
        [[ $mode != rollback || $metric == "$simple_metric" ]] || continue
        [[ $line != *nexthop* && $metric =~ ^[0-9]+$ ]] || simple_fail 'Multipath or unsupported custom route requires manual review.'
        cidr=${line%% *}; [[ $cidr == */* ]] || cidr+='/32'
        simple_cidr "$cidr" >/dev/null || simple_fail 'Unsupported custom route destination.'
        live_rows+=("$line")
        printf 'REMOVE live %s\n' "$line"
    done <<< "$simple_routes"
    if ((${#saved_rows[@]} == 0 && ${#live_rows[@]} == 0)); then printf 'No matching custom routes. No changes made.\n'; return; fi
    printf 'WARNING: Route removal can interrupt connectivity. Defaults and connected routes are retained; use a console.\n'
    $simple_apply || { printf 'DRY RUN: No changes. Add --apply to remove these routes.\n'; return; }
    [[ -z ${SSH_CONNECTION:-} ]] || simple_fail 'Route cleanup must be run from a console, not an SSH session.'
    simple_recheck_backends
    current=$(ip -N -4 -o route show table main) || simple_fail 'Cannot recheck routes before removal.'
    [[ $current == "$simple_routes" ]] || simple_fail 'Routes changed during planning; rerun the preview.'
    for index in "${!uuids[@]}"; do
        current=$(simple_profile_routes "${uuids[index]}") || simple_fail 'Cannot recheck saved routes before removal.'
        [[ $current == "${snapshots[index]}" ]] || simple_fail 'Saved routes changed during planning; rerun the preview.'
    done
    for entry in "${saved_rows[@]}"; do
        uuid=${entry%%|*}; entry=${entry#*|}
        simple_saved_remove "$uuid" "$entry"
        raw=$(simple_profile_routes "$uuid") || simple_fail 'Cannot verify saved route removal.'
        entries=(); IFS=, read -r -a entries <<< "$raw"
        for current in "${entries[@]}"; do
            read -r current <<< "$current"
            [[ $current != "$entry" ]] || simple_fail 'Saved route removal verification failed.'
        done
    done
    for line in "${live_rows[@]}"; do
        cidr=${line%% *}; device=$(simple_field "$line" dev); protocol=$(simple_field "$line" proto)
        gateway=$(simple_field "$line" via); source=$(simple_field "$line" src); metric=$(simple_field "$line" metric)
        arguments=(-4 route del "$cidr" table main proto "$protocol" dev "$device" metric "${metric:-0}")
        [[ -z $gateway ]] || arguments+=(via "$gateway")
        [[ -z $source ]] || arguments+=(src "$source")
        ip "${arguments[@]}" || simple_fail 'Live route removal failed; partial changes may remain.'
    done
    output=$(ip -N -4 -o route show table main) || simple_fail 'Cannot verify remaining routes.'
    for line in "${live_rows[@]}"; do
        [[ $'\n'"$output"$'\n' != *$'\n'"$line"$'\n'* ]] || simple_fail 'Live route removal verification failed.'
    done
    [[ $(printf '%s\n' "$output" | grep '^default ' || true) == "$(printf '%s\n' "$simple_routes" | grep '^default ' || true)" ]] || simple_fail 'Default routes changed; inspect concurrent configuration.'
    printf '%s completed. Only custom route entries were removed; no profiles were reactivated.\n' "$mode"
}
simple_main() (
    local arg operation='' metric_explicit=false record selected evidence
    local execution=preview persistence=no
    local simple_np_work='' simple_np_source='' simple_np_snapshot=''
    local -A simple_owners=()
    trap '[[ -z $simple_np_work ]] || rm -rf -- "$simple_np_work"' EXIT
    umask 077
    simple_apply=false; simple_persist=false; simple_metric=42762; simple_maps=(); simple_overrides=()
    while (($#)); do
        arg=$1; shift
        case $arg in
            --help|-h) simple_usage; return ;;
            --apply) simple_apply=true ;;
            --persist) simple_persist=true ;;
            --reset|--rollback)
                [[ -z $operation ]] || simple_fail 'Choose only one of --rollback or --reset.'
                operation=${arg#--} ;;
            --map|--gateway|--metric)
                (($#)) && [[ -n $1 && $1 != --* ]] || simple_fail "Missing argument for $arg"
                case $arg in
                    --map) simple_maps+=("$1") ;;
                    --gateway) simple_overrides+=("$1") ;;
                    --metric) simple_metric=$1; metric_explicit=true ;;
                esac
                shift ;;
            *) simple_fail "Unknown argument: $arg" ;;
        esac
    done
    [[ $simple_metric =~ ^[1-9][0-9]{0,9}$ ]] && ((10#$simple_metric <= 4294967295)) || simple_fail '--metric must be an integer from 1 through 4294967295.'
    simple_check_os
    if $simple_apply; then execution=apply; fi
    if $simple_persist; then persistence=yes; fi
    if [[ -n $operation ]]; then persistence=automatic-cleanup; fi
    printf 'MODE: %s; operation=%s; persistence=%s; runtime routes use ip\n' "$execution" "${operation:-routes}" "$persistence"
    command -v ip >/dev/null || simple_fail 'iproute2 is required.'
    if $simple_apply; then simple_root; fi
    if [[ -n $operation ]]; then
        ((${#simple_maps[@]} == 0 && ${#simple_overrides[@]} == 0)) && ! $simple_persist || simple_fail 'Cleanup is separate from maps, gateway overrides and --persist; saved routes are included automatically.'
        [[ $operation != reset ]] || ! $metric_explicit || simple_fail '--reset removes all custom metrics; use --metric with --rollback instead.'
        simple_cleanup "$operation"; return
    fi
    ((${#simple_maps[@]})) || simple_fail 'Supply at least one --map.'
    simple_inventory
    simple_prepare_backends
    for record in "${simple_overrides[@]}"; do
        [[ $record == *=* ]] || simple_fail 'Invalid gateway override.'
        selected=$(simple_select "${record%%=*}") || simple_fail 'Invalid gateway selector.'
        evidence=$(simple_gateway "$selected") || simple_fail 'Invalid gateway override.'
    done
    simple_plan
    for record in "${simple_plan_rows[@]}"; do
        selected=${record#*|}; selected=${selected%%|*}
        [[ ${simple_owners[$selected]:-unknown} != unknown ]] || simple_fail 'Mapped interface has no supported authoritative networking owner.'
    done
    simple_netplan_preflight
    if ((${#simple_plan_rows[@]} == 0)); then
        printf 'No route additions needed. No changes made.\n'
        return
    fi
    printf 'Azure connectivity, NSGs/firewalls and symmetric reply routing remain separate prerequisites.\n'
    if $simple_apply; then simple_add
    else printf 'DRY RUN: No changes. Add --apply for runtime routes; add --apply --persist to save them.\n'; fi
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then simple_main "$@"; fi