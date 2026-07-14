# Changelog

## 2026-07-14

### Added

- Documented the single universal POSIX `install.sh` located at the root of
  `Telemtinstall/telemt2`. It detects the OS and existing install, offers
  Install or Update, refreshes `telemt2` with `git pull --ff-only`, and invokes
  this canonical Docker installer when Docker is the compatible route.
- Added `update-with-system-ca.sh`, a separate compatibility wrapper for Docker Telemt servers with a manually installed OpenSSL whose compiled default trust path does not use the operating system CA bundle.
- The wrapper compares default and explicit-CA TLS verification and refuses to hide real certificate-chain failures. It is check-only by default; `--run-update` explicitly invokes the existing updater with `SSL_CERT_FILE`/`CURL_CA_BUNDLE` after refusing a possible Telemt version downgrade.
- The wrapper does not patch the Docker installer at runtime. It does not edit certificates, nginx configuration, Telemt configuration, users, or secrets; after validation it invokes the normal documented `--update` behavior.
- Added Ubuntu host nginx/OpenSSL validation to fresh install, `--update`, and `--fix-nginx`. The installer checks both the nginx command and the service binary, then builds isolated nginx `1.31.2` with pinned OpenSSL `3.5.7` when the host stack is too old.

### Changed

- Updated the exact checked compatible Telemt target and example image tag to `3.4.23`.
- Docker OS validation now accepts Debian 13.x or Ubuntu 24.x-26.x and stops before installation on other versions.
- Ubuntu support is Docker-only. The host nginx fallback does not replace system OpenSSL shared libraries, while Debian 13 keeps the existing distro-nginx path.

### Fixed

- Fixed `mawk` warnings about the `general.links` section escape in `telemt-users links`; Debian and Ubuntu now regenerate links without OS-specific warning noise.

## 2026-07-07

### Changed

- Added explicit README command blocks for updating Docker Telemt `3.4.18` to the checked compatible `3.4.22` release from a `telemt2` checkout, including a no-change dry-run plan and post-update checks.
- Public IPv4 detection now prefers a DNS A record that matches one of the server's local IPv4 addresses before falling back to external egress-IP services. This keeps update plans correct on servers whose outbound traffic leaves through a different VPN/WireGuard IP.

### Fixed

- Made `telemt-users` user parsing compatible with `mawk` on older Debian systems by avoiding interval regex syntax in the 32-hex secret check.
- Made Docker installer secret parsing compatible with `mawk` too, so link regeneration and existing-secret loading use the same portable 32-hex check without OS-specific branches or notices.

## 2026-07-06

### Changed

- Updated the checked compatible Telemt target to `3.4.22`.
- Fresh installs and `--update` now add `client_mss_bulk = "1400"` for Telemt `3.4.19+` when MSS is enabled.
- `--update` now reports missing `server.client_mss_bulk` and patches existing `telemt.toml` without overwriting manual values.
- Synlimit V2 fields are written when `TELEMT_SYNLIMIT=nftables|iptables`; SYN limiter remains disabled by default in the Docker/nginx-stream layout.

### Fixed

- `--update` now removes invalid `prefer` keys from `[[upstreams]]`; Telemt `3.4.22` rejects `upstreams[].prefer` under `general.config_strict=true`.

## 2026-06-12

### Changed

- Default upstream Telemt release and installer image tag are now pinned to `3.4.18` instead of using a moving `latest` tag.
- `--update` now analyzes the existing install, detects the current Telemt version when possible, switches compose to the exact checked compatible target tag, and safely extends existing `telemt.toml`/compose with missing Telemt `3.4.18` compatibility keys instead of requiring a separate migration mode.
- `TELEMT_VERSION=latest` is ignored in `--update`; the updater uses `TELEMT_LATEST_COMPATIBLE_VERSION` unless an exact release tag is provided intentionally.
- `build.sh` now blocks `TELEMT_VERSION=latest` by default; set `ALLOW_TELEMT_LATEST=1` only for an intentional moving-latest build.
- Generated configs now use `/run/telemt` for runtime/cache state, enable bounded `beobachten` diagnostics, add `client_mss` when supported, keep `synlimit = false` by default, set `mask_dynamic = false`, and add per-upstream IPv4 policy.
- Compose now always mounts `/run/telemt` as tmpfs for Telemt runtime/cache state; hardening additionally adds `/tmp` tmpfs, read-only root, dropped capabilities, and no-new-privileges.
- Generated compose YAML no longer contains tab indentation in the hardening block.
- Container recreation now removes only the exact `telemt` container name, avoiding accidental matches such as `telemt-monitor`.
- Public IPv4 detection now falls back cleanly to the installer error message instead of exiting early under `set -e`.
- README now documents every installer prompt with its meaning, default value, and recommended answer.
- `telemt-users` now supports `status`, `enable`, and `disable`, preserving user secrets through `[access.user_enabled]`.
- `telemt-report.sh` now shows user enabled state and attempts to include TLS fingerprint runtime diagnostics when available.

