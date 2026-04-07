# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

ColimaSwift is a macOS menu bar app (LSUIElement) that controls and monitors a local [Colima](https://github.com/abiosoft/colima) VM. It shells out to the `colima`, `docker`, and `ps` CLIs to read status and drive start/stop/restart actions, then renders the result in a SwiftUI popover.

Targets arm64 macOS 13+. Built with `xcrun swiftc` from a Makefile — there is no `.xcodeproj` or `Package.swift`.

## Build & run

```bash
make          # Compile ColimaSwift.app into build/
make run      # Build and launch the app
make clean    # Remove build/
```

There is no test target.

## Architecture

The Swift sources in `ColimaSwift/` form a tight SwiftUI + Combine pipeline:

- **ColimaSwiftApp.swift** — `@main` entry plus `AppDelegate`. The AppDelegate owns the `NSStatusItem`, the `NSPopover` hosting `MenuContentView`, and subscribes to the controller's `@Published` state to redraw the menu bar icon.
- **ColimaController.swift** — The single source of truth. An `ObservableObject` that runs a 5-second polling loop, executes shell commands, parses their output into `ColimaStatus` models, and exposes start/stop/restart actions. All UI state flows from here.
- **MenuContentView.swift** — SwiftUI view bound to the controller. Renders status, VM/container metrics, action buttons, and error messages.
- **ColimaStatus.swift** — Plain models/enums for instance state, VM metrics, and Docker container counts.
- **Shell.swift** — Thin `Process` wrapper. Always invokes tools by **absolute path** (`/opt/homebrew/bin/colima`, `/opt/homebrew/bin/docker`, `/bin/ps`) because the app launches without a login shell `PATH`.

### How the data flows
1. Controller's timer fires → runs `colima list --json` (one JSON object per line, filter for the `default` profile).
2. If running, reads `~/.colima/_lima/default/vz.pid` and asks `ps` for the host-agent's CPU/memory.
3. Runs `docker ps -a` to count running/total containers.
4. Updates `@Published` properties → SwiftUI view and menu bar icon refresh automatically via Combine.

### Entitlements
`ColimaSwift.entitlements` **disables** the App Sandbox on purpose: a sandboxed process can't spawn `colima`/`docker`/`ps`. Don't re-enable it without rethinking the whole execution model.

## Conventions
- New shell invocations should go through `Shell.swift` and use absolute paths — never rely on `PATH`.
- New observable state belongs on `ColimaController`; views should stay declarative.
- Keep the JSON parsing tolerant of colima version drift (it emits NDJSON, not a JSON array).
