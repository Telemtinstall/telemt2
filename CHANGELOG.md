# Changelog

## 2026-05-11

### Added

- Added this changelog to track repository-level changes.
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