## 2026-05-31

### Changed

- nginx stream on `443/tcp` uses the SNI router again: requests for the configured domain go to Telemt on `127.0.0.1:1443`, and unknown/non-SNI traffic goes directly to the local HTTPS mask site on `127.0.0.1:8443`.
- Generated proxy links now also include a direct public-IPv4 variant in `/root/telemt-proxy-link-ip.txt` when the public IP is known. The direct link still keeps the configured domain as TLS SNI inside the `ee` secret.
- Added `--auto` / `-auto` mode for fresh installs. It uses defaults, confirms the plan automatically, and asks only for the proxy domain when it cannot read one from `DOMAIN`, saved config, or the server FQDN hostname.
- Docker doctor/startup now retries Telemt container recreation when Docker temporarily reports a zombie process, and prints a Russian/English recovery hint if the daemon still cannot reap it.
- Fixed nginx port preflight under `pipefail`: existing nginx listeners on `80/tcp` or `443/tcp` are now correctly accepted instead of being misreported as non-nginx conflicts.
- Fresh installs now retry the ACME HTTP-01 local and public IPv4 preflight after nginx reload. This avoids false `404` failures when nginx needs a moment to serve the newly written challenge file, while still stopping on real webroot/DNS/firewall problems.
- ACME and active-probing diagnostics no longer treat IPv4-mapped `::ffff:<ipv4>` resolver output as a real DNS AAAA record.
- Failed or interrupted fresh installs can be rerun normally: the reinstall guard now allows resume while the installer state is incomplete, and successful installs mark the state as complete.
- New installs can create multiple MTProxy users/links at once. The generated `telemt.toml` includes all users, and `/root/telemt-proxy-links.txt` contains a separate link pair for each user.
- Added `telemt-users`: a post-install utility to list, add, delete, and regenerate Telemt user links. It backs up `telemt.toml`, updates `[access.users]`, recreates the container, and rewrites the link files.
- Hardened Docker doctor/container recovery: `--fix-nginx` now rebuilds a missing local image when needed and recreates only the `telemt` container from the existing compose file, which repairs Docker Compose v1 `ContainerConfig` and removed-image failures without regenerating secrets or certificates.
- Clarified installer/help/README wording: repair mode preserves secrets, users, and certificates, and only edits `telemt.toml` for compatibility when an unsupported optional block prevents startup.
- `RESET_INSTALL_STATE=1` is now a true clean install path: it removes saved prompts, old Telemt secret/config/compose/container/link files before asking questions, and rebuilds `telemt-local:latest` instead of reusing a stale local image.
- nginx mask site config now uses an installer-owned file `telemt-mask-<domain>.conf`; legacy installer-generated vhosts are cleaned up when safe, while unrelated nginx site configs are left untouched.
- Added copy-paste command blocks for fresh install, update, repair/doctor, and full reinstall to both RU and EN README sections.
- Ubuntu package/startup now prefers Docker Compose v2 and tries to install it even when the old package step was already marked as done. The installer does not upgrade system Python; if only legacy Python `docker-compose` v1 is available, it removes stale Telemt containers before `compose up` to avoid `ContainerConfig`/removed-image crashes.
- Validation now performs a real HTTPS GET against the mask site through the public 443/SNI path and prints `Mask site OK`/`Маскировочная страница OK` when the placeholder is reachable.
- Package installation now checks which Compose package exists before installing, avoiding misleading `Unable to locate package docker-compose-plugin` output on Debian/Ubuntu builds that package Compose v2 as `docker-compose`.
- New installs now detect the actual Telemt version inside the Docker image, so `censorship.exclusive_mask` is enabled for `latest` images when the bundled Telemt binary supports it.
- The Docker installer now refuses unsupported OS versions before package installation: Debian must be 13.x or newer, Ubuntu must be 24.x or newer. Emergency `--fix-nginx` remains available.
- High-load tuning is now enabled by default for new Docker installs and can still be disabled at the prompt.
- `build.sh` no longer warns about `TELEMT_VERSION=latest`; the default workflow intentionally builds the current upstream release.
- If `80/tcp` or `443/tcp` is occupied by a Docker container, the installer now shows the container name/image/ports and asks whether to remove it before continuing.

## 2026-05-19

### Changed

