# Contributing

Start from specs/001-hardware-monitor and .specify/memory/constitution.md. Preserve metric validity, raw units, PID/start-time identity, monotonic deltas, shared collection and authentication boundaries. Never substitute zero for unavailable values or claim a model is validated from a registry presence test.

Use Swift 6.1+ and Node 22.12+. Run Swift tests, i18n checks, the production web build and the relevant integration smoke. `scripts/smoke.py` and `scripts/lan-smoke.py` use temporary databases and do not install a daemon or change certificate trust. Browser tests use Playwright with an installed Chrome via CMM_CHROME, or configure a downloaded Playwright browser for CI. Hardware/system authorization/performance acceptance remains explicit and is recorded separately.

Translation contributions only edit locales; see locales/README.md. Generated resources are committed with their sources. Dependencies are pinned; update versions, lock files and third-party notices together. Do not add license or copyright claims for the project until its owner confirms them. Release workflows build candidates with ad-hoc signatures; publication requires the hardware, installation and license gates in docs/release-checklist.md.
