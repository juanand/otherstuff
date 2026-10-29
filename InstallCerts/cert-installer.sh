#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'Error: %s\n' "$1" >&2
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

validate_only=0
case ${1:-} in
    --validate-only) validate_only=1; shift ;;
    --help|-h)
        printf '%s\n' 'Usage: bash install-certificates.sh [--validate-only]' \
            'Copies certs/*.crt unchanged, rebuilds system trust, and configures CA environment defaults.' \
            'Java requires a readable OS-generated truststore; Debian/Ubuntu need enabled ca-certificates-java integration.' \
            'REQUESTS_CA_BUNDLE and CURL_CA_BUNDLE replace the default CA bundle for clients that honor them.' \
            'SSL_CERT_FILE overrides the default CA-file path; other trust sources depend on the client.' \
            'NODE_EXTRA_CA_CERTS adds to Node defaults, but explicit TLS ca options bypass them.' \
            'JAVA_TOOL_OPTIONS selects the OS Java truststore instead of JVM/application default cacerts.' \
            'Replacement can remove application-specific CAs and trust policies, including in bundled runtimes.' \
            'Existing simple JVM options are preserved; conflicting trustStore options or complex quoting are rejected.' \
            'JVM options in /etc/environment and the invoking environment must agree when both are set.' \
            'Variables apply only where inherited and honored. Restart processes; sudo, cron, units, and apps can override them.' \
            'No runtime installations, proxy changes, TLS verification bypasses, or automatic service restarts.'
        exit 0 ;;
esac
(( $# == 0 )) || fail 'Unknown argument. Use --help.'
[[ $(uname -s) == Linux ]] || fail 'Run this script on Linux.'

for utility in cp chmod mkdir dirname awk mktemp mv rm; do
    command -v "$utility" >/dev/null 2>&1 || fail "Missing required utility: $utility"
done

[[ -r /etc/os-release ]] || fail 'Missing /etc/os-release.'
os_family=$(awk -F= '/^(ID|ID_LIKE)=/ { gsub(/["\047]/, "", $2); printf " %s ", $2 }' /etc/os-release)
case $os_family in
    *' debian '*|*' ubuntu '*|*' linuxmint '*)
        trust_directory=/usr/local/share/ca-certificates
        bundle=/etc/ssl/certs/ca-certificates.crt
        java_truststore=/etc/ssl/certs/java/cacerts
        update_command=(update-ca-certificates) ;;
    *' rhel '*|*' fedora '*|*' centos '*|*' rocky '*|*' almalinux '*)
        trust_directory=/etc/pki/ca-trust/source/anchors
        bundle=/etc/pki/tls/certs/ca-bundle.crt
        java_truststore=/etc/pki/java/cacerts
        update_command=(update-ca-trust extract) ;;
    *) fail 'Unsupported OS family; expected Debian/Ubuntu/Mint or RHEL/Rocky/AlmaLinux/Fedora.' ;;
esac
command -v "${update_command[0]}" >/dev/null 2>&1 || fail "Missing ${update_command[0]}; install the distribution ca-certificates package."
[[ -d /run/systemd/system ]] || fail 'A running systemd system is required for system-service environment defaults.'

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
shopt -s nullglob
certificates=("$script_directory"/certs/*.crt)
(( ${#certificates[@]} > 0 )) || fail 'No certs/*.crt files found beside the script. Use .crt filenames for PEM CA certificates.'
[[ ! -L $trust_directory ]] || fail 'The certificate destination must not be a symbolic link.'
for certificate in "${certificates[@]}"; do
    [[ -f $certificate && ! -L $certificate ]] || fail "Not a regular certificate file: $certificate"
    destination=$trust_directory/${certificate##*/}
    [[ ! -L $destination ]] || fail 'A certificate destination is a symbolic link.'
    [[ ! -e $destination || -f $destination ]] || fail "Not a regular destination file: $destination"
done

ca_profile=/etc/profile.d/installcert-ca.sh
ca_systemd=/etc/systemd/system.conf.d/90-installcert-ca.conf
for target in "$ca_profile" "$ca_systemd"; do
    [[ ! -L $target ]] || fail "Refusing a symbolic link at $target"
    if [[ -e $target ]]; then
        [[ -f $target ]] || fail "Not a regular file: $target"
        IFS= read -r first_line < "$target" || true
        [[ ${first_line:-} == '# Managed by InstallCert' ]] || fail "Refusing to overwrite an unowned file: $target"
    fi
done
[[ ! -L /etc/environment && ( ! -e /etc/environment || -f /etc/environment ) ]] || fail '/etc/environment must be a regular file, not a symbolic link.'

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

if (( validate_only )); then
    printf 'Preflight passed: %s .crt file(s); destination: %s; Java store: %s. Certificate contents were not validated. No changes made.\n' "${#certificates[@]}" "$trust_directory" "$java_truststore"
    exit 0
fi
(( EUID == 0 )) || fail 'Run as root, for example with sudo. Automatic elevation is not performed.'

mkdir -p -m 0755 -- "$trust_directory"
for certificate in "${certificates[@]}"; do
    cp -f -- "$certificate" "$trust_directory/${certificate##*/}"
    chmod 0644 -- "$trust_directory/${certificate##*/}"
done
"${update_command[@]}"
[[ -s $bundle && -r $bundle ]] || fail 'The trust updater did not produce the expected readable system CA bundle.'
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
    for certificate in "${certificates[@]}"; do restorecon -F -- "$trust_directory/${certificate##*/}"; done
fi

printf '%s\n' \
    'Certificates copied and system trust rebuilt.' \
    'CA defaults configured for PAM sessions, login shells, and system services.' \
    'Java and PEM bundle overrides can replace application-specific trust. Use --help for consequences and exceptions.' \
    'Log in again and restart affected applications. For services, run systemctl daemon-reexec and restart affected services, or reboot.' \
    'Sudo, cron, user service managers, containers, and applications may need their own environment configuration. No services were restarted.'
 