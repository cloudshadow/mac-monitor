# Translation resources

Each BCP 47 directory contains locale.json and the nine message namespaces. English defines the key and parameter contract. Add a language by copying en, changing metadata and translating values; published languages must be complete. Generated files must not be edited.

Run `npm --prefix web run i18n:check` and `npm --prefix web run i18n:generate` from the repository root. Duplicate properties, aliases, missing published keys and parameter mismatches fail validation. Ordinary parameters are strings; only a plural object's argument is an integer in 0…2147483647. Escape literal braces as `{{` and `}}`. Messages are rendered as text, never HTML.

`cpuPercentCore` is relative to one logical core; machine percentages divide by logical CPU count. Memory is physical footprint, and the system memory percentage is non-idle memory rather than an OS memory-pressure score. Preserve process names and sensor IDs. Native text is generated from native.json, with stable alphabetic parameter order.
