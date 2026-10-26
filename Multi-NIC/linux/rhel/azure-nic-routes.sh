#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

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
        '  --persist                  With --apply, also save NetworkManager routes.' \
        '  --metric NUMBER            Positive IPv4 route metric; default 42762.' \
        '  --rollback                 Remove custom routes with the selected metric.' \
        '  --reset                    Remove custom routes with any metric.' \
        '    Cleanup includes saved routes on active managed Ethernet NICs; defaults stay.' \
        '    No profile deletion/reactivation. Use a console for cleanup --apply.' \
        '  --help                     Show this help.'
}

simple_os_release() (
    local release_file=${1:-/etc/os-release} ID='' ID_LIKE=''
    [[ -f $release_file && -r $release_file ]] || simple_fail 'Cannot read OS metadata.'
    . "$release_file" || simple_fail 'Cannot load OS metadata.'
    [[ -n $ID ]] || simple_fail 'OS metadata has no ID.'
    printf '%s\n' "$ID" "$ID_LIKE"
)
simple_check_os() {
    local metadata family
    local -a families=()
    metadata=$(simple_os_release) || simple_fail 'Cannot determine OS family; requires a RHEL/Fedora-derived distribution.'
    read -r -a families <<< "${metadata//$'\n'/ }"
    for family in "${families[@]}"; do
        case $family in rhel|centos|fedora|rocky|almalinux|ol) return ;; esac
    done
    simple_fail "Unsupported OS family: ${metadata//$'\n'/ }. Requires a RHEL/Fedora-derived distribution."
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
        if command -v nmcli >/dev/null; then
            value=$(nmcli --escape no -g IP4.GATEWAY device show "$device" 2>/dev/null || true)
            while IFS= read -r line; do [[ -z $line || $line == -- ]] || values+=("$line|NetworkManager"); done <<< "$value"
            value=$(nmcli --escape no -g DHCP4.OPTION device show "$device" 2>/dev/null || true)
            while IFS= read -r line; do
                if [[ $line =~ ^routers[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                    for record in ${BASH_REMATCH[1]}; do values+=("$record|DHCP"); done
                fi
            done <<< "${value// | /$'\n'}"
        fi
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
simple_profile() {
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
simple_saved_spec() {
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
simple_saved() {
    local cidr device gateway source uuid raw entry spec count=0
    local -a entries=() fields=()
    IFS='|' read -r cidr device gateway source uuid <<< "$1"
    spec=$(simple_saved_spec "$1") || simple_fail 'Cannot establish saved route format.'
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
    local record cidr device gateway source uuid status spec
    for record in "${simple_plan_rows[@]}"; do
        IFS='|' read -r cidr device gateway source uuid <<< "$record"
        if [[ $uuid != - ]]; then
            status=$(simple_saved "$record") || simple_fail 'Saved routes changed during apply.'
            if [[ $status == absent ]]; then
                spec=$(simple_saved_spec "$record") || simple_fail 'Cannot establish saved route format.'
                nmcli connection modify uuid "$uuid" +ipv4.routes "$spec" || simple_fail 'Saving failed; partial changes may remain.'
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
simple_profile_routes() {
    local raw
    raw=$(nmcli --escape no -g ipv4.routes connection show uuid "$1") || simple_fail 'Cannot inspect saved routes.'
    [[ $raw != -- ]] || raw=''
    printf '%s\n' "${raw//$'\n'/,}"
}
simple_cleanup() {
    local mode=$1 output device type state uuid previous raw entry cidr metric table profile_table attribute route_type line protocol gateway source index current
    local -a targets=() uuids=() snapshots=() saved_rows=() live_rows=() entries=() fields=() arguments=()
    command -v nmcli >/dev/null || simple_fail 'Route cleanup requires active NetworkManager and nmcli.'
    simple_inventory
    output=$(nmcli --terse --escape no -f DEVICE,TYPE,STATE device status) || simple_fail 'Cannot list NetworkManager devices.'
    while IFS=: read -r device type state; do
        [[ $type == ethernet && $state == connected* ]] || continue
        [[ $device =~ ^[a-zA-Z0-9_.:-]+$ ]] || simple_fail 'Unsupported cleanup device.'
        uuid=$(nmcli --escape no -g GENERAL.CON-UUID device show "$device") || simple_fail 'Cannot inspect active profile.'
        [[ $uuid =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] || simple_fail 'No unique active cleanup profile.'
        for previous in "${uuids[@]}"; do [[ $previous != "$uuid" ]] || simple_fail 'Cleanup profile is shared by multiple devices.'; done
        targets+=("$device"); uuids+=("$uuid")
        profile_table=$(nmcli --escape no -g ipv4.route-table connection show uuid "$uuid") || simple_fail 'Cannot inspect profile route table.'
        [[ $profile_table =~ ^[0-9]+$ ]] || simple_fail 'Unsupported profile route table.'
        [[ $profile_table != 0 ]] || profile_table=254
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
    current=$(ip -N -4 -o route show table main) || simple_fail 'Cannot recheck routes before removal.'
    [[ $current == "$simple_routes" ]] || simple_fail 'Routes changed during planning; rerun the preview.'
    for index in "${!uuids[@]}"; do
        current=$(simple_profile_routes "${uuids[index]}") || simple_fail 'Cannot recheck saved routes before removal.'
        [[ $current == "${snapshots[index]}" ]] || simple_fail 'Saved routes changed during planning; rerun the preview.'
    done
    for entry in "${saved_rows[@]}"; do
        uuid=${entry%%|*}; entry=${entry#*|}
        nmcli connection modify uuid "$uuid" -ipv4.routes "$entry" || simple_fail 'Saved route removal failed; partial changes may remain.'
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
simple_main() {
    local arg operation='' metric_explicit=false record selected evidence
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
    command -v ip >/dev/null || simple_fail 'iproute2 is required.'
    if $simple_apply; then simple_root; fi
    if [[ -n $operation ]]; then
        ((${#simple_maps[@]} == 0 && ${#simple_overrides[@]} == 0)) && ! $simple_persist || simple_fail 'Cleanup is separate from maps, gateway overrides and --persist; saved routes are included automatically.'
        [[ $operation != reset ]] || ! $metric_explicit || simple_fail '--reset removes all custom metrics; use --metric with --rollback instead.'
        simple_cleanup "$operation"; return
    fi
    ((${#simple_maps[@]})) || simple_fail 'Supply at least one --map.'
    simple_inventory
    for record in "${simple_overrides[@]}"; do
        [[ $record == *=* ]] || simple_fail 'Invalid gateway override.'
        selected=$(simple_select "${record%%=*}") || simple_fail 'Invalid gateway selector.'
        evidence=$(simple_gateway "$selected") || simple_fail 'Invalid gateway override.'
    done
    simple_plan
    if ((${#simple_plan_rows[@]} == 0)); then
        printf 'No route additions needed. No changes made.\n'
        return
    fi
    printf 'Azure connectivity, NSGs/firewalls and symmetric reply routing remain separate prerequisites.\n'
    if $simple_apply; then simple_add
    else printf 'DRY RUN: No changes. Add --apply for runtime routes; add --apply --persist to save them.\n'; fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then simple_main "$@"; fi