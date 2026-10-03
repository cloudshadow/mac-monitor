# Third-party dependencies

This file records dependencies; it does not license Cloud Mac Monitor itself. The project's license and copyright holder are still to be confirmed before public release.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| SwiftNIO | 2.83.0 | Apache-2.0 | https://github.com/apple/swift-nio |
| SwiftNIO SSL / embedded BoringSSL | 2.30.0 | Apache-2.0; BoringSSL includes third-party notices | https://github.com/apple/swift-nio-ssl |
| swift-sodium | 0.11.0 | MIT | https://github.com/jedisct1/swift-sodium |
| libsodium | 1.0.22 (fixed swift-sodium XCFramework; runtime version also reported) | ISC | https://github.com/jedisct1/libsodium |
| SQLite | 3.53.4 | Public domain | https://sqlite.org/2026/sqlite-amalgamation-3530400.zip |
| React / React DOM | 19.3.0 | MIT | https://github.com/facebook/react |
| Vite / plugin-react | 8.3.2 / 6.1.1 | MIT | https://github.com/vitejs/vite |
| TypeScript | 7.0.2 | Apache-2.0 | https://github.com/microsoft/TypeScript |
| React type declarations | 19.3.0 | MIT | https://github.com/DefinitelyTyped/DefinitelyTyped |

Swift transitive dependencies are pinned in `Package.resolved`; web transitive dependencies are pinned in `web/package-lock.json`. Collected upstream license texts are in `ThirdParty/Licenses/` and included by the development app builder. The public release packager must also collect all shipped transitive dependency notices. Release packaging is not implemented yet.

SQLite is compiled directly from the unmodified `sqlite3.c` and `sqlite3.h` in `Sources/CSQLite`. The official archive SHA3-256 was verified before extraction:

```
628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e
```

The official archive also includes the public-domain dedication in its source headers. No code from other monitoring applications has been copied.

开发验收另外使用 `@playwright/test`、`playwright` 与 `playwright-core`（版本见 web/package-lock.json），来源 https://github.com/microsoft/playwright ，Apache-2.0；许可文本保存在 ThirdParty/Licenses/Playwright-Apache-2.0.txt。它们不进入生产网页或原生运行服务。
