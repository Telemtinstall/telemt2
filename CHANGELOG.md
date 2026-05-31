# Changelog

## 2026-05-31

### Changed

- Removed HTTP/2 from generated Telemt nginx mask-site listeners for Debian/Ubuntu, Astra Linux, and AlmaLinux compatibility. The mask site only needs plain HTTPS; Telemt traffic still goes through nginx stream SNI routing.
- Added `--fix-nginx` / `-fix` emergency doctor mode for Debian/Ubuntu, Astra Linux, and AlmaLinux Telemt installers. It backs up changed nginx files, removes only incompatible `http2` directives, runs `nginx -t`, checks Docker/Compose, starts/reconciles the Telemt container, verifies `telemt.toml`, local API, certbot timer, and listening ports without changing Telemt secrets, users, or certificates.

## 2026-05-23

### Added

- Added experimental `proxy/whatsapp/` installer for the official WhatsApp Chat Proxy Docker image.
- Added guarded `direct` and `sni` modes for WhatsApp proxy:
  - `direct` requires free public `443/tcp`;
  - `sni` can add one route to an existing Telemt nginx stream map after backup and `nginx -t`.
- Added DNS A-record validation against the current server IPv4 and local-only HAProxy stats binding for the WhatsApp proxy installer.
- Added optional `ufw`/`firewalld` port opening for the WhatsApp proxy installer without rewriting custom firewall rules.
- Improved WhatsApp proxy nginx stream detection for alternate Telemt config names and blocked reuse of an already-routed Telemt SNI domain.
- Made WhatsApp proxy DNS and port/mode preflight run on every resume so changing the domain cannot reuse stale checks.
- Improved WhatsApp proxy final verification with retries for HAProxy stats and SNI certificate checks.
- Added `-lang ru` / `-lang en` and `-update` options to the WhatsApp proxy installer.
- Added explicit WhatsApp connection details to the final installer output: host/server, `443/tcp`, and optional media `587/tcp`.
- Expanded WhatsApp proxy documentation with clean-server/Telemt-nginx requirements, SNI routing scheme, and detailed installer prompt explanations.

## 2026-05-22

### Added

- Added `--update` / `-update` mode to Telemt single-server installers for Debian 13/Ubuntu, Debian 11, Astra Linux, AlmaLinux, and Tiny Core.
- Added IDN/punycode normalization for Telemt installer domains and Let's Encrypt email domains.
- Added conditional `censorship.exclusive_mask` generation for new configs when the selected Telemt image/release is `latest` or `3.4.12+`.
- Documented update commands and installer prompts in the root README and Telemt OS README files.

### Changed

- Update mode preserves existing `telemt.toml`, users, secrets, proxy links, nginx/SSH settings, and certificates; it only updates/recreates the Docker container or native Tiny Core binary.

## 2026-05-19

### Changed

- Raised the default Telemt connection limit from `1000` to `5000` in Telemt installers and batch installers.
- Removed default Docker CPU/RAM/PID limits from Telemt-generated compose files so media downloads are not throttled by artificial container limits.
- Kept Docker hardening controls that do not cap throughput: `read_only`, `cap_drop`, `no-new-privileges`, `tmpfs`, disabled access logs, and `nofile` ulimits.
- Fixed the WireGuard installer routing path: generated `wg0.conf` now adds explicit `FORWARD` accept rules in addition to NAT, and active UFW setups get `ufw route allow` for the VPN route.

## 2026-05-11

### Added

- Added `utils/certbot_helper.sh` for issuing Let's Encrypt certificates with certbot-style domain arguments, DNS preflight, and optional auto-renewal setup.
- Added `utils/README.md` with Russian and English usage notes for utility scripts.
- Added certbot-style non-interactive mode, web server detection, and automatic HTTP to HTTPS redirect handling to `utils/certbot_helper.sh`.
- Added this changelog to track repository-level changes.
- Added a bilingual installer notice explaining that the scripts are Bash installers, not official upstream installers, and listing software sources.
- Added short bilingual notice links at the top of subdirectory README files.
- Added `telemt/debian-11/README.md` for the dedicated Debian 11 installer.

### Changed

- Split the repository into two main trees:
  - `telemt/` for Telemt MTProto proxy installers and SSH helper tools.
  - `vpn/` for VLESS, WireGuard, OpenVPN, AmneziaWG, and experimental VPN installers.
- Renamed the Debian/Ubuntu Telemt path to `telemt/debian-13-ubuntu/`.
- Moved the Debian 11 Telemt installer to `telemt/debian-11/`.
- Updated root README and per-directory documentation links to the new paths.
- Updated VLESS download examples to use the public `Telemtinstall/telemt2` paths.
- Updated Tiny Core Telemt installer to use the latest Telemt release by default with upstream `.sha256` verification.
- Added strict Telemt config validation and API request body limit to the Tiny Core installer:
  - `config_strict = true`
  - `request_body_limit_bytes = 65536`

### Not Added

- Did not add quota reset API handling because the intended setup is unlimited.
- Did not add Grafana or external metrics stack.
- Did not add third-party domain fronting.
