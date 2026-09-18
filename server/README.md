# Lightroom MCP Unified server

Node.js >=22, MCP TypeScript SDK v2.0.0. This package is private and is distributed
in the project's GitHub releases, not through npm.

Read the [repository installation guide](../README.md) and [feature audit](../docs/FEATURE_AUDIT.md).
From this directory, run `npm ci`, `npm run check`, `npm run lint`, and
`npm test -- --runInBand`. The test command builds the CLI before exercising its
actual stdio and TCP transport. Runtime entry point: `node dist/index.js`.
