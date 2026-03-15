# macUSB Workflow Rules

This file defines the end-to-end workflow for preparing, documenting, and delivering changes in this repository.

## Purpose

- Keep the change process consistent for all contributors.
- Ensure implementation, documentation, release notes, and commits stay synchronized.
- Serve as the top-level process guide; detailed commit and release-note rules live in dedicated rule files.

## Workflow (End-to-End)

Use this sequence unless the user explicitly requests a narrower scope:

1. Analyze current behavior and gather context from code and docs.
2. Implement the required change.
3. Validate behavior (build/tests/smoke checks as appropriate).
4. Update documentation in `docs/reference/` when behavior, contracts, or workflows changed.
5. Update release notes in `docs/reference/CHANGELOG.md` when the change is user-facing and release-relevant.
6. Prepare commit message and commit scope according to commit rules.

## Definition of Done

A change is done when all applicable conditions are met:

- Requested behavior is implemented.
- Validation was run (or explicitly reported if not possible).
- `docs/reference/APPLICATION_REFERENCE.md` reflects the current behavior when relevant.
- `docs/reference/CHANGELOG.md` is updated when release-relevant.
- No stale documentation links remain.
- Commit content and message follow repository rules.

## Change Classification

Use these rules to decide required documentation updates:

- Code or runtime behavior changed:
- update `docs/reference/APPLICATION_REFERENCE.md`.
- User-facing behavior changed and should appear in release notes:
- update `docs/reference/CHANGELOG.md`.
- Internal-only refactor with no user-facing impact:
- changelog update is optional.
- Documentation-only change:
- update only the affected doc(s), and keep cross-references consistent.

## Commit Workflow

- Apply commit rules from `docs/rules/COMMIT_RULES.md`.
- Keep commit scope aligned with the requested task scope.

## Release Notes Workflow

- Apply release-note rules from `docs/rules/CHANGELOG_RULES.md`.
- Keep entries short, user-facing, and grouped by coherent topics.

## Decision and Escalation Rules

- If requirements are ambiguous and materially affect behavior, ask before implementing.
- If multiple valid implementations exist, present tradeoffs and request direction.
- If blocked by environment constraints, report blocker, what was validated, and what remains.

## Documentation Hygiene

- Keep process rules only in `docs/rules/`.
- Keep app behavior and technical reference only in `docs/reference/`.
- Avoid duplicating the same rule in multiple files.
- Keep links and file paths current after every rename/restructure.
