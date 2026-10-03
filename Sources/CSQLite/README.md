# Embedded SQLite

Unmodified SQLite 3.53.4 amalgamation, downloaded from:

https://sqlite.org/2026/sqlite-amalgamation-3530400.zip

Archive SHA3-256 (verified before extraction):

`628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`

The source/header public-domain notices remain intact. SwiftPM builds this source directly; it does not link the macOS SQLite version. Compilation enables thread safety and omits extension loading and global allocator statistics. Connection settings are applied by each database owner, not by the amalgamation.
