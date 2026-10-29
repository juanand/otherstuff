#!/usr/bin/env bash

set -euo pipefail

command -v fold >/dev/null 2>&1 || {
    printf '%s\n' 'Error: Missing required utility: fold' >&2
    exit 1
}

message() {
    printf '%s\n' "$@" | fold -s -w 78
}

fail() {
    message "Error: $1" >&2
    exit 1
}

merge_java_options() {
    local existing=$1 truststore=$2 option result=''
    local options=()
    [[ $existing =~ ^[a-zA-Z0-9_\ .:/,=+@%-]*$ ]] || fail 'JAVA_TOOL_OPTIONS must contain simple single-line options without quotes, backslashes, or shell metacharacters. Configure complex options per application.'
    read -r -a options <<< "$existing"
    for option in "${options[@]}"; do
        case $option in
            "-Djavax.net.ssl.trustStore=$truststore") ;;
            -Djavax.net.ssl.trustStore*) fail 'Conflicting Java truststore option found. Review JAVA_TOOL_OPTIONS before installation.' ;;
            *) result+="${result:+ }$option" ;;
        esac
    done
    printf '%s%s-Djavax.net.ssl.trustStore=%s' "$result" "${result:+ }" "$truststore"
}

certificate_thumbprint() {
    local fingerprint
    fingerprint=$(openssl x509 "$@" -noout -fingerprint -sha256 2>/dev/null) || return 1
    fingerprint=${fingerprint#*=}
    fingerprint=${fingerprint//:/}
    [[ $fingerprint =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s\n' "${fingerprint,,}"
}

scan_certificate_file() {
    local source=$1 line ending normalized block='' end_marker='' fingerprint
    scan_original=''
    scan_contents=''
    scan_count=0
    scan_matches=0
    scan_other_blocks=0
    scan_der=''
    scan_delete=0
    scan_hashes=()
    [[ -f $source && -r $source ]] || fail "Not a readable certificate source: $source"
    if ! grep -aqE '^-----BEGIN (TRUSTED )?CERTIFICATE-----' -- "$source"; then
        if fingerprint=$(certificate_thumbprint -inform DER -in "$source"); then
            scan_der=$fingerprint
            scan_hashes+=("$fingerprint")
            scan_count=1
            if [[ -n ${removal_thumbprints["$fingerprint"]+present} ]]; then
                scan_matches=1
                scan_delete=1
            fi
        fi
        return
    fi
    while true; do
        line=''
        if IFS= read -r line; then
            ending=$'\n'
        else
            [[ -n $line ]] || break
            ending=''
        fi
        normalized=${line%$'\r'}
        scan_original+="$line$ending"
        if [[ -n $end_marker ]]; then
            [[ $normalized != '-----BEGIN '* ]] || fail "Nested PEM certificate in $source"
            block+="$line$ending"
            if [[ $normalized == "$end_marker" ]]; then
                fingerprint=$(printf '%s' "$block" | certificate_thumbprint) ||
                    fail "Invalid PEM certificate in $source"
                scan_hashes+=("$fingerprint")
                scan_count=$((scan_count + 1))
                if [[ -n ${removal_thumbprints["$fingerprint"]+present} ]]; then
                    scan_matches=$((scan_matches + 1))
                else
                    scan_contents+="$block"
                fi
                block=''
                end_marker=''
            fi
        else
            case $normalized in
                '-----BEGIN CERTIFICATE-----')
                    block=$line$ending
                    end_marker='-----END CERTIFICATE-----' ;;
                '-----BEGIN TRUSTED CERTIFICATE-----')
                    block=$line$ending
                    end_marker='-----END TRUSTED CERTIFICATE-----' ;;
                '-----END CERTIFICATE-----'|'-----END TRUSTED CERTIFICATE-----')
                    fail "Unexpected PEM certificate terminator in $source" ;;
                *)
                    if [[ $normalized == '-----BEGIN '* ]]; then
                        scan_other_blocks=1
                    fi
                    scan_contents+="$line$ending" ;;
            esac
        fi
    done < "$source"
    [[ -z $end_marker ]] || fail "Unclosed PEM certificate in $source"
    if (( scan_matches > 0 && scan_matches == scan_count && scan_other_blocks == 0 )); then
        scan_delete=1
    fi
}

