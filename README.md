# Home Assistant TimescaleDB App

[![License](https://img.shields.io/github/license/flaksit/hass-timescaledb)](LICENSE)

A Home Assistant app providing PostgreSQL 18 with [TimescaleDB](https://www.timescale.com/) 2.25 — a high-performance time-series database optimized for the Raspberry Pi 5.

## Features

- PostgreSQL 18 with TimescaleDB 2.25 extension pre-loaded
- Optimized defaults for Raspberry Pi 5 (4GB/8GB)
- Configurable tuning via the app UI (shared_buffers, work_mem, etc.)
- Role-based access control with auto-generated passwords
- Proper process management with s6-overlay (graceful shutdown, signal handling)
- Health monitoring via pg_isready watchdog

## Getting Started

1. Add this repository to your Home Assistant app store:

   `https://github.com/flaksit/hass-timescaledb`

2. Install the "TimescaleDB" app
3. Start the app

See the [full documentation](timescaledb/DOCS.md) for configuration options.

## Architecture

| Component | Version |
|-----------|---------|
| PostgreSQL | 18 |
| TimescaleDB | 2.25.2 |
| s6-overlay | 3.2.2.0 |
| Target | aarch64 (Raspberry Pi 5) |

## License

See [LICENSE](LICENSE).
