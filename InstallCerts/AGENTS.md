# InstallCerts Agent Guidelines

## Purpose and Current State

- Maintain a Bash installer for trusted CA certificates on Debian and RHEL Linux families, with environment defaults pointing supported clients to the updated trust stores.
- See [README.md](README.md) for usage, supported environments, limitations, and validation commands. There is currently no automated test suite. Keep implementation focused on shell scripts; do not introduce an application framework.
- Derive help, the `# Managed by {scriptname}` ownership marker, and generated profile `.sh` and systemd `.conf` basenames from the current invocation name, stripping only a final `.sh` suffix. Recognize only the current name's marker; users must remove variables under the old name before renaming an installed copy. Preserve other names' markers, unmarked files, and symlink targets; certificate-only actions must not discover or change environment files.
- No arguments must show help only, regardless of privileges. Require an explicit apply or removal action; `--validate-only` must accompany an action. Reject combinations of removal and apply actions. See [README.md](README.md) for all switches.
- Keep certificate and variable application independent: `--applycerts` must not inspect or change environment configuration or require Java/systemd; `--applyvars` must not read certificate inputs or invoke or require the trust updater. Both switches together must behave like `--applyall`, completing all preflight checks before changes.
- Keep removal independent: `--removecerts` must not inspect or change environment configuration; `--removevars` must not read certificate inputs, inspect trust stores, or require OpenSSL or the trust updater. Both switches together must behave like `--removeall`, completing all preflight checks before changes.
- Variable application requires distribution Java trust-store integration, readable trust stores, and a running systemd instance. Certificate-only application and removal do not require these runtime prerequisites. Do not silently install or enable them or reload or restart service managers.
- Keep user-facing output within 78 columns for 80-column consoles, and report the detected OS before operational preflight checks. Never wrap certificate bytes or generated configuration.
- Certificate removal intentionally removes matching certificates regardless of installation provenance. Match decoded X.509 SHA-256 thumbprints, not filenames or file hashes; preserve unrelated certificates and leave input files unchanged. See [README.md](README.md) for source-directory coverage and limitations.
- Removal must not create persistent state or backup directories. Variable removal must preserve unrelated settings, removing only matching environment values and the matching Java trust-store token. Certificate removal must verify selected certificates are absent from the rebuilt PEM bundle before reporting success.

## Certificate and Shell Conventions

- Discover `certs/*.crt` relative to the script's location, not the caller's working directory. Handle spaces in paths, empty matches, unreadable inputs, and symbolic-link destinations explicitly.
- Expect PEM/base64-encoded CA certificates, one certificate per file; an extension alone does not establish encoding or CA suitability. Copy accepted certificates without changing their bytes.
- Use Bash, quoted expansions, arrays for file lists and commands, and deliberate error handling under `set -euo pipefail`.
- Check prerequisites before changing system state. Reject unsupported distributions clearly; do not silently install packages or elevate privileges.
- Make repeated runs idempotent. Preserve unrelated environment settings and JVM options, reject conflicting trust-store settings, and avoid overwriting unowned configuration files.

## Linux Trust Stores

- Detect the family using `ID` and `ID_LIKE` in `/etc/os-release`; check the required trust-update utility before installation.
- Use the distribution's trust updater rather than editing generated bundles directly:

| Family                      | CA Anchor Directory                  | Trust Update                | PEM Bundle                             |
| --------------------------- | ------------------------------------ | --------------------------- | -------------------------------------- |
| Debian/Ubuntu               | `/usr/local/share/ca-certificates` | `update-ca-certificates`  | `/etc/ssl/certs/ca-certificates.crt` |
| RHEL/Fedora and derivatives | `/etc/pki/ca-trust/source/anchors` | `update-ca-trust extract` | `/etc/pki/tls/certs/ca-bundle.crt`   |

- Preserve system trust and TLS verification. Do not introduce insecure client flags, proxy changes, or automatic service restarts.

## Environment Semantics

- Consider `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, and `SSL_CERT_FILE` for clients that honor them. Explain that overrides may replace client-specific defaults rather than extend them.
- `NODE_EXTRA_CA_CERTS` adds certificates to Node defaults at process startup; explicit application TLS `ca` settings can bypass it.
- Java requires a Java-format trust store, not the PEM bundle. Verify distribution integration and the readable OS-generated store, typically `/etc/ssl/certs/java/cacerts` on Debian or `/etc/pki/java/cacerts` on RHEL. Do not clobber unrelated `JAVA_TOOL_OPTIONS` or evaluate its contents as shell code.
- Distinguish PAM environments, login-shell profiles, and service-manager defaults. No file or environment variable reaches every application; existing processes need new environments, and sudo, cron, containers, and applications can override inheritance.

## Safe Validation

- The installer targets Linux. Use a real Bash environment for shell checks, and report missing tools rather than claiming validation passed. When development is hosted on Windows/PowerShell, prefer WSL when available.
- Run `bash -n <script>` after each new or repaired script, then `shellcheck <script>` when available. See [README.md](README.md) for current validation commands; never use installation as a syntax check or source the top-level installer as a test helper.
- Keep `--validate-only` strictly read-only for every selected action: it must not create temporary files, copy or remove certificates, update trust, write configuration, or restart anything.
- Test installation only with explicit authorization in disposable Debian-family and RHEL-family Linux systems, never against the development host's trust store. Check repeated runs, invocation from another directory, filenames with spaces, missing or malformed inputs, and preservation of existing configuration.
- Separate syntax/lint results from installation evidence. Containers do not prove PAM, login-shell, or systemd environment propagation; test those contexts separately when supported.