clean_environment() {
    local source=$1 expected_bundle=$2 expected_store=$3
    awk -v expected="$expected_bundle" -v store="$expected_store" '
        {
            original = $0
            assignment = $0
            sub(/\r$/, "", assignment)
            sub(/^[[:space:]]*(export[[:space:]]+)?/, "", assignment)
            if (!match(assignment, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/)) {
                print original
                next
            }
            name = substr(assignment, 1, RLENGTH)
            value = substr(assignment, RLENGTH + 1)
            sub(/[[:space:]]*=$/, "", name)
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            first = substr(value, 1, 1)
            if ((first == "\"" || first == "\047") && substr(value, length(value), 1) == first) {
                value = substr(value, 2, length(value) - 2)
            }
            if (name ~ /^(REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE|SSL_CERT_FILE|NODE_EXTRA_CA_CERTS)$/ && value == expected) next
            option = "-Djavax.net.ssl.trustStore=" store
            if (name == "JAVA_TOOL_OPTIONS" && index(value, option)) {
                if (value !~ /^[a-zA-Z0-9_ .:\/,=+@%-]*$/) {
                    invalid = 1
                    next
                }
                count = split(value, options, /[[:space:]]+/)
                result = ""
                removed = 0
                for (position = 1; position <= count; position++) {
                    if (options[position] == option) removed = 1
                    else if (options[position] != "") result = result (result == "" ? "" : " ") options[position]
                }
                if (removed) {
                    if (result != "") printf "%s\"%s\"\n", substr(original, 1, index(original, "=")), result
                    next
                }
            }
            print original
        }
        END { if (invalid) exit 1 }
    ' "$source"
}