- Removed HTTP/2 from the generated nginx mask-site listener for compatibility with nginx 1.24 and older distribution builds. The mask site only needs plain HTTPS, while Telemt traffic still goes through the nginx stream SNI router.
- Added `--fix-nginx` / `-fix` emergency doctor mode. It backs up changed nginx files, removes only incompatible `http2` directives, runs `nginx -t`, checks Docker/Compose, starts/reconciles the Telemt container, verifies `telemt.toml`, local API, certbot timer, and listening ports without changing Telemt secrets, users, certificates, or `telemt.toml` contents.
- The same doctor mode now detects duplicate top-level nginx `stream {}` files, keeps the installer-managed Telemt stream config, backs up and disables the extra stream files, then reruns `nginx -t`.
- Normal installer mode now refuses to run over an existing installation unless `RESET_INSTALL_STATE=1` is explicitly set. Existing installs should use `--update` or `--fix-nginx`.
- Restored the dark mask-site placeholder and removed service/administrator text from the generated page. `--fix-nginx` now also refreshes the existing mask page without changing Telemt secrets, certificates, or `telemt.toml`.
- Fixed the mask-page refresh path in `--fix-nginx`: repair mode now updates the HTML and restores the local `127.0.0.1:8443` HTTPS mask server when a certificate exists, without rewriting the nginx stream map.
- Stopped assuming `TELEMT_VERSION=latest` supports optional `censorship.exclusive_mask`. Strict Telemt configs no longer get that block for moving `latest` images, and `--fix-nginx` removes the optional block from existing configs when present.
- `RESET_INSTALL_STATE=1` now clears the installer resume state before running, so a clean reinstall no longer skips certificate/mask-site steps as "already done".
- Container start now removes an existing `telemt` container before `compose up` to avoid the Docker Compose v1 `KeyError: ContainerConfig` recreate bug.
- Improved the final active probing check in the Docker installer:
  - forces IPv4 with `openssl s_client -4` and `curl -4`;
  - stores the full result in `/root/telemt-active-probing-check.txt`;
  - prints automatic diagnostics on failure: DNS A/AAAA, listening ports, nginx status/test, stream config, Docker container/logs, and firewall state;
  - redacts proxy links/secrets from diagnostic Docker logs;
  - explains common `BIO_connect:connect error` causes and the exact next steps.
- Raised the default Telemt connection limit from `1000` to `5000`.
- Removed default Docker CPU/RAM/PID limits from generated compose files. Hardening still keeps `read_only`, `cap_drop`, `no-new-privileges`, `tmpfs`, healthcheck, and high `nofile` ulimits.
- Aligned generated Docker compose with the live Telemt standard: explicit non-root `user: "65532:65532"`, `RUST_LOG=warn`, `logging.driver=none` by default, and `nofile=65535/65535`.
- Added copy-paste Git, `wget`, and `curl` download commands for the Docker installer in RU and EN documentation.
- Fixed Docker installer proxy link generation: links are now built explicitly as valid TLS MTProxy links, saved in both `https://t.me/proxy` and `tg://proxy` forms, instead of relying on fragile JSON `grep` extraction.
- Fixed resume-mode link generation: reruns now load the existing secret from `telemt-secret.env` or the installed `telemt.toml` instead of failing with an unbound `TELEMT_SECRET`.
- Added an ACME HTTP-01 preflight before `certbot`: the installer now creates a temporary challenge file, verifies it locally and through the server public IPv4, opens `80/443` in active UFW/firewalld before certificate issuance, and writes clear diagnostics to `/root/telemt-acme-http01-check.txt` when the challenge path is unreachable.
- Added `--update` mode for the Docker installer. It preserves existing `telemt.toml`, `docker-compose.yml`, secrets, links, and nginx configs, rebuilds/pulls the Telemt image, recreates the container, and reruns validation.
- Added IDN/punycode normalization for domains and Let's Encrypt email domains. Cyrillic/IDN input is converted to ASCII punycode; invalid punycode is rejected before system changes.
- Added explicit `censorship.exclusive_mask` for new Telemt `3.4.12+` installs so the configured SNI domain is pinned to the local HTTPS mask backend.

## 2026-05-11

### Added

- Added this changelog to track Docker installer changes.
- Added a bilingual installer notice explaining that this is a Bash installer/Dockerfile, not an official Telemt installer, and listing software sources.
- Added strict Telemt config validation and API request body limit to generated configs:
  - `config_strict = true`
  - `request_body_limit_bytes = 65536`

### Changed

- Updated documentation examples to use the latest Telemt release by default.
- Kept explicit version pinning as an optional production workflow through `TELEMT_VERSION=<version>`.

### Not Added

- Did not add quota reset API handling because the intended setup is unlimited.
- Did not add Grafana or external metrics stack.
- Did not add third-party domain fronting.
