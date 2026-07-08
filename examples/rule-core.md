---
description: Core project conventions and global standards
alwaysApply: true
---

# General Conventions

<!-- Example of a canonical rule with alwaysApply: true -->
<!-- Rules here are injected into ALL agent contexts. -->
<!-- Use only for truly global project conventions. -->

## Language & Style

- Use English for all code comments, log messages, and commit messages.
- Follow the style guide enforced by the project's linter.
- Keep functions and files small and focused (single responsibility).

## Testing

- Every new feature must include tests.
- Tests must not call external services — stub all integrations.
- Run the relevant tests before marking a task as complete.

## Security

- Never hardcode secrets, tokens, or credentials in code.
- Never log sensitive values (passwords, keys, tokens).

## Git

- Follow Conventional Commits: `feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`.
- Keep commits atomic and focused.