check_directory_chain() {
    local directory=$1
    while [[ $directory != / ]]; do
        [[ ! -L $directory ]] || fail "Refusing a symbolic-link destination directory: $directory"
        [[ ! -e $directory || -d $directory ]] || fail "Not a directory: $directory"
        directory=${directory%/*}
        directory=${directory:-/}
    done
}

collect_managed_configuration() {
    local target first_line
    managed_configuration_files=()
    for target in "${ca_profile%/*}"/*.sh "${ca_systemd%/*}"/*.conf; do
        [[ -f $target && -r $target && ! -L $target ]] || continue
        first_line=''
        IFS= read -r first_line < "$target" || true
        if [[ $first_line == '# Managed by InstallCert' ]]; then
            managed_configuration_files+=("$target")
        fi
    done
}

remove_managed_configuration() {
    local target first_line
    for target in "${managed_configuration_files[@]}"; do
        if (( apply_vars )) && [[ $target == "$ca_profile" || $target == "$ca_systemd" ]]; then
            continue
        fi
        [[ -e $target || -L $target ]] || continue
        [[ -f $target && -r $target && ! -L $target ]] ||
            fail "Managed configuration changed during preflight: $target. Refusing removal."
        first_line=''
        IFS= read -r first_line < "$target" || true
        [[ $first_line == '# Managed by InstallCert' ]] ||
            fail "Configuration ownership changed during preflight: $target. Refusing removal."
        rm -f -- "$target"
        message "Removed installer configuration: $target"
    done
}

cleanup_removal() {
    if (( ${#removal_temporary_files[@]} > 0 )); then
        rm -f -- "${removal_temporary_files[@]}"
    fi
}

replace_contents() {
    local target=$1 contents=$2 temporary
    temporary=$(mktemp "${target%/*}/.installcert-remove.XXXXXXXX")
    removal_temporary_files+=("$temporary")
    cp --preserve=all -- "$target" "$temporary"
    printf '%s' "$contents" > "$temporary"
    mv -fT -- "$temporary" "$target"
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -F -- "$target"
    fi
}

remove_selected_actions() {
    local environment_file=$1 root source resolved certificate fingerprint original cleaned current
    local match_count=0
    local -a link_sources=() regular_sources=()
    local -A originals=() replacements=() der_sources=() deletions=() input_sources=()
    removal_thumbprints=()
    if (( remove_certs )); then
        for certificate in "${certificates[@]}"; do
            scan_certificate_file "$certificate"
            (( scan_count == 1 )) && [[ -z $scan_der ]] ||
                fail "Expected one PEM certificate per removal input: $certificate"
            removal_thumbprints["${scan_hashes[0]}"]=1
            resolved=$(readlink -f -- "$certificate")
            input_sources["$resolved"]=1
        done
        for root in "${removal_directories[@]}"; do
            [[ -e $root || -L $root ]] || continue
            check_directory_chain "$root"
            while IFS= read -r -d '' source; do
                [[ -n $source ]] || fail "Cannot read all trust-source entries under $root"
                [[ -f $source ]] || continue
                scan_certificate_file "$source"
                (( scan_matches > 0 )) || continue
                resolved=$(readlink -f -- "$source")
                [[ -z ${input_sources["$resolved"]+present} ]] ||
                    fail 'A removal input is also a trust source. Move the input directory outside the trust-source directories.'
                check_directory_chain "${source%/*}"
                originals["$source"]=$scan_original
                replacements["$source"]=$scan_contents
                der_sources["$source"]=$scan_der
                deletions["$source"]=$scan_delete
                if [[ -L $source ]]; then
                    link_sources+=("$source")
                else
                    regular_sources+=("$source")
                fi
                match_count=$((match_count + scan_matches))
                message "Match: $scan_matches certificate(s) in $source"
            done < <(find "$root" \( -type f -o -type l \) -print0 2>/dev/null || printf '\0')
        done
        message "Selected certificates: ${#removal_thumbprints[@]}" \
            "Matching certificates in trust sources: $match_count"
    fi

    original=''
    cleaned=''
    if (( remove_vars )); then
        check_directory_chain "${environment_file%/*}"
        check_directory_chain "${ca_profile%/*}"
        check_directory_chain "${ca_systemd%/*}"
        if [[ -e $environment_file ]]; then
            original=$(cat -- "$environment_file" && printf '\001')
            original=${original%$'\001'}
            cleaned=$(clean_environment "$environment_file" "$bundle" "$java_truststore" && printf '\001') ||
                fail 'Cannot safely clean complex JAVA_TOOL_OPTIONS. Remove the matching trust-store option manually, then retry variable removal. No changes made.'
            cleaned=${cleaned%$'\001'}
            if [[ $(printf '%s' "$cleaned") == $(printf '%s' "$original") ]]; then
                cleaned=$original
            fi
        fi
        message 'Environment cleanup includes matching entries and installer-owned profile and systemd files.'
    fi
    if (( validate_only )); then
        message 'Removal preflight passed. No changes made.'
        return
    fi
    (( EUID == 0 )) || fail 'Removal requires root. Rerun with sudo; automatic elevation is not performed.'

    if (( remove_certs )); then
        for source in "${link_sources[@]}" "${regular_sources[@]}"; do
            scan_certificate_file "$source"
            [[ $scan_original == "${originals["$source"]}" && $scan_der == "${der_sources["$source"]}" ]] ||
                fail "Trust source changed during preflight: $source. No changes made."
        done
    fi
    if (( remove_vars )) && [[ -e $environment_file ]]; then
        current=$(cat -- "$environment_file" && printf '\001')
        current=${current%$'\001'}
        [[ $current == "$original" ]] || fail 'Environment configuration changed during preflight. No changes made.'
    fi
    trap cleanup_removal EXIT
    if (( remove_certs )); then
        for source in "${link_sources[@]}" "${regular_sources[@]}"; do
            if (( ${deletions["$source"]} )); then
                rm -f -- "$source"
            else
                replace_contents "$source" "${replacements["$source"]}"
            fi
            message "Removed matching certificate data from: $source"
        done
        if ! "${removal_update_command[@]}" 2>&1 | fold -s -w 78; then
            fail 'Trust update failed after source changes. Retry the selected removal actions to finish rebuilding trust and cleanup.'
        fi
    fi
    if (( remove_vars )); then
        if [[ $cleaned != "$original" ]]; then
            replace_contents "$environment_file" "$cleaned"
        fi
        remove_managed_configuration
        message 'Installer environment settings removed; unrelated settings preserved.'
    fi
    if (( remove_certs )); then
        [[ -f $bundle && -r $bundle ]] ||
            fail 'Selected cleanup finished, but the rebuilt system CA bundle cannot be inspected.'
        scan_certificate_file "$bundle"
        (( scan_matches == 0 )) ||
            fail 'Selected cleanup finished, but selected certificates remain in the rebuilt CA bundle. Inspect other trust-policy sources; removal is incomplete.'
        message 'Matching certificates removed and system trust rebuilt.' \
            'The input certs directory was not changed.'
    fi
    if (( remove_vars )); then
        message 'Existing processes retain their environments. Start new sessions and restart affected applications yourself.' \
            'For system services, an administrator must reexecute systemd and restart affected services, or reboot.'
    fi
    message 'No backup directory was created. No services or service managers were restarted or reloaded.'
}

(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) ||
    fail 'Bash 4.4 or later is required.'
declare -A removal_thumbprints=()
removal_temporary_files=()
validate_only=0
remove_mode=0
remove_certs=0
remove_vars=0
apply_certs=0
apply_vars=0
(( $# > 0 )) || set -- --help
while (( $# > 0 )); do
case $1 in
    --validate-only) validate_only=1; shift ;;
    --removecerts) remove_certs=1; shift ;;
    --removevars) remove_vars=1; shift ;;
    --remove|--removeall) remove_certs=1; remove_vars=1; shift ;;
    --applycerts) apply_certs=1; shift ;;
    --applyvars) apply_vars=1; shift ;;
    --applyall) apply_certs=1; apply_vars=1; shift ;;
    --help|-h)
        message "Usage: bash \"${0##*/}\" [ACTION ...] [--validate-only]" \
            '' \
            'No arguments show this help only, even when running as root.' \
            '' \
            'Actions:' \
            '  --applycerts     Install certificates and rebuild system trust only.' \
            '  --applyvars      Configure CA environment defaults only.' \
            '  --applyall       Apply certificates and environment defaults.' \
            '  --removecerts    Remove certificates selected by certs/*.crt only.' \
            '  --removevars     Remove installer CA environment settings only.' \
            '  --removeall      Remove certificates and environment settings.' \
            '  --remove         Alias for --removeall.' \
            '' \
            'Options:' \
            '  --validate-only  Check the selected actions without changing files or trust.' \
            '  --help, -h       Show this help.' \
            '' \
            'Installation:' \
            'Nothing is installed unless an action is explicitly selected.' \
            '--applycerts copies certs/*.crt unchanged; it does not change environment settings.' \
            '--applyvars does not read certs or rebuild trust; existing readable PEM and Java stores are required.' \
            'Environment defaults require running systemd and distribution Java CA integration.' \
            'Use --applycerts --applyvars together, or --applyall, to apply both.' \
            'Removal actions cannot be combined with apply actions.' \
            '' \
            'Removal:' \
            'Use --removecerts --removevars together, or --removeall, to remove both.' \
            '--removecerts does not inspect or change environment configuration.' \
            '--removevars does not read certs or rebuild trust; OpenSSL is not required.' \
            'Matches SHA-256 certificate thumbprints, not filenames or file hashes.' \
            'Metadata before PEM headers and different PEM formatting do not change certificate identity.' \
            'Removes matching local and vendor CA sources, even if installed by another tool.' \
            'Mixed PEM files keep unrelated certificates. The input certs directory is unchanged.' \
            'Certificate removal requires OpenSSL; no backup or state directory is created.' \
            'Does not scan private application stores or p11-kit policy files.' \
            'Package updates may restore vendor certificates. Historical settings cannot be restored.' \
            '' \
            'Client trust behavior:' \
            'REQUESTS_CA_BUNDLE and CURL_CA_BUNDLE replace the default CA bundle for clients that honor them.' \
            'SSL_CERT_FILE overrides the default CA-file path; other trust sources depend on the client.' \
            'NODE_EXTRA_CA_CERTS adds to Node defaults, but explicit TLS ca options bypass them.' \
            'JAVA_TOOL_OPTIONS selects the OS Java truststore instead of JVM/application default cacerts.' \
            'Replacement can remove application-specific CAs and trust policies, including in bundled runtimes.' \
            'Existing simple JVM options are preserved; conflicting trustStore options or complex quoting are rejected.' \
            'JVM options in /etc/environment and the invoking environment must agree when both are set.' \
            '' \
            'Environment inheritance:' \
            'Variables apply only where inherited and honored. Restart processes; sudo, cron, units, and apps can override them.' \
            'No runtime installations, proxy changes, TLS verification bypasses, or automatic service restarts.'
        exit 0 ;;
    *) fail 'Unknown argument. Use --help.' ;;
