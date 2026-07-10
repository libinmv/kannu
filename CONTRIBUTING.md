# Contributing to Kannu (കണ്ണ്)

Thank you for your interest in contributing to Kannu! We welcome contributions from everyone—developers, designers, testers, and documentation writers. Please read the following guidelines to help us maintain a collaborative and high-quality project.

## Table of Contents
- [How to Contribute](#how-to-contribute)
- [Code of Conduct](#code-of-conduct)
- [Development Setup](#development-setup)
- [Git Hook Setup](#git-hook-setup)
- [Pull Request Process](#pull-request-process)
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
	- Xcode 15.0+ with Swift 5.9 toolchain
	- MacBook with a notch (for full feature testing)
- **Clone the repo:**
	```bash
	git clone <your-fork-url>
	cd AgentStatDynamicIsland
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

## Pull Request Process

1. Ensure your PR has a clear title and description, and target `development` unless a maintainer asks for a different base branch.
2. Link any related issues.
3. Keep PRs focused—one feature or fix per PR when possible.
4. Update documentation if your change affects user-facing behavior.
5. Wait for review and address feedback promptly.

## Commit Checklist

Before each commit:

1. Define the **developer feature label** (what you are building).
2. If using an agent, define the **agent feature label**.
3. Add one new entry to `CHANGELOG.md` under `## [Unreleased]` with:
   - `Developer label`
   - `Agent label`
   - `Changes` bullets listed one-by-one
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
