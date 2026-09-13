# Contributing to Kannu (കണ്ണ്)

Thank you for your interest in contributing to Kannu! We welcome contributions from everyone—developers, designers, testers, and documentation writers. Please read the following guidelines to help us maintain a collaborative and high-quality project.

## Table of Contents
- [How to Contribute](#how-to-contribute)
- [Code of Conduct](#code-of-conduct)
- [Development Setup](#development-setup)
- [Git Hook Setup](#git-hook-setup)
- [Working with AI Agents](#working-with-ai-agents)
- [Pull Request Process](#pull-request-process)
- [Before Changing Agent Status Code](#before-changing-agent-status-code)
- [Commit Checklist](#commit-checklist)
- [Coding Guidelines](#coding-guidelines)
- [Design Contributions](#design-contributions)
- [Documentation](#documentation)
- [Code Review process](#code-review-process)
- [Community & Support](#community--support)


---

## How to Contribute

1. **Fork the repository** and clone your fork locally.
2. **Create a feature branch** for your changes: `git switch -c feature/your-feature-name`
3. **Make your changes** following the guidelines below.
4. **Test your changes** to ensure they work as expected and do not break existing functionality.
5. **Commit** with clear, descriptive messages after completing the [Commit Checklist](#commit-checklist).
6. **Push** to your fork and submit a **pull request** (PR) to the `development` branch.
7. **Participate in code review** and address any feedback.

## Code of Conduct

We are committed to fostering a welcoming and inclusive environment. Please read our [Code of Conduct](CODE_OF_CONDUCT.md) before participating.

## Development Setup

- **Requirements:**
	- macOS Sonoma 14.0 or later
	- Xcode 16.4 or later, with a Swift 6.1+ toolchain — `KannuApp.swift` uses `extension CGRect: @retroactive Hashable`, which needs Swift 6.0, and CI builds on `macos-15`/`macos-26` for Swift 6.1+
	- MacBook with a notch (for full feature testing)
- **Clone the repo:**
	```bash
	git clone <your-fork-url>
	cd kannu
	open Kannu.xcodeproj
	```
- **Build & Run:**
	- Select your Mac as the run destination in Xcode.
	- Choose the **Kannu** scheme.
	- Press ⌘R to build and run.

## Git Hook Setup

Run this once after cloning:

```bash
./scripts/install-git-hooks.sh
```

This enables the repo-managed `pre-commit` hook from `.githooks/`.

## Working with AI Agents

Agents do a meaningful share of the work here — the Commit Checklist below asks for an agent feature
label precisely because of that. If you are pointing one at this repository, or you are one:

- **`AGENTS.md` at the repository root is the canonical instruction file.** It holds the engineering
  standards: the architecture principles, the build/test/run commands, the house conventions and the
  traps this project has already paid for. Codex, Cursor, Copilot, Aider and Windsurf read it
  automatically.
- **`CLAUDE.md` is Claude Code's entry point**, because Claude Code reads that filename and not
  `AGENTS.md`. It holds only Claude-specific machinery and imports the shared file with `@AGENTS.md`.
- **Do not copy rules between them.** One rule in two files is how this repo shipped a documented
  CHANGELOG shape that the commit hook rejected — twice, in two different files.
  `KannuTests/ChangelogRuleDocsTests.swift` now fails CI if the copies disagree with the hook.

## Pull Request Process

1. Ensure your PR has a clear title and description, and target `development` unless a maintainer asks for a different base branch.
2. Link any related issues.
3. Keep PRs focused—one feature or fix per PR when possible.
4. Update documentation if your change affects user-facing behavior.
5. Wait for review and address feedback promptly.

## Before Changing Agent Status Code

The agent-status subsystem (`Kannu/managers/AgentStatus/`) has repeatedly re-broken the same
invariants. [docs/REGRESSIONS.md](docs/REGRESSIONS.md) records each one with the commits that
prove it, why it recurs, and the guard that now catches it. Please read it before working in
that area, and add an entry when you find a bug recurring.

## Commit Checklist

Before each commit:

1. Define the **developer feature label** (what you are building).
2. Define the **agent feature label** if an agent did any of the work. The line itself is required
   either way — write `none — human-authored` when it did not.
3. Add one new entry at the **top** of `## [Unreleased]` in `CHANGELOG.md`, in exactly this shape.
   `.githooks/pre-commit` parses it literally and rejects anything else, so the bold keys and the
   trailing colons matter:

   ```markdown
   ### YYYY-MM-DD - <a short title for the change>
   - **Developer label:** <the developer feature label, or the request in the requester's own words>
   - **Agent label:** <agent feature label, or "none — human-authored">
   - **Changes:**
     - <one concrete change per bullet>
   ```

   The heading and the `Developer label` are not the same string: the heading titles the change,
   while the label names the feature or quotes the request that prompted it. Every entry in
   `CHANGELOG.md` follows that split — read the last few before writing yours.
4. Stage `CHANGELOG.md` together with the code changes.
5. Use a commit subject that reflects the developer feature label (avoid vague messages like `Fixes`).

## Coding Guidelines

- Follow existing Swift and SwiftUI conventions in the project.
- Match surrounding code style, naming, and structure.
- Keep changes scoped to the task at hand.
- Prefer extending existing abstractions over duplicating logic.

## Design Contributions

UI and UX improvements are welcome. Include screenshots or screen recordings in your PR when changing visual behavior.

## Documentation

Update `ReadMe.md`, localized strings, and inline help text when you change user-visible features or settings.

## Code Review process

Maintainers will review PRs for correctness, style, and scope. Be responsive to feedback and iterate as needed.

## Community & Support

Open an issue for bugs, feature requests, or questions. Be respectful and provide reproduction steps for bug reports.

Thank you for helping make Kannu better!