esac
done
remove_mode=$((remove_certs || remove_vars))
if (( remove_mode && (apply_certs || apply_vars) )); then
    fail 'Removal actions cannot be combined with --applycerts, --applyvars, or --applyall.'
fi
(( remove_mode || apply_certs || apply_vars )) ||
    fail 'Select an apply or removal action. Use --help for usage.'
[[ $(uname -s) == Linux ]] || fail 'Run this script on Linux.'

for utility in cp chmod mkdir dirname awk mktemp mv rm; do
    command -v "$utility" >/dev/null 2>&1 || fail "Missing required utility: $utility"
done
if (( remove_certs )); then
    for utility in openssl find grep readlink; do
        command -v "$utility" >/dev/null 2>&1 || fail "Missing required utility: $utility"
    done
fi
if (( remove_vars )); then
    command -v cat >/dev/null 2>&1 || fail 'Missing required utility: cat'
fi

[[ -r /etc/os-release ]] || fail 'Missing /etc/os-release.'
os_name=$(awk -F= '/^PRETTY_NAME=/ { value = substr($0, index($0, "=") + 1); gsub(/["\047]/, "", value); print value }' /etc/os-release)
message "Detected OS: ${os_name:-Linux}"
os_family=$(awk -F= '/^(ID|ID_LIKE)=/ { gsub(/["\047]/, "", $2); printf " %s ", $2 }' /etc/os-release)
case $os_family in
    *' debian '*|*' ubuntu '*|*' linuxmint '*)
        trust_directory=/usr/local/share/ca-certificates
        bundle=/etc/ssl/certs/ca-certificates.crt
        java_truststore=/etc/ssl/certs/java/cacerts
        removal_directories=(/usr/local/share/ca-certificates /usr/share/ca-certificates)
        removal_update_command=(update-ca-certificates --fresh)
        update_command=(update-ca-certificates) ;;
    *' rhel '*|*' fedora '*|*' centos '*|*' rocky '*|*' almalinux '*)
        trust_directory=/etc/pki/ca-trust/source/anchors
        bundle=/etc/pki/tls/certs/ca-bundle.crt
        java_truststore=/etc/pki/java/cacerts
        removal_directories=(/etc/pki/ca-trust/source/anchors /usr/share/pki/ca-trust-source/anchors)
        removal_update_command=(update-ca-trust extract)
        update_command=(update-ca-trust extract) ;;
    *) fail 'Unsupported OS family; expected Debian/Ubuntu/Mint or RHEL/Rocky/AlmaLinux/Fedora.' ;;
