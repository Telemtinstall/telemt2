# Changelog

## 2026-07-06

### Changed

- Updated Docker, Debian/Ubuntu systemd, and Tiny Core Telemt installers to the checked compatible upstream release `3.4.22`.
- Added `client_mss_bulk = "1400"` support for Telemt `3.4.19+` in fresh installs and update-mode compatibility patching.
- Extended update-mode config analysis to detect missing `server.client_mss_bulk` and patch existing configs without a separate migration mode.
- Added Synlimit V2 fields for explicit `TELEMT_SYNLIMIT=nftables|iptables` use while keeping SYN limiter disabled by default in nginx-fronted installs.
- Aligned Tiny Core Telemt config logic with Docker/systemd: generated links now use the selected user list, and Tiny Core supports multiple users, optional `ad_tag`, and optional middle proxy.
- Added Tiny Core `--update` mode: it backs up the existing binary/config, downloads the exact pinned Telemt release, rewrites compatible config keys, restarts services, and persists changes through `filetool.sh -b`.

### Fixed

- Removed invalid `prefer` keys from `[[upstreams]]` in generated and update-patched Telemt configs; Telemt `3.4.22` rejects `upstreams[].prefer` when `general.config_strict=true`.

## 2026-06-12

### Changed

- Pruned legacy Telemt installers from the public tree: AlmaLinux, Astra Linux, and Debian 11 are no longer published.
- Added the Debian 13 systemd/no-Docker Telemt installer and published the Docker Telemt installer tree.
- Updated Tiny Core Telemt to default to release `3.4.18`, verify official GitHub release `.sha256` files, and use the newer compatibility config keys when the selected release supports them.
- Updated the WhatsApp proxy installer to default to the official dated Docker image `facebook/whatsapp_proxy:20260607`; update mode now checks Docker Hub for the newest dated `YYYYMMDD` tag instead of relying on mutable `latest`.
- Pinned the legacy Debian/Ubuntu Docker installer to a checked GHCR image digest instead of the mutable `ghcr.io/telemt/telemt:latest` tag.
- Made `sync_github.sh` explicitly publish `proxy/whatsapp` and all kept VPN directories from the local source tree.
- Promoted AmneziaWG documentation from experimental/test wording to the supported working VPN installer wording.
- Made the AmneziaWG installer check kernel/linux-headers reboot requirements at startup, before the long DKMS/PPA install path, and print the exact resume command after reboot.
- Added bot-safe VPN QR export: `wgctl` now supports JSON mode with `qr_png_base64`/`qr_png_data_uri`, and `wgctl`, `awgctl`, and `vlessctl` now have `qrpng` commands for large PNG QR files.
- Added Amnezia-native QR export for AmneziaWG: `awgctl -j add/qr` now returns `amnezia_qr_png_base64_items`, and `awgctl amqrpng` saves Android-friendly Amnezia chunk QR PNG files.
- Added AmneziaVPN `.vpn` QR export for AmneziaWG: `awgctl -j add/qr` now returns `vpn_key` and `vpn_qr_png_base64_items`, and `awgctl vpnkey/vpnqrpng` generate the official-style self-hosted Amnezia payload for Android imports.
- Added `vpn_qr_chunks_total` to AmneziaWG JSON QR responses for diagnostic/fallback chunked `.vpn` QR handling.
- Switched the AmneziaWG bot contract to two explicit single QR fields: `android_qr_png_base64` for Android Amnezia and `ios_qr_png_base64` for iPhone Amnezia; `vpnqrpng` now saves one Android-native QR instead of a chunk series.
- Removed the experimental WireGuard-over-wstunnel tree from the public VPN tree.

## 2026-06-11

### Added

- Added VLESS installer `--auto` / `--direct` non-interactive modes with `pipiska1` as the default first client name.
- Added VLESS installer `-lang ru|en` mode for localized prompts, install plan, and final output.
- Added `vlessctl -j` JSON output for client management, links, QR PNG data, traffic, and online checks.
- Added VLESS online-state fields without removing existing JSON fields: `online_users`, `clients[].online`, and `clients[].last_seen_*`.
- Documented VLESS JSON response fields, status codes, QR handling, and default client-name auto-numbering.
- Documented VLESS `online` JSON compatibility notes for Telegram bots and other integrations.
- Added VLESS access-log management through `vlessctl logs on|off|status`, nginx `[ip=...]` access format, and 7-day daily logrotate config.

### Changed

- Improved VLESS installer and `vlessctl` error messages for Russian-speaking operators.
- Made `vlessctl add` auto-increment an existing client name instead of failing.
- Moved VLESS base package installation after the install-plan confirmation so operators can inspect prompts, DNS errors, and the plan before package changes begin.
- Made VLESS port preflight print busy listeners and suggest free replacement ports for HTTPS/VLESS, local Xray, and Stats API ports.

## 2026-06-04

### Fixed

- Fixed VPN installer resume handling: completed-step state is cleared when saved installer input changes, so changed ports/domains/modes no longer reuse stale preflight/config steps.
- Added ACME HTTP-01 preflight checks to VPN HTTPS-mask installers before running certbot.
- Added explicit FORWARD rules and UFW route allowance to AmneziaWG and experimental WireGuard-over-wstunnel installers.
- Added a client-side route guard to generated WireGuard-over-wstunnel helper scripts to avoid full-tunnel routing loops.
- Removed unnecessary `http2` from the OpenVPN nginx mask backend listener for wider nginx compatibility.

## 2026-05-31

### Changed

- Removed HTTP/2 from generated Telemt nginx mask-site listeners for Debian/Ubuntu, Astra Linux, and AlmaLinux compatibility. The mask site only needs plain HTTPS; Telemt traffic still goes through nginx stream SNI routing.
- Added `--fix-nginx` / `-fix` emergency doctor mode for Debian/Ubuntu, Astra Linux, and AlmaLinux Telemt installers. It backs up changed nginx files, removes only incompatible `http2` directives, runs `nginx -t`, checks Docker/Compose, starts/reconciles the Telemt container, verifies `telemt.toml`, local API, certbot timer, and listening ports without changing Telemt secrets, users, or certificates.
- The same doctor mode now detects duplicate top-level nginx `stream {}` files, keeps the installer-managed Telemt stream config, backs up and disables the extra stream files, then reruns `nginx -t`.
- Doctor mode no longer asks Docker Compose to recreate an existing Telemt container. It uses `docker start telemt` when the container already exists, avoiding the Compose v1 "image has been removed, volume data could be lost" prompt.
- Normal installer mode now refuses to run over an existing installation unless `RESET_INSTALL_STATE=1` is explicitly set. Existing installs should use `--update` or `--fix-nginx`.
- Restored the dark Telemt mask-site placeholder for Debian 13/Ubuntu and Tiny Core, and removed service/administrator text from the generated page.

## 2026-05-23

### Added

- Added `proxy/whatsapp/` installer for the official WhatsApp Chat Proxy Docker image.
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

- Added `--update` / `-update` mode to Telemt single-server installers for Debian 13/Ubuntu and Tiny Core.
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
### Changed

- Split the repository into two main trees:
  - `telemt/` for Telemt MTProto proxy installers and SSH helper tools.
  - `vpn/` for VLESS, WireGuard, OpenVPN, AmneziaWG, and experimental VPN installers.
- Renamed the Debian/Ubuntu Telemt path to `telemt/debian-13-ubuntu/`.
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
