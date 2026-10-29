# Install and Remove Trusted CA Certificates

This vibe-coded script explicitly applies or removes local CA certificates, CA environment defaults, or both on Debian/Ubuntu and RHEL/Fedora systems from relative `./certs` folder. Without parameters it only displays help, including when run with sudo. Certificate removal matches certificate thumbprints without requiring installation records or a backup directory.

## Requirements

- Linux with Bash 4.4 or later and standard GNU utilities including `fold`.
- `--applycerts` and certificate-removal actions require the distribution's `ca-certificates` package and trust-update command. Certificate removal additionally requires OpenSSL. These actions do not require a running systemd instance or a readable Java store.
- `--applyvars` requires a running systemd instance and readable existing system PEM and distribution-generated Java trust stores. The Java store is `/etc/ssl/certs/java/cacerts` on Debian-family systems or `/etc/pki/java/cacerts` on RHEL-family systems; Debian/Ubuntu require enabled `ca-certificates-java` integration. This action does not require a trust-update command or certificate input directory. `--applyall` combines both sets of requirements.
- `--removevars` only needs readable environment configuration; it does not require certificate inputs, OpenSSL, a trust updater, existing trust stores, or a running systemd instance. Combined removal actions use both removal preflights.
- Root privileges to apply or remove anything. Read-only validation does not require root if the files needed by the selected action are readable. Help does not require root.
- Certificate application and removal require one PEM/base64-encoded CA certificate per lowercase `.crt` file in a `certs` directory beside the script. Input symlinks are rejected. Removal parses certificates; application still does not validate certificate contents, CA suitability, or expiration.

Only install CAs you have independently verified, including their encoding, CA suitability, validity dates, and issuer. Installation changes trust system-wide.

## Usage

Choose an explicit action. Create the adjacent `certs` directory only when applying or removing certificates; filenames and directory paths may contain spaces.

Replace `{scriptname}` in the examples with your chosen script basename, without a final `.sh` suffix. The examples assume the script has that suffix; omit it from the commands if your script is extensionless.

```bash
bash "./{scriptname}.sh"
bash "./{scriptname}.sh" --help
bash "./{scriptname}.sh" --applycerts --validate-only
sudo bash "./{scriptname}.sh" --applycerts
sudo bash "./{scriptname}.sh" --applyvars
sudo bash "./{scriptname}.sh" --applycerts --applyvars
sudo bash "./{scriptname}.sh" --applyall
bash "./{scriptname}.sh" --removecerts --validate-only
sudo bash "./{scriptname}.sh" --removecerts
bash "./{scriptname}.sh" --removevars --validate-only
sudo bash "./{scriptname}.sh" --removevars
bash "./{scriptname}.sh" --removeall --validate-only
sudo bash "./{scriptname}.sh" --removeall
```

`--applycerts` copies certificates and rebuilds trust without changing environment configuration. `--applyvars` configures environment defaults against existing trust stores without reading certificate inputs or invoking the trust updater. Use both switches, in either order, or `--applyall` to do both. Both preflights complete before any changes when combined. Removal actions cannot be combined with apply actions.

No arguments, with or without sudo, show help and make no changes. `--validate-only` must accompany an action; on its own it reports a usage error and never assumes installation.

Choose the script name before first applying environment variables. Help, ownership markers, and generated configuration filenames use its current invocation name, and certificate discovery uses the script's containing directory, not the current working directory. Invoke the script directly rather than through a symbolic link so it finds the intended `certs` directory. Environment application requires a nonempty basename that does not start with a dot or contain line breaks; spaces are supported.

Operational runs report the detected OS before checking distribution-specific prerequisites. Help, status messages, errors, and displayed trust-updater output wrap at 78 columns to fit an 80-column console. Generated configuration and certificate bytes are not wrapped. Help does not require OS detection.

Application validation checks only the prerequisites and paths needed by the selected actions. Certificate-only validation does not inspect environment files, Java options, or systemd. Variable-only validation does not read certificate inputs or check the trust updater. Validation does not inspect certificate contents for application, prove write permissions, or exercise the trust updater. Removal validation parses certificates and reports matching sources only when certificate removal is selected, and checks environment cleanup only when variable removal is selected. All validation modes avoid temporary files and changes to trust or configuration.

Installation copies certificate bytes unchanged and invokes `update-ca-certificates` on Debian-family systems or `update-ca-trust extract` on RHEL-family systems. Existing anchors with matching filenames are overwritten, so choose names carefully. Previously installed certificates absent from `certs` are not automatically removed.

## Removal Actions

- `--removecerts` removes matching certificates and rebuilds trust without inspecting or changing environment configuration.
- `--removevars` removes installer environment settings without reading certificates or inspecting or rebuilding trust.
- `--removeall` removes both.

Combining `--removecerts --removevars`, in either order, is equivalent to `--removeall`; both preflights complete before changes. Add `--validate-only` to any removal selection to preview it without changes.

Certificate removal uses `certs/*.crt` as the removal list, not as files to delete. It compares SHA-256 thumbprints of decoded X.509 certificate data, not file hashes or filenames. Metadata before the PEM header, PEM formatting, and line endings do not affect certificate identity. The input directory is left unchanged. Variable-only removal does not need this directory.

Matching certificates are removed regardless of installer or ownership, including pre-existing and vendor-provided certificates in these source directories:

| Family        | Local Sources                        | Vendor Sources                             |
| ------------- | ------------------------------------ | ------------------------------------------ |
| Debian/Ubuntu | `/usr/local/share/ca-certificates` | `/usr/share/ca-certificates`             |
| RHEL/Fedora   | `/etc/pki/ca-trust/source/anchors` | `/usr/share/pki/ca-trust-source/anchors` |

Files are scanned recursively regardless of extension. PEM, trusted PEM, and single-certificate DER sources are supported. Mixed PEM files retain unrelated certificates and other PEM blocks. A source containing only selected certificates and surrounding metadata is deleted. Directory symlinks are not traversed; matching file symlinks are removed or replaced locally without modifying their external targets. Inputs must be outside these source directories.

After certificate removal, the script rebuilds trust with `update-ca-certificates --fresh` or `update-ca-trust extract`. Environment settings are cleaned up only when variable removal is selected. Certificate removal checks the resulting system PEM bundle and returns an error if selected certificates remain trusted through another source; variable-only removal never reads this bundle. Generated bundles are never edited directly. No persistent state or backup directory is created; temporary replacement files are cleaned up on exit.

This is removal, not restoration of historical state. It cannot restore overwritten certificates or old environment values. Package updates can reinstall vendor certificates. Private application stores, separately maintained Java stores, and p11-kit policy files are not scanned. If a selected certificate remains in the rebuilt bundle, inspect those other trust-policy sources. Failures after source files have changed are not automatically rolled back; resolve the reported problem and rerun the selected removal actions to finish cleanup.

## Environment Defaults

Environment defaults are opt-in through `--applyvars`, `--applyall`, or the combined apply switches. Certificate-only application does not create, modify, or remove environment configuration. When selected, the script preserves unrelated settings in `/etc/environment` and creates `/etc/profile.d/{scriptname}.sh` and `/etc/systemd/system.conf.d/{scriptname}.conf`, where `{scriptname}` is the invoked script basename with its final `.sh` suffix removed, if present. It replaces the managed CA-variable assignments and refuses to overwrite unowned managed configuration files or symbolic-link destination files. Repeated runs do not duplicate environment entries.

Both generated files start with `# Managed by {scriptname}`. Variable actions recognize only the marker matching the current script basename. Files with another name's marker, unrelated files, and file symlinks are not removed. `--validate-only` never migrates or deletes files, and certificate-only actions never perform this discovery.

Before renaming a script whose variables have already been applied, run `--removevars` using the old name, then rename it and reapply variables under the new name. A renamed script does not recognize the old name's marker or automatically migrate its files. The marker scopes profile and drop-in ownership only; `/etc/environment` remains shared and is cleaned up by matching values.

These variables point to the distribution's updated PEM bundle:

- `REQUESTS_CA_BUNDLE` and `CURL_CA_BUNDLE` select a CA bundle for clients that honor them, potentially replacing client-specific trust.
- `SSL_CERT_FILE` selects a CA file for supporting TLS clients; other trust sources depend on the client.
- `NODE_EXTRA_CA_CERTS` extends Node's built-in defaults at process startup. Explicit application TLS `ca` settings can bypass it.

The login profile exports the four CA-bundle variables even when they are already set. Log in again and restart affected applications yourself to inherit new settings. `/etc/environment` depends on the session's PAM configuration; services, sudo, cron, containers, and individual applications may need separate environment configuration. A child process cannot change the calling shell's environment.

The script adds the OS-generated Java trust store to `JAVA_TOOL_OPTIONS`, preserving supported simple JVM options and rejecting conflicting trust-store options or complex quoting during preflight. It also writes systemd manager environment defaults. These defaults need an administrator-managed daemon reexecution and service restarts, or a reboot, to take effect; unit-specific settings can override them. The script does not install packages, elevate itself, change proxy settings, disable TLS verification, or restart services.

Variable removal (`--removevars` or combined removal) deletes discovered profiles and systemd drop-ins only when their ownership marker matches the current script basename. In `/etc/environment`, it removes the four CA-variable assignments only when their values match the configured system PEM bundle. It removes only the matching `-Djavax.net.ssl.trustStore=...` token from `JAVA_TOOL_OPTIONS`, keeping unrelated simple JVM options; an emptied assignment is removed. Unrelated environment entries, comments, and custom CA paths are retained. Cleanup refuses complex JVM quoting containing the matching option rather than evaluating or damaging it; remove that option manually and rerun in that case.

Variable removal does not unset variables already inherited by running processes or reload systemd. New sessions and administrator-managed application/service restarts or a reboot are still required.

## Development Checks

Run checks in a real Bash environment, such as Linux or WSL:

```bash
bash -n "./{scriptname}.sh"
shellcheck "./{scriptname}.sh"
```

Run ShellCheck only when installed and report its absence otherwise. There is currently no automated test suite. Do not source the installer for tests: it executes at top level.

Temporary-fixture checks cover certificate parsing and filtering, environment cleanup, independent application and removal preflights, combined removal selections, output width, script-derived configuration paths and markers, instance-specific ownership and cleanup, and safe file replacement. No-argument help has been checked under both a normal user and Linux root. Actual application and removal against Debian-family and RHEL-family system stores have not been exercised. These tests require explicit authorization and disposable Linux systems. Syntax and fixture checks do not prove trust-updater integration, PAM behavior, login-session propagation, or service inheritance.
