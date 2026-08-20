# Shelly Android Agent Guide

## Product Direction

- Build an Android-first SSH client with Flutter.
- Aim for roughly the same functional coverage as Shelly SSH, but do not
  migrate or preserve Shelly's code, data model, or desktop architecture.
- Let `dartssh2`, Android platform constraints, and mobile usability shape the
  implementation.
- The HTML prototype and screenshots under `md3-ssh-client-mockup/` are the
  visual and interaction source of truth.
- The curated ServerBox snapshot under `example/` is an implementation
  reference only. It is not the product design and is not a project template.

## Collaboration

- The user owns frontend design, product decisions, hands-on testing, and
  feedback.
- The coding agent owns implementation, integration, routine code hygiene, and
  concise handoff notes.
- Implement requested work end to end when requirements are clear. Do not stop
  at a plan or leave placeholder behavior unless the user explicitly asks for
  scaffolding.
- Make conservative product assumptions that follow the HTML prototype and
  existing code. Ask only when a choice would materially change behavior or
  scope.
- Do not redesign the HTML prototype on personal preference. Point out concrete
  Android, accessibility, security, or terminal-usability conflicts before
  changing the design.
- Keep changes scoped. Do not combine feature work with unrelated refactors,
  dependency upgrades, generated-file churn, or formatting of untouched files.

## Reference Code And Licensing

- `example/` contains a curated snapshot of ServerBox and its forks. ServerBox
  is AGPL-3.0 licensed; the bundled package directories retain their own
  licenses.
- Treat the snapshot as read-only reference material. Do not import from it,
  add it as a path dependency, or make the application build depend on it.
- Prefer learning APIs, lifecycle decisions, failure cases, and test scenarios
  from the snapshot. Do not copy AGPL implementation into the product unless
  the user explicitly accepts the resulting license obligations.
- Never run project-wide analysis, tests, builds, or code generation inside
  `example/`. The curated snapshot is intentionally not a runnable project.

## Architecture

- Organize production code by feature, with clear areas for hosts, terminal
  sessions, SFTP, history and snippets, notes, settings, and the read-only
  agent.
- Keep shared infrastructure narrow: SSH transport, secure storage, local
  persistence, Android lifecycle, and common UI primitives.
- Wrap `dartssh2` behind application-owned services and session abstractions.
  Widgets must not construct or own raw `SSHClient`, shell, or SFTP clients.
- Keep terminal emulation behind an adapter so an upstream `xterm` update or a
  maintained fork can be adopted without rewriting feature code.
- Separate persistent host configuration from live connection state. Never
  serialize sockets, SSH clients, stream controllers, or widget state.
- Keep business logic out of widgets. Widgets render state and dispatch user
  intent; controllers/services own connection, retry, transfer, and persistence
  behavior.
- Make connection and transfer cancellation explicit. Dispose subscriptions,
  timers, controllers, shells, SFTP handles, and clients at their ownership
  boundary.

## Code Standards

- Prefer files below 800 lines. This is a soft maximum, not a target; split a
  file earlier when it contains more than one responsibility.
- Prefer small cohesive classes and functions over broad utility files.
- Use strong Dart types at boundaries and in state. Avoid `dynamic`, untyped
  maps, and repeated casts when a model or sealed result can express the data.
- Do not add fallback type branches for hypothetical input variants. Support
  multiple shapes only when an external contract or real data requires it, and
  normalize once at the boundary.
- Do not add redundant compatibility paths, speculative platform branches, or
  duplicate implementations for old dependency versions.
- Do not swallow failures with `catch (_)`, fake success values, or silent
  defaults. Convert expected failures into explicit domain errors and surface
  actionable messages to the UI.
- Catch exceptions only where the code can add context, recover deliberately,
  or translate an infrastructure error into an application error.
- Avoid premature abstractions. Add an interface or helper when it protects an
  ownership boundary, enables a real alternate implementation, or removes
  meaningful duplication.
- Use generated immutable models only when generation is already part of the
  production project. Do not introduce code generation for a trivial model.
- Comments should explain constraints or non-obvious decisions, not narrate
  straightforward code.
- Keep user-facing strings ready for localization; do not scatter duplicate
  literals through widgets.

## SSH And Security Rules

- Always implement host-key verification. Unknown hosts require an explicit
  trust decision; changed keys must block the connection until the user reviews
  them.
- Never disable host-key signature verification in production code.
- Store passwords, private keys, passphrases, and provider secrets with Android
  Keystore-backed secure storage. Do not put secret material in ordinary local
  databases, logs, crash text, analytics, or debug output.
- Store non-secret host metadata, known-host records, history, snippets, notes,
  and session metadata in the normal persistence layer.
- Authentication, jump-host, port-forwarding, shell, and SFTP failures must
  preserve enough context for a useful user-facing error without exposing
  secrets.
- The agent is supervised and read-only by default. Any future remote command
  execution requires an explicit user approval boundary and visible command
  text.
- Product Agent read tools may inspect bounded terminal/session context, remote
  read-only data, and configured web-search results. They must not expose SSH
  clients, credentials, private keys, or provider secrets to the model.
- Product Agent write tools may only create an explicit request containing one
  or more complete commands. The app must show the exact request and wait for
  user approval before sending anything to the remote terminal; a revised
  command requires a new approval.
- Provider adapters should normalize Messages and Responses streaming events
  into one tool-loop runtime. Display provider status summaries when available,
  never model-private chain-of-thought content.

## Mobile Experience

- Design for touch and small screens first. Desktop density and hover behavior
  are not defaults.
- Terminal work must account for IME input, CJK width, selection, copy/paste,
  focus restoration, orientation changes, and a mobile key row for Ctrl, Alt,
  Esc, Tab, arrows, and other terminal keys.
- The current mockup omits the terminal extra-key row. Production must add a
  compact Termux-style row with one-shot/lockable modifiers, navigation keys,
  common shell characters, long-press repeat, and configurable ordering.
- Extra keys must emit terminal key/control sequences through the terminal
  input API. Do not implement them as ordinary text concatenation.
- Avoid rebuilding the terminal widget for normal output. Batch high-frequency
  stream updates where needed and keep connection state separate from terminal
  paint state.
- Treat app backgrounding, process death, network changes, and Android battery
  policy as normal lifecycle events. Do not promise background session survival
  unless a foreground service is actually active and visible to the user.
- Preserve recoverable UI state, but do not pretend a dead SSH socket is still
  connected. Reconnection must be explicit and observable.

## Verification

- Keep routine verification lightweight. Format changed Dart files and use
  focused static analysis when it is quick and relevant.
- Do not run `flutter test`, integration suites, release builds, Gradle builds,
  broad benchmarks, or other complex tests unless the user explicitly asks.
- Do not create, launch, reset, or manage an Android emulator.
- When the user explicitly says an emulator is running and asks for device
  testing, identify the target with `flutter devices` and use
  `flutter run -d <device-id>`. Do not expand that request into a full test
  suite.
- If a change cannot be meaningfully verified without the user's emulator,
  finish the implementation and state the exact manual flow that remains to be
  checked.

## Completion

- A feature is complete when its production path, loading/empty/error states,
  cancellation and cleanup behavior, and relevant persistence are implemented.
- Report what changed, what lightweight checks ran, and what device behavior
  still needs user feedback.
- Do not claim a terminal, background-service, keyboard, biometric, or file
  picker flow works on Android until it has been exercised on the user's
  emulator or a physical device.
