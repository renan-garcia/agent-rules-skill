---
description: Conventions for service layer files
alwaysApply: false
globs: src/services/**/*.ts,app/services/**/*.rb
---

# Service Layer Conventions

<!-- Example of a rule with globs: only activated for files inside services/ -->
<!-- The agent receives this rule automatically when editing files matched by the globs. -->

## Structure

- Each service file should contain a single, well-defined responsibility.
- Services must return a typed result (success/failure) — never throw for
  business-logic failures.
- Side effects (email, jobs, external calls) must be isolated and injected.

## Naming

- Services are named as verbs: `CreateOrder`, `SendNotification`, `ProcessPayment`.
- File names follow the same convention in snake_case: `create_order.rb` / `createOrder.ts`.

## Error handling

- Return errors as typed values; only raise/throw for truly unexpected conditions.
- Log errors at the service boundary, not deeper.
