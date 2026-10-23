#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

usage() {
    printf '%s\n' \
        'Usage: bash multinic-routing.sh [--discover | --apply | --rollback | --verify] OPTIONS' \
        'Default: read-only plan. Routes are runtime-only unless --persist is supplied.' \
        'Gateways: overrides > configured evidence > Azure subnet network + 1 (/2 through /29).' \
        '  --route CIDR[=LOCAL_IP_OR_INTERFACE_OR_MAC]  Repeatable; no default routes.' \
        '  --gateway INTERFACE_OR_IP_OR_MAC=GATEWAY   Repeatable override.' \
        '  --primary INTERFACE_OR_IP_OR_MAC          Override primary identity.' \
        '  --peer LOCAL_IP=REMOTE_IP                 Repeatable route-get verification.' \
        '  --protect-peer LOCAL_IP=REMOTE_IP         Refuse a plan changing this path.' \
        '  --allow-connected-overlap                Acknowledge direct connected subroutes.' \
        '  --persist                                Save owned routes in NetworkManager profiles.' \
        '  --apply                                  Root only; add reviewed routes.' \
        '  --rollback                               Root only; remove journal-owned routes.' \
        '  --verify                                 Read-only route and peer checks.' \
        '  --discover                               Read-only inventory; no mappings needed.' \
        '  --help'
}

ipv4_number() {
    local address=$1 first second third fourth extra
    [[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r first second third fourth extra <<< "$address"
    local octet
    for octet in "$first" "$second" "$third" "$fourth"; do
        [[ ${#octet} -le 3 && ( $octet == 0 || $octet != 0* ) ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
    printf '%s\n' "$(( (10#$first << 24) | (10#$second << 16) | (10#$third << 8) | 10#$fourth ))"
}

cidr_parts() {
    local value=$1 number length mask
    [[ $value == */* ]] || return 1
    length=${value#*/}
    [[ $length =~ ^(0|[1-9]|[12][0-9]|3[0-2])$ ]] || return 1
    number=$(ipv4_number "${value%/*}") || return 1
    mask=$(( (0xffffffff << (32-length)) & 0xffffffff ))
    printf '%s %s %s\n' "$number" "$length" "$((number & mask))"
}

contains() {
    local number length network target
    read -r number length network < <(cidr_parts "$1") || return 1
    target=$(ipv4_number "$2") || return 1
    (( (target & ((0xffffffff << (32-length)) & 0xffffffff)) == network ))
}

canonical_cidr() {
    local number length network
    read -r number length network < <(cidr_parts "$1") || fail "Invalid IPv4 CIDR: $1"
    (( length > 0 && number == network )) || fail "Use a canonical, non-default destination CIDR: $1"
}

route_field() {
    local text=$1 field=$2 previous='' token
    for token in $text; do
        if [[ $previous == "$field" ]]; then printf '%s\n' "$token"; return; fi
        previous=$token
    done
}

load_inventory() {
    local output device address rest mac
    output=$(ip -o -4 address show scope global) || fail 'Cannot read IPv4 addresses.'
    interfaces=(); addresses=(); macs=()
    while read -r _ device _ address rest; do
        [[ -n ${device:-} ]] || continue
        device=${device%%@*}
        [[ $device =~ ^[a-zA-Z0-9_.:-]+$ ]] || fail "Unsupported interface name: $device"
        cidr_parts "$address" >/dev/null || fail "Invalid configured prefix: $address"
        [[ $rest != *tentative* && $rest != *dadfailed* ]] || continue
        mac='unknown'
        if [[ -r /sys/class/net/$device/address ]]; then read -r mac < "/sys/class/net/$device/address"; fi
        interfaces+=("$device"); addresses+=("$address"); macs+=("${mac,,}")
    done <<< "$output"
    ((${#interfaces[@]})) || fail 'No usable global IPv4 addresses found.'
    routes=$(ip -N -4 -o route show table main) || fail 'Cannot read main routing table.'
    rules=$(ip -4 -o rule show) || fail 'Cannot read IPv4 policy rules.'
}

resolve_selector() {
    local selector=$1 index found=-1
    for index in "${!interfaces[@]}"; do
        if [[ $selector == "${interfaces[index]}" || $selector == "${addresses[index]%/*}" || ${selector,,} == "${macs[index]}" ]]; then
            ((found < 0)) || fail "Selector $selector matches multiple addresses; select a local IP."
            found=$index
        fi
    done
    ((found >= 0)) || fail "No local IPv4 interface matches $selector"
    printf '%s\n' "$found"
}

find_primary() {
    local line device candidate='' index
    if [[ -n $primary_override ]]; then
        index=$(resolve_selector "$primary_override") || fail 'Cannot resolve primary override.'
        primary=${interfaces[index]}
        primary_evidence='explicit override'
    else
        while IFS= read -r line; do
            [[ $line == default\ * ]] || continue
            device=$(route_field "$line" dev)
            [[ -n $device && $line != *nexthop* ]] || fail 'Ambiguous default route; use --primary.'
            [[ -z $candidate || $candidate == "$device" ]] || fail 'Multiple default-route interfaces; use --primary.'
            candidate=$device
        done <<< "$routes"
        [[ -n $candidate ]] || fail 'No default-route evidence for primary NIC; use --primary.'
        primary=$candidate
        primary_evidence='unique main-table default-route interface (guest evidence, not Azure API attestation)'
        local matched=false
        for device in "${interfaces[@]}"; do [[ $device != "$primary" ]] || matched=true; done
        $matched || fail 'Default-route interface has no usable global IPv4 address.'
    fi
}

gateway_for() {
    local index=$1 device=${interfaces[$1]} candidate='' evidence='' value line entry selector resolved
    for entry in "${gateway_overrides[@]}"; do
        [[ $entry == *=* ]] || fail "Invalid gateway override: $entry"
        selector=${entry%%=*}; value=${entry#*=}
        ipv4_number "$value" >/dev/null || fail "Invalid gateway override: $entry"
        resolved=$(resolve_selector "$selector") || fail 'Cannot resolve gateway override.'
        if [[ ${interfaces[resolved]} == "$device" ]]; then
            [[ -z $candidate ]] || fail "Multiple gateway overrides for $device"
            candidate=$value; evidence='override'
        fi
    done
    if [[ -z $candidate ]]; then
        local -a evidence_values=()
        while IFS= read -r line; do
            if [[ $line == default\ * && $(route_field "$line" dev) == "$device" ]]; then
                value=$(route_field "$line" via)
                [[ -z $value ]] || evidence_values+=("$value|installed-default")
            fi
        done <<< "$routes"
        if command -v nmcli >/dev/null 2>&1; then
            value=$(nmcli --escape no -g IP4.GATEWAY device show "$device" 2>/dev/null || true)
            while IFS= read -r line; do
                [[ -z $line || $line == -- ]] || evidence_values+=("$line|NetworkManager-IP4.GATEWAY")
            done <<< "$value"
            value=$(nmcli --escape no -g DHCP4.OPTION device show "$device" 2>/dev/null || true)
            while IFS= read -r line; do
                if [[ $line =~ ^routers[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                    for entry in ${BASH_REMATCH[1]}; do evidence_values+=("$entry|DHCP-routers"); done
                fi
            done <<< "${value// | /$'\n'}"
        fi
        for entry in "${evidence_values[@]}"; do
            value=${entry%%|*}
            [[ -z $candidate || $candidate == "$value" ]] || fail "Conflicting gateway evidence for $device; use --gateway."
            candidate=$value; evidence+="${entry#*|},"
        done
    fi
    local other number length network gateway_number
    read -r number length network < <(cidr_parts "${addresses[index]}") || fail "Invalid configured prefix: ${addresses[index]}"
    if [[ -z $candidate ]]; then
        (( length >= 2 && length <= 29 )) || fail "Cannot calculate an Azure gateway from ${addresses[index]} on $device; use --gateway $device=ACTUAL_GATEWAY."
        gateway_number=$((network + 1))
        printf -v candidate '%d.%d.%d.%d' \
            "$(((gateway_number >> 24) & 255))" "$(((gateway_number >> 16) & 255))" \
            "$(((gateway_number >> 8) & 255))" "$((gateway_number & 255))"
        evidence="Azure-subnet-network-plus-one(${addresses[index]})"
    fi
    ipv4_number "$candidate" >/dev/null || fail "Invalid gateway: $candidate"
    contains "${addresses[index]}" "$candidate" || fail "Gateway $candidate is outside ${addresses[index]} on $device."
    for other in "${addresses[@]}"; do [[ ${other%/*} != "$candidate" ]] || fail 'Gateway is a local address.'; done
    gateway_number=$(ipv4_number "$candidate")
    if ((length < 31)); then
        (( gateway_number != network && gateway_number != (network | (0xffffffff >> length)) )) || fail 'Gateway is a subnet network/broadcast address.'
    fi
    printf '%s|%s\n' "$candidate" "$evidence"
}

networkmanager_routes() {
    local uuid=$1 raw entry field key value seen cidr gateway metric source table supported number length network position
    local -a entries=() fields=()
    raw=$(nmcli --escape no -g ipv4.routes connection show uuid "$uuid") || fail "Cannot read saved routes for profile $uuid."
    [[ $raw != -- ]] || raw=''
    IFS=, read -r -a entries <<< "${raw//$'\n'/,}"
    for entry in "${entries[@]}"; do
        read -r -a fields <<< "$entry"
        ((${#fields[@]})) || continue
        cidr=${fields[0]}; gateway=0.0.0.0; metric=-1; source=''; table=0; supported=true; seen='|'; position=1
        if ((position < ${#fields[@]})) && ipv4_number "${fields[position]}" >/dev/null; then
            gateway=${fields[position]}; position=$((position+1))
        fi
        if ((position < ${#fields[@]})) && [[ ${fields[position]} =~ ^[0-9]+$ ]]; then
            metric=${fields[position]}; position=$((position+1))
        fi
        for field in "${fields[@]:position}"; do
            [[ $field =~ ^[a-zA-Z0-9_-]+=.+$ ]] || fail "Unsupported NetworkManager route field for $uuid: $field"
            key=${field%%=*}; value=${field#*=}
            [[ $seen != *"|$key|"* ]] || fail "Duplicate NetworkManager route field: $key"
            seen+="$key|"
            case $key in
                src) source=$value ;;
                table) table=$value ;;
                *) supported=false ;;
            esac
        done
        [[ $cidr == */* ]] || cidr+='/32'
        read -r number length network < <(cidr_parts "$cidr") || fail "Invalid saved route prefix: $cidr"
        ((number == network)) || fail "Noncanonical saved route prefix: $cidr"
        ipv4_number "$gateway" >/dev/null || fail "Invalid saved route gateway: $gateway"
        [[ -z $source ]] || ipv4_number "$source" >/dev/null || fail "Invalid saved route source: $source"
        [[ $metric =~ ^(-1|[0-9]+)$ && $table =~ ^[0-9]+$ ]] || fail 'Invalid saved route metric/table.'
        printf '%s|%s|%s|%s|%s|%s\n' "$cidr" "$gateway" "$metric" "$source" "$table" "$supported"
    done
}

saved_route_status() {
    local uuid=$1 cidr=$2 gateway=$3 source=$4 entries destination next_hop metric preferred_source table supported count=0
    entries=$(networkmanager_routes "$uuid") || fail 'Cannot assess saved route ownership.'
    while IFS='|' read -r destination next_hop metric preferred_source table supported; do
        [[ $destination == "$cidr" ]] || continue
        [[ $next_hop == "$gateway" && $metric == 42760 && $preferred_source == "$source" &&
           $table == 254 && $supported == true ]] || fail "Saved route collision for $cidr in profile $uuid."
        count=$((count+1))
    done <<< "$entries"
    ((count <= 1)) || fail "Duplicate saved routes for $cidr in profile $uuid."
    if ((count)); then printf 'present\n'; else printf 'absent\n'; fi
}

load_persistent_state() {
    local record uuid cidr device gateway source extra
    persistent_records=()
    if [[ -e $state_dir/networkmanager ]]; then
        [[ -f $state_dir/networkmanager && ! -L $state_dir/networkmanager ]] || fail 'Unsafe persistent journal path.'
        mapfile -t persistent_records < "$state_dir/networkmanager" || fail 'Cannot read persistent journal; use root if it is protected.'
        for record in "${persistent_records[@]}"; do
            IFS='|' read -r uuid cidr device gateway source extra <<< "$record"
            [[ $uuid =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ &&
               $device =~ ^[a-zA-Z0-9_.:-]+$ && -z ${extra:-} ]] || fail 'Invalid persistent journal record.'
            canonical_cidr "$cidr"
            ipv4_number "$gateway" >/dev/null && ipv4_number "$source" >/dev/null || fail 'Invalid persistent journal IP.'
            [[ -f $state_file ]] && grep -Fxq "$cidr|$device|$gateway|$source" "$state_file" || fail 'Persistent journal does not match the runtime journal.'
        done
    fi
}

prepare_persistence() {
    local record cidr device gateway source uuid autoconnect permissions profile status existing profile_device files filename file_uuid file_path matches
    command -v nmcli >/dev/null || fail '--persist requires the active NetworkManager backend and nmcli.'
    persistent_plan=()
    for record in "${plan[@]}"; do
        IFS='|' read -r cidr device gateway source <<< "$record"
        uuid=$(nmcli --escape no -g GENERAL.CON-UUID device show "$device") || fail "Cannot find an active NetworkManager profile for $device."
        [[ $uuid =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] || fail "No unique active NetworkManager profile for $device."
        files=$(nmcli --terse --escape no -f UUID,FILENAME connection show) || fail 'Cannot inspect NetworkManager profile storage.'
        filename=''; matches=0
        while IFS=: read -r file_uuid file_path; do
            [[ $file_uuid == "$uuid" ]] || continue
            filename=$file_path; matches=$((matches+1))
        done <<< "$files"
        [[ $matches == 1 && $filename == /etc/* ]] || fail "Profile $uuid is not uniquely saved under /etc; temporary/generated profiles need explicit administrator review."
        autoconnect=$(nmcli --escape no -g connection.autoconnect connection show uuid "$uuid") || fail 'Cannot read profile autoconnect setting.'
        [[ $autoconnect == yes || $autoconnect == true ]] || fail "Profile $uuid does not autoconnect; persistence would not be reliable at boot."
        permissions=$(nmcli --escape no -g connection.permissions connection show uuid "$uuid") || fail 'Cannot read profile permissions.'
        [[ -z $permissions || $permissions == -- ]] || fail "Profile $uuid is user-restricted and may not activate at boot."
        for existing in "${persistent_plan[@]}"; do
            profile=${existing%%|*}; profile_device=${existing#*|*|}; profile_device=${profile_device%%|*}
            [[ $profile != "$uuid" || $profile_device == "$device" ]] || fail "Profile $uuid is shared by multiple mapped devices."
        done
        status=$(saved_route_status "$uuid" "$cidr" "$gateway" "$source") || fail 'Cannot establish persistent route state.'
        if [[ $status == present ]]; then
            local owned=false
            for existing in "${persistent_records[@]}"; do [[ $existing != "$uuid|$record" ]] || owned=true; done
            $owned || fail "Existing saved route for $cidr is not journal-owned."
        fi
        persistent_plan+=("$uuid|$record")
        printf 'PERSIST %s profile=%s route="%s %s 42760 src=%s table=254" state=%s\n' "$device" "$uuid" "$cidr" "$gateway" "$source" "$status"
    done
    if [[ -f $state_dir/networkmanager ]]; then
        [[ $(printf '%s\n' "${persistent_records[@]}") == "$(printf '%s\n' "${persistent_plan[@]}")" ]] || fail 'Different persistent plan exists; roll it back with --rollback --persist before changing it.'
    fi
}

apply_persistence() {
    local record uuid cidr device gateway source status temporary
    if [[ ! -f $state_dir/networkmanager ]]; then
        temporary=$(mktemp "$state_dir/networkmanager.XXXXXX") || fail 'Cannot create persistent journal.'
        chmod 600 "$temporary"
        printf '%s\n' "${persistent_plan[@]}" > "$temporary"
        mv -- "$temporary" "$state_dir/networkmanager"
    fi
    for record in "${persistent_plan[@]}"; do
        IFS='|' read -r uuid cidr device gateway source <<< "$record"
        status=$(saved_route_status "$uuid" "$cidr" "$gateway" "$source") || fail 'Saved routes changed during apply; journal retained.'
        if [[ $status == absent ]]; then
            nmcli connection modify uuid "$uuid" +ipv4.routes "$cidr $gateway 42760 src=$source table=254" || fail 'Persistent apply failed; journals retained. Review state before --rollback --persist.'
        fi
        [[ $(saved_route_status "$uuid" "$cidr" "$gateway" "$source") == present ]] || fail 'Persistent route verification failed; journals retained.'
    done
    printf 'Routes saved in NetworkManager profiles; no profile was reactivated.\n'
}

rollback_persistence() {
    local record uuid cidr device gateway source status
    command -v nmcli >/dev/null || fail 'nmcli is required to roll back persistent routes.'
    for record in "${persistent_records[@]}"; do
        IFS='|' read -r uuid cidr device gateway source <<< "$record"
        status=$(saved_route_status "$uuid" "$cidr" "$gateway" "$source") || fail 'Persistent route changed externally; journals retained.'
    done
    for record in "${persistent_records[@]}"; do
        IFS='|' read -r uuid cidr device gateway source <<< "$record"
        status=$(saved_route_status "$uuid" "$cidr" "$gateway" "$source") || fail 'Persistent route changed during rollback; journals retained.'
        if [[ $status == present ]]; then
            nmcli connection modify uuid "$uuid" -ipv4.routes "$cidr $gateway 42760 src=$source table=254" || fail 'Persistent rollback failed; journals retained.'
        fi
        [[ $(saved_route_status "$uuid" "$cidr" "$gateway" "$source") == absent ]] || fail 'Saved route remains after rollback; journals retained.'
    done
}

owned_route_present() {
    local cidr=$1 device=$2 gateway=$3 source=$4 line exact protocol record uuid status
    exact=$(ip -N -4 -o route show table main exact "$cidr") || fail 'Cannot query route.'
    [[ -n $exact && $exact != *$'\n'* ]] || return 1
    line=$exact
    [[ $(route_field "$line" dev) == "$device" && $(route_field "$line" via) == "$gateway" &&
       $(route_field "$line" src) == "$source" && $(route_field "$line" metric) == 42760 &&
       $line != *nexthop* ]] || return 1
    protocol=$(route_field "$line" proto)
    [[ $protocol != 242 ]] || return 0
    [[ $protocol == 4 || $protocol == static ]] || return 1
    for record in "${persistent_records[@]}"; do
        [[ ${record#*|} == "$cidr|$device|$gateway|$source" ]] || continue
        uuid=${record%%|*}
        status=$(saved_route_status "$uuid" "$cidr" "$gateway" "$source") || fail 'Cannot verify NetworkManager route ownership.'
        if [[ $status == present || ${5:-false} == true ]]; then return 0; fi
    done
    return 1
}

build_plan() {
    local mapping cidr selector index selected other gateway evidence line destination device route_index
    local -a previous_cidrs=()
    plan=()
    for mapping in "${mappings[@]}"; do
        cidr=${mapping%%=*}; selector=''
        if [[ $mapping == *=* ]]; then
            selector=${mapping#*=}
            [[ -n $selector ]] || fail "Empty route selector: $mapping"
        fi
        canonical_cidr "$cidr"
        for other in "${previous_cidrs[@]}"; do
            if contains "$cidr" "${other%/*}" || contains "$other" "${cidr%/*}"; then fail "Overlapping destination mappings: $cidr and $other"; fi
        done
        previous_cidrs+=("$cidr")
        if [[ -n $selector ]]; then
            selected=$(resolve_selector "$selector") || fail 'Cannot resolve route selector.'
        else
            selected=-1
            for index in "${!interfaces[@]}"; do
                if contains "$cidr" "${addresses[index]%/*}"; then
                    ((selected < 0)) || fail "Multiple local addresses match $cidr; specify CIDR=LOCAL_IP."
                    selected=$index
                fi
            done
            ((selected >= 0)) || fail "No local address matches $cidr; specify CIDR=LOCAL_IP."
        fi
        device=${interfaces[selected]}
        evidence=$(gateway_for "$selected") || fail "Cannot establish gateway for $device."
        gateway=${evidence%%|*}; evidence=${evidence#*|}
        printf 'MAP %s -> %s mac=%s source=%s gateway=%s evidence=%s\n' "$cidr" "$device" "${macs[selected]}" "${addresses[selected]}" "$gateway" "$evidence"
        for index in "${!addresses[@]}"; do
            if [[ ${interfaces[index]} != "$device" ]] && contains "$cidr" "${addresses[index]%/*}"; then
                fail "$cidr includes another local NIC (${addresses[index]}); narrow the aggregate."
            fi
        done
        while IFS= read -r line; do
            [[ -n $line ]] || continue
            destination=${line%% *}
            [[ $destination != default ]] || continue
            [[ $destination == */* ]] || destination+='/32'
            cidr_parts "$destination" >/dev/null || fail "Unsupported main-table route: $line"
            if [[ $destination == "$cidr" ]]; then
                if [[ -f $state_file ]] && grep -Fxq "$cidr|$device|$gateway|${addresses[selected]%/*}" "$state_file" &&
                   owned_route_present "$cidr" "$device" "$gateway" "${addresses[selected]%/*}"; then continue; fi
                fail "Existing route collision for $cidr: $line"
            fi
            if (( ${destination#*/} > ${cidr#*/} )) && contains "$cidr" "${destination%/*}"; then
                if [[ $(route_field "$line" scope) =~ ^(link|253)$ && $(route_field "$line" dev) == "$device" && $allow_connected == true ]]; then
                    warn "More-specific connected route stays direct: $line"
                else
                    fail "More-specific route overrides $cidr: $line (same-NIC connected routes require --allow-connected-overlap)."
                fi
            fi
        done <<< "$routes"
        plan+=("$cidr|$device|$gateway|${addresses[selected]%/*}")
    done
    while IFS= read -r line; do
        [[ $line =~ ^(0:|32766:|32767:)[[:space:]] ]] || fail "Custom IPv4 policy rule requires manual assessment: $line"
    done <<< "$rules"
}

mutate_route() {
    local action=$1 cidr=$2 device=$3 gateway=$4 source=$5
    ip -4 route "$action" "$cidr" via "$gateway" dev "$device" src "$source" proto 242 metric 42760
}

state_paths() {
    state_dir=/var/lib/azure-multinic
    state_file=$state_dir/routes
}

lock_state() {
    ((EUID == 0)) || fail 'Root is required only for apply/rollback.'
    command -v flock >/dev/null || fail 'flock (normally supplied by util-linux) is required for mutation.'
    [[ ! -L $state_dir && ! -L $state_file ]] || fail 'Refusing symbolic-link state paths.'
    if [[ ! -d $state_dir ]]; then mkdir -m 700 -- "$state_dir"; fi
    [[ $(stat -c '%u:%a' "$state_dir") == 0:700 ]] || fail "State directory must be root-owned mode 700: $state_dir"
    if [[ -e $state_file ]]; then
        [[ -f $state_file && $(stat -c '%u:%a' "$state_file") == 0:600 ]] || fail 'Unsafe state journal permissions.'
    fi
    if [[ -e $state_dir/networkmanager || -L $state_dir/networkmanager ]]; then
        [[ -f $state_dir/networkmanager && ! -L $state_dir/networkmanager &&
           $(stat -c '%u:%a' "$state_dir/networkmanager") == 0:600 ]] || fail 'Unsafe persistent journal permissions.'
    fi
    exec 9>"$state_dir/lock"
    flock -n 9 || fail 'Another routing operation is running.'
}

rollback() {
    local cidr device gateway source extra
    [[ -f $state_file ]] || { printf 'No owned routes to roll back.\n'; return; }
    local -a saved=()
    local -a removable=()
    mapfile -t saved < "$state_file"
    local record
    for record in "${saved[@]}"; do
        IFS='|' read -r cidr device gateway source extra <<< "$record"
        canonical_cidr "$cidr"
        [[ -z ${extra:-} && $device =~ ^[a-zA-Z0-9_.:-]+$ ]] || fail 'Invalid journal record.'
        ipv4_number "$gateway" >/dev/null && ipv4_number "$source" >/dev/null || fail 'Invalid journal IP.'
        if owned_route_present "$cidr" "$device" "$gateway" "$source" true; then
            removable+=("$record|$(route_field "$(ip -N -4 -o route show table main exact "$cidr")" proto)")
        elif [[ -n $(ip -N -4 -o route show table main exact "$cidr") ]]; then
            fail "Owned route changed externally: $cidr. Refusing to delete; journal retained."
        fi
    done
    if [[ -f $state_dir/networkmanager ]]; then rollback_persistence; fi
    local protocol
    for record in "${removable[@]}"; do
        IFS='|' read -r cidr device gateway source protocol <<< "$record"
        if [[ $protocol == 242 ]]; then
            mutate_route del "$cidr" "$device" "$gateway" "$source" || fail 'Rollback failed; journals retained.'
        else
            ip -4 route del "$cidr" via "$gateway" dev "$device" src "$source" proto "$protocol" metric 42760 || fail 'Rollback failed; journals retained.'
        fi
    done
    if [[ -f $state_dir/networkmanager ]]; then rm -- "$state_dir/networkmanager"; fi
    rm -- "$state_file"
    printf 'Rollback complete. Unrelated routes were not removed.\n'
}

verify_peers() {
    local pair source peer index result device found failure=false
    ((${#peers[@]})) || { warn 'No --peer LOCAL_IP=REMOTE_IP supplied; live source-specific selection was not tested.'; return; }
    for pair in "${peers[@]}"; do
        [[ $pair == *=* ]] || fail "Invalid peer: $pair"
        source=${pair%%=*}; peer=${pair#*=}
        ipv4_number "$peer" >/dev/null || fail "Invalid peer address: $peer"
        index=$(resolve_selector "$source") || fail 'Cannot resolve peer source.'
        [[ ${addresses[index]%/*} == "$source" ]] || fail 'Peer source must be a local IPv4 address.'
        result=$(ip -4 route get "$peer" from "$source") || fail "Route lookup failed: $pair"
        printf 'LOOKUP %s: %s\n' "$pair" "$result"
        device=$(route_field "$result" dev)
        if [[ $device != "${interfaces[index]}" ]]; then
            warn "Asymmetric egress for $pair; assess source policy routing and rp_filter. No sysctl was changed."
            failure=true
        fi
    done
    ! $failure || fail 'Source-specific egress verification failed.'
}

validate_peers() {
    local pair source peer index
    for pair in "${peers[@]}" "${protected_peers[@]}"; do
        [[ $pair == *=* ]] || fail "Invalid peer mapping: $pair"
        source=${pair%%=*}; peer=${pair#*=}
        ipv4_number "$peer" >/dev/null || fail "Invalid peer IPv4: $peer"
        index=$(resolve_selector "$source") || fail 'Cannot resolve peer source.'
        [[ ${addresses[index]%/*} == "$source" ]] || fail 'Peer source must be a local IPv4 address.'
    done
}

protect_management() {
    local pair source peer lookup existing_device existing_gateway record cidr device gateway chosen_source
    for pair in "${protected_peers[@]}"; do
        source=${pair%%=*}; peer=${pair#*=}
        lookup=$(ip -4 route get "$peer" from "$source") || fail "Cannot inspect protected path: $pair"
        existing_device=$(route_field "$lookup" dev); existing_gateway=$(route_field "$lookup" via)
        for record in "${plan[@]}"; do
            IFS='|' read -r cidr device gateway chosen_source <<< "$record"
            contains "$cidr" "$peer" || continue
            if [[ -z $existing_gateway && $device == "$existing_device" && $allow_connected == true ]]; then continue; fi
            [[ $device == "$existing_device" && $gateway == "$existing_gateway" ]] || fail "Plan would change protected management path $pair; narrow mappings or use console access."
        done
    done
}

main() {
    local mode=plan arg evidence index record cidr device gateway source temporary
    primary_override=''; allow_connected=false; persist=false
    state_paths
    mappings=(); gateway_overrides=(); peers=(); protected_peers=(); plan=(); persistent_records=(); persistent_plan=()
    while (($#)); do
        arg=$1; shift
        case $arg in
            --help|-h) usage; return ;;
            --discover|--apply|--rollback|--verify)
                [[ $mode == plan ]] || fail 'Choose only one operation.'; mode=${arg#--} ;;
            --allow-connected-overlap) allow_connected=true ;;
            --persist) persist=true ;;
            --route|--gateway|--primary|--peer|--protect-peer)
                (($#)) && [[ -n $1 && $1 != --* ]] || fail "Missing argument for $arg"
                case $arg in
                    --route) mappings+=("$1") ;;
                    --gateway) gateway_overrides+=("$1") ;;
                    --primary) [[ -z $primary_override ]] || fail 'Duplicate --primary.'; primary_override=$1 ;;
                    --peer) peers+=("$1") ;;
                    --protect-peer) protected_peers+=("$1") ;;
                esac
                shift ;;
            *) fail "Unknown argument: $arg" ;;
        esac
    done
    command -v ip >/dev/null || fail 'iproute2 is required.'
    if [[ $mode == apply || $mode == rollback ]]; then lock_state; fi
    load_persistent_state
    if [[ -f $state_dir/networkmanager && ( $mode == apply || $mode == rollback ) && $persist == false ]]; then
        fail 'This plan owns persistent routes; include --persist to apply or roll it back.'
    fi
    if [[ $mode == rollback ]]; then rollback; return; fi
    load_inventory
    find_primary
    printf 'PRIMARY %s evidence=%s\n' "$primary" "$primary_evidence"
    for index in "${!interfaces[@]}"; do
        printf 'NIC %s mac=%s IPv4=%s\n' "${interfaces[index]}" "${macs[index]}" "${addresses[index]}"
        if [[ -r /proc/sys/net/ipv4/conf/${interfaces[index]}/rp_filter ]]; then
            printf 'rp_filter %s=' "${interfaces[index]}"; cat "/proc/sys/net/ipv4/conf/${interfaces[index]}/rp_filter"
        fi
    done
    if [[ -r /proc/sys/net/ipv4/conf/all/rp_filter ]]; then printf 'rp_filter all='; cat /proc/sys/net/ipv4/conf/all/rp_filter; fi
    if [[ $mode == discover ]]; then
        for index in "${!interfaces[@]}"; do
            if evidence=$(gateway_for "$index"); then printf 'GATEWAY %s %s\n' "${interfaces[index]}" "$evidence"; else warn "Gateway unresolved for ${interfaces[index]}."; fi
        done
        printf 'IPv4 main routes:\n%s\nIPv4 rules:\n%s\n' "$routes" "$rules"
        return
    fi
    ((${#mappings[@]})) || fail 'Supply at least one --route CIDR[=SELECTOR].'
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        local ssh_remote ssh_remote_port ssh_local ssh_local_port
        read -r ssh_remote ssh_remote_port ssh_local ssh_local_port <<< "$SSH_CONNECTION"
        if ipv4_number "$ssh_remote" >/dev/null && ipv4_number "$ssh_local" >/dev/null; then
            protected_peers+=("$ssh_local=$ssh_remote")
        else
            warn 'SSH session is not IPv4; its path cannot be validated by this IPv4 script.'
        fi
    fi
    validate_peers
    for record in "${gateway_overrides[@]}"; do
        [[ $record == *=* ]] || fail "Invalid gateway override: $record"
        index=$(resolve_selector "${record%%=*}") || fail 'Cannot resolve gateway override.'
        evidence=$(gateway_for "$index") || fail 'Invalid gateway override.'
    done
    build_plan
    protect_management
    if $persist || [[ -f $state_dir/networkmanager ]]; then
        prepare_persistence
        printf 'Runtime and NetworkManager persistent plan (no primary default-route changes):\n'
    else
        printf 'Runtime-only plan (no primary default-route changes):\n'
    fi
    printf '  %s\n' "${plan[@]}"
    warn 'Destination routes do not ensure arbitrary source symmetry. Azure transit/peering/UDRs and NSG/firewall permission must already exist.'
    if [[ $mode == apply ]]; then
        if [[ -f $state_file ]]; then
            [[ $(cat "$state_file") == "$(printf '%s\n' "${plan[@]}")" ]] || fail 'Different owned plan exists; roll it back before changing mappings.'
        else
            temporary=$(mktemp "$state_dir/routes.XXXXXX")
            chmod 600 "$temporary"
            printf '%s\n' "${plan[@]}" > "$temporary"
            mv -- "$temporary" "$state_file"
        fi
        if $persist; then apply_persistence; load_persistent_state; fi
        for record in "${plan[@]}"; do
            IFS='|' read -r cidr device gateway source <<< "$record"
            if ! owned_route_present "$cidr" "$device" "$gateway" "$source"; then
                mutate_route add "$cidr" "$device" "$gateway" "$source" || fail 'Apply failed. Journal retained; use --rollback after reviewing current state.'
            fi
            owned_route_present "$cidr" "$device" "$gateway" "$source" || fail 'Installed route verification failed; journal retained.'
        done
        [[ $(ip -N -4 -o route show table main default) == "$(printf '%s\n' "$routes" | grep '^default ' || true)" ]] || fail 'Default route changed during apply; inspect concurrent network configuration.'
        printf 'Apply complete. Journal: %s\n' "$state_file"
    elif [[ $mode == verify ]]; then
        if $persist || [[ -f $state_dir/networkmanager ]]; then
            for record in "${persistent_plan[@]}"; do
                IFS='|' read -r index cidr device gateway source <<< "$record"
                [[ $(saved_route_status "$index" "$cidr" "$gateway" "$source") == present ]] || fail "Persistent route is not saved as planned: $cidr"
            done
        fi
        for record in "${plan[@]}"; do
            IFS='|' read -r cidr device gateway source <<< "$record"
            owned_route_present "$cidr" "$device" "$gateway" "$source" || fail "Owned route not installed as planned: $cidr"
        done
    fi
    verify_peers
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi