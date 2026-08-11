---
paths:
  - "**/*.tf"
  - "**/*.tfvars"
  - "**/prisma/**"
  - "**/*.prisma"
---

# Database & Infrastructure Standards

## Prisma

- Schema lives in `prisma/schema.prisma`; commit all migrations.
- Use an isolated test database.
- Never hardcode connection strings — use `DATABASE_URL` from env.
- Row-level security on all applicable tables.

## Terraform

- Plan → review → apply. Never apply without a reviewed plan.
- Least-privilege IAM for all roles and policies.
- Runbooks live in `/docs/runbooks/`.
