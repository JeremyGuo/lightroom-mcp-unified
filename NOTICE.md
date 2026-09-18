# Source and license notices

Lightroom MCP Unified 0.1.0 integrates and modifies MIT-licensed source from
Automaat/lightroom-mcp, pinned at commit
710dcb022c36c5fd04fef2643115290e2fb11657 (version 0.15.0).

Upstream: https://github.com/Automaat/lightroom-mcp
Original copyright: Copyright (c) 2026 Marcin Skalski.
The complete original MIT license is preserved in LICENSE and server/LICENSE.
The upstream bridge, catalog handlers, preset handlers, JSON implementation,
installer, tests, and packaging infrastructure are used and modified under MIT.
New integration and independently written controller code:
Copyright (c) 2026 JeremyGuo and contributors, licensed under the same MIT terms.

varunkumar/lightroom-mcp was reviewed at commit
04f872fd1b6b0f7e2ee16c88121b9f0695fc1ffc to inventory public tool interfaces.
No license file was present at that revision. Its source, documentation, bundled
Adobe documentation, artwork and other assets are NOT included or copied into
this distribution. The similarly named tools are new implementations against
Adobe's public Lightroom SDK API contracts. Interface compatibility is not a
claim of bit-for-bit behavior compatibility.

Adobe's SDK documentation was consulted to check public API names and signatures.
Adobe SDK documentation and SDK binaries are not redistributed. Lightroom and
Adobe are trademarks of Adobe. This project is unofficial and is not affiliated
with or endorsed by Adobe, Anthropic, OpenAI, or either upstream maintainer.

Runtime dependencies retain their licenses inside server/node_modules in release
bundles. Dependency versions and integrity hashes are recorded in package-lock.json.
No code-signing identity or signed/notarized executable is claimed for this release.