esac
if (( apply_certs || remove_certs )); then
    command -v "${update_command[0]}" >/dev/null 2>&1 || fail "Missing ${update_command[0]}; install the distribution ca-certificates package."
fi
if (( apply_vars )); then
    [[ -d /run/systemd/system ]] || fail 'A running systemd system is required for system-service environment defaults.'
fi

certificates=()
if (( apply_certs || remove_certs )); then
    script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    shopt -s nullglob
    certificates=("$script_directory"/certs/*.crt)
    (( ${#certificates[@]} > 0 )) || fail 'No certs/*.crt files found beside the script. Use .crt filenames for PEM CA certificates.'
    [[ ! -L $trust_directory ]] || fail 'The certificate destination must not be a symbolic link.'
    for certificate in "${certificates[@]}"; do
        [[ -f $certificate && -r $certificate && ! -L $certificate ]] || fail "Not a readable regular certificate file: $certificate"
        (( remove_certs )) && continue
        destination=$trust_directory/${certificate##*/}
        [[ ! -L $destination ]] || fail 'A certificate destination is a symbolic link.'
        [[ ! -e $destination || -f $destination ]] || fail "Not a regular destination file: $destination"
    done
fi

configuration_name=${0##*/}
configuration_name=${configuration_name%.sh}
ca_profile=/etc/profile.d/$configuration_name.sh
ca_systemd=/etc/systemd/system.conf.d/$configuration_name.conf
if (( apply_vars || remove_vars )); then
    if (( apply_vars )); then
        [[ -n $configuration_name && $configuration_name != .* && $configuration_name != *$'\n'* && $configuration_name != *$'\r'* ]] ||
            fail 'Use a nonempty script basename that does not start with a dot or contain line breaks for environment application.'
    fi
    for target in "$ca_profile" "$ca_systemd"; do
        check_directory_chain "${target%/*}"
        [[ ! -L $target ]] || fail "Refusing a symbolic link at $target"
        if [[ -e $target ]]; then
            [[ -f $target ]] || fail "Not a regular file: $target"
            IFS= read -r first_line < "$target" || true
            [[ ${first_line:-} == '# Managed by InstallCert' ]] || fail "Refusing to overwrite an unowned file: $target"
        fi
    done
    [[ ! -L /etc/environment && ( ! -e /etc/environment || -f /etc/environment ) ]] || fail '/etc/environment must be a regular file, not a symbolic link.'
    collect_managed_configuration
fi

if (( remove_mode )); then
    remove_selected_actions /etc/environment
    exit 0
fi

if (( apply_vars )); then
    if (( ! apply_certs )); then
        [[ -f $bundle && -s $bundle && -r $bundle ]] || fail "Missing readable system PEM bundle: $bundle. Update system trust before applying environment defaults. No system changes made."
    fi
    [[ -f $java_truststore && -s $java_truststore && -r $java_truststore ]] || fail "Missing readable Java truststore: $java_truststore. Enable distribution Java CA integration (ca-certificates-java on Debian/Ubuntu), then rerun. No system changes made."
    java_options=${JAVA_TOOL_OPTIONS:-}
    if [[ -f /etc/environment ]]; then
        saved_java_options=$(awk '/^[[:space:]]*(export[[:space:]]+)?JAVA_TOOL_OPTIONS[[:space:]]*=/ { sub(/^[[:space:]]*(export[[:space:]]+)?JAVA_TOOL_OPTIONS[[:space:]]*=[[:space:]]*/, ""); print }' /etc/environment)
        case $saved_java_options in
            \"*\") saved_java_options=${saved_java_options:1:${#saved_java_options}-2} ;;
            \'*\') saved_java_options=${saved_java_options:1:${#saved_java_options}-2} ;;
        esac
        if [[ -n $saved_java_options ]]; then
            saved_java_options=$(merge_java_options "$saved_java_options" "$java_truststore")
            if [[ -n $java_options ]]; then
                [[ $(merge_java_options "$java_options" "$java_truststore") == "$saved_java_options" ]] || fail 'JAVA_TOOL_OPTIONS differs between /etc/environment and this process; reconcile the options before installation.'
            fi
            java_options=$saved_java_options
        fi
    fi
    java_options=$(merge_java_options "$java_options" "$java_truststore")
fi

if (( validate_only )); then
    if (( apply_certs )); then
        message "Certificate preflight passed: ${#certificates[@]} .crt file(s)." \
            "Destination: $trust_directory" 'Certificate contents were not validated.'
    fi
    if (( apply_vars )); then
        message 'Environment preflight passed.' "Profile: $ca_profile" \
            "Systemd drop-in: $ca_systemd" "PEM bundle: $bundle" "Java store: $java_truststore"
    fi
    message 'No changes made.'
    exit 0
fi
(( EUID == 0 )) || fail 'Applying the selected actions requires root. Rerun with sudo; automatic elevation is not performed.'

if (( apply_certs )); then
    mkdir -p -m 0755 -- "$trust_directory"
    for certificate in "${certificates[@]}"; do
        cp -f -- "$certificate" "$trust_directory/${certificate##*/}"
        chmod 0644 -- "$trust_directory/${certificate##*/}"
    done
    if command -v restorecon >/dev/null 2>&1; then
        for certificate in "${certificates[@]}"; do
            restorecon -F -- "$trust_directory/${certificate##*/}"
        done
    fi
    "${update_command[@]}" 2>&1 | fold -s -w 78
    [[ -s $bundle && -r $bundle ]] || fail 'The trust updater did not produce the expected readable system CA bundle.'
    message 'Certificates copied and system trust rebuilt.'
fi
(( apply_vars )) || exit 0
[[ -f $java_truststore && -s $java_truststore && -r $java_truststore ]] || fail 'The trust updater did not leave a readable Java truststore. CA environment settings were not changed.'

temporary=$(mktemp /etc/.installcert-environment.XXXXXXXX)
trap 'rm -f -- "$temporary"' EXIT
if [[ -f /etc/environment ]]; then
    cp --preserve=all -- /etc/environment "$temporary"
    awk '!/^[[:space:]]*(export[[:space:]]+)?(REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE|SSL_CERT_FILE|NODE_EXTRA_CA_CERTS|JAVA_TOOL_OPTIONS)[[:space:]]*=/' /etc/environment > "$temporary"
else
    chmod 0644 "$temporary"
fi
for name in REQUESTS_CA_BUNDLE CURL_CA_BUNDLE SSL_CERT_FILE NODE_EXTRA_CA_CERTS; do
    printf '%s="%s"\n' "$name" "$bundle" >> "$temporary"
done
printf 'JAVA_TOOL_OPTIONS="%s"\n' "$java_options" >> "$temporary"
mv -f -- "$temporary" /etc/environment

mkdir -p -m 0755 -- /etc/profile.d /etc/systemd/system.conf.d
printf '# Managed by InstallCert\n' > "$ca_profile"
for name in REQUESTS_CA_BUNDLE CURL_CA_BUNDLE SSL_CERT_FILE NODE_EXTRA_CA_CERTS; do
    printf 'export %s="%s"\n' "$name" "$bundle" >> "$ca_profile"
done
printf 'if [ "${JAVA_TOOL_OPTIONS+x}" != x ]; then\n    export JAVA_TOOL_OPTIONS="%s"\nelse\n    case " $JAVA_TOOL_OPTIONS " in\n        *" -Djavax.net.ssl.trustStore="*) ;;\n        *) export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Djavax.net.ssl.trustStore=%s" ;;\n    esac\nfi\n' \
    "$java_options" "$java_truststore" >> "$ca_profile"
printf '# Managed by InstallCert\n[Manager]\nDefaultEnvironment="REQUESTS_CA_BUNDLE=%s" "CURL_CA_BUNDLE=%s" "SSL_CERT_FILE=%s" "NODE_EXTRA_CA_CERTS=%s" "JAVA_TOOL_OPTIONS=%s"\n' \
    "$bundle" "$bundle" "$bundle" "$bundle" "${java_options//%/%%}" > "$ca_systemd"
chmod 0644 -- "$ca_profile" "$ca_systemd"
if command -v restorecon >/dev/null 2>&1; then
    restorecon -F -- /etc/environment "$ca_profile" "$ca_systemd"
fi
remove_managed_configuration

message \
    'CA defaults configured for PAM sessions, login shells, and system services.' \
    "Profile: $ca_profile" "Systemd drop-in: $ca_systemd" \
    'Java and PEM bundle overrides can replace application-specific trust. Use --help for consequences and exceptions.' \
    'Log in again and restart affected applications. For services, run systemctl daemon-reexec and restart affected services, or reboot.' \
    'Sudo, cron, user service managers, containers, and applications may need their own environment configuration. No services were restarted.'
 