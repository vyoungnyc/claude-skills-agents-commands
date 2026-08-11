---
paths:
  - "**/*.{ts,tsx,mts,cts}"
---

# TypeScript & React Standards

- TypeScript strict mode; two-space indentation.
- camelCase (variables/functions), PascalCase (components/classes/types), SCREAMING_SNAKE_CASE (consts).
- Prefer named exports; colocate tests and styles when logical.
- Fix types properly — no blanket `any` or `@ts-ignore`. If unavoidable, comment why.

## React / Next.js

- Use shadcn/ui; prefer composition over forking components.
- Keep state minimal and localized; heavy state in hooks/stores.
- Prototype screens as static components under `UI_prototype/`.
- Accessibility basics always: labels, focus management, keyboard navigation.
- Handle loading, error, and empty states explicitly.

## Testing

- Unit/component tests: Jest or Vitest, colocated with the code or under `/tests`.
- E2E: Playwright under `/tests/e2e`; validate key user flows.
