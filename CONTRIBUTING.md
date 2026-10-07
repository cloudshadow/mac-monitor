# Contributing

Preserve metric validity, raw units, PID/start-time identity, monotonic deltas, shared collection and authentication boundaries. Never substitute zero for unavailable values or claim a model is validated from a registry presence test.

Use Swift 6.1+ and Node 22.12+. Run Swift tests, i18n checks, the production web build and the relevant integration smoke. `scripts/smoke.py`, `scripts/lan-smoke.py`, and `scripts/port-smoke.py` use temporary databases and do not install a daemon or change certificate trust. Browser tests use Playwright with an installed Chrome via CMM_CHROME, or configure a downloaded Playwright browser for CI. Hardware/system authorization/performance acceptance remains explicit and is recorded separately.

Translation contributions only edit locales; see locales/README.md. Generated resources are committed with their sources. Dependencies are pinned; update versions, lock files and third-party notices together. Do not add license or copyright claims for the project until its owner confirms them. Release workflows build candidates with ad-hoc signatures; publication requires the hardware, installation and license gates in docs/release-checklist.md.

## Build and test locally

Development requires Swift 6.1+ with Xcode or Command Line Tools, Node 22.12+, and Python 3. Browser tests use an installed Google Chrome; set `CMM_CHROME` to choose another executable.

```bash
npm --prefix web ci
npm --prefix web run build
bash scripts/swift.sh test -j 4
node --test scripts/i18n/validate.test.mjs
npm --prefix web test
python3 scripts/installer-reinstall-test.py
python3 scripts/smoke.py
python3 scripts/port-smoke.py
python3 scripts/lan-smoke.py
```

## Run a development instance

```bash
mkdir -m 700 /private/tmp/mac-monitor-dev
.build/debug/MonitorAgent --data-root /private/tmp/mac-monitor-dev --web-root "$PWD/web/dist"
# In another terminal:
.build/debug/MonitorControl --data-root /private/tmp/mac-monitor-dev
```

## Package the app

```bash
bash scripts/package-app.sh 0.1.11
CMM_ARCH=arm64 bash scripts/package-app.sh 0.1.11
CMM_ARCH=x86_64 bash scripts/package-app.sh 0.1.11
```

Packages and checksums are written to `artifacts/`; app bundles are under `artifacts/package/<arch>/`. Cross-compilation does not replace runtime testing on the target architecture.
