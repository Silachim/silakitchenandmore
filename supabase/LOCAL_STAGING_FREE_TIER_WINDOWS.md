# Sila's Kitchen and More: Free-tier local staging (Windows)

**No Supabase paid plan or second hosted project is needed.** Local staging uses Docker Desktop and the Supabase CLI on your computer.

Official instructions:
- https://supabase.com/docs/guides/local-development/cli/getting-started
- https://supabase.com/docs/guides/local-development/cli-workflows
- https://supabase.com/docs/guides/local-development/local-and-hosted-projects

## Critical production safeguards

The GitHub branch `staging/sila-order-workflow-20261126` is not itself a database. The GitHub Pages site still deploys `main`; do not change its Supabase credentials.

**Do not run `supabase db push`, `supabase db reset --remote`, `supabase db reset --linked`, or `supabase db reset --db-url`.** Never run local tests with the production database URL or secret. Do not save production database passwords in this repository.

**Do not run `npx supabase start` / `db reset` from this repository's existing `supabase` directory without first preparing the baseline**: there are incremental staging migration files but no confirmed complete baseline schema migration for this project. Running them against an empty database will fail or leave a misleading partial setup.

## Phase 1: local prerequisites (Windows PowerShell)

1. Install Docker Desktop: https://www.docker.com/products/docker-desktop/
2. Start Docker Desktop; verify Linux containers are running.
3. Install Node.js LTS (if needed): https://nodejs.org/
4. In PowerShell, verify:
   ```powershell
   docker version
   node --version
   npm --version
   ```
5. Create a **separate** local directory, outside the production repository:
   ```powershell
   New-Item -ItemType Directory -Force "$HOME\Desktop\sila-local-staging" | Out-Null
   Set-Location "$HOME\Desktop\sila-local-staging"
   npm init -y
   npm install --save-dev supabase
   npx supabase init
   ```
   Do not link this folder to the production project. `supabase init` creates only local config files.
6. Start the local services:
   ```powershell
   npx supabase start
   npx supabase status
   ```
   The CLI reports a local API URL and keys. Treat keys as project-specific credentials; never commit secrets. You can use local Studio for inspection.

## Phase 2: prepare a schema-only baseline

The Sila-specific database schema, functions, enums, triggers and policies must be present before running the two incremental staging migrations. The repository currently includes only those incremental migrations, so **starting local Supabase alone is not sufficient**.

Recommended approach:
- Obtain a **schema-only** export of the production application's *public* schema (not customer data), through a reviewed, read-only remote dump workflow. Confirm that no INSERT/COPY statements, customer details, auth users or secrets appear.
- Also separately capture needed Storage bucket definitions and any custom policies/functions in the managed `storage` schema. Local Supabase creates managed schemas itself; do not blindly import a full managed schema dump on top of them.
- Import the reviewed baseline into the *local* Supabase database only, using its localhost connection. Confirm needed tables and functions exist and no real customer rows were copied.
- Add fictional users and test data. Authenticate through **local Auth**, not production Auth.

A schema dump is not a production migration command. Never run a dump's restore against production. Before using the CLI with remote options, confirm the current Supabase CLI syntax from its official documentation.

## Phase 3: apply and test incremental migrations locally

Apply in order to the local database only, after the baseline is verified:
1. `supabase/migrations/20261126_coordinated_order_workflow_STAGING.sql`
2. `supabase/migrations/20261126_receipt_storage_and_admin_payment_access_STAGING.sql`

Then run:
- `supabase/security/20261126_staging_post_migration_verify.sql`
- `tests/order-workflow-contracts.test.mjs` static tests
- Manual/API tests for pickup, delivery, order approval, decline, receipt upload, payment submission/rejection/verification and role permissions.

**Do not simply copy all migrations into local `supabase/migrations` and run `db reset`** without sequencing the baseline first.

## Phase 4: localhost-only frontend testing

Run a **separate** local copy of the site, using the local API URL and local anon/publishable key. Use only fictional customer names, phones and addresses. Disable real WhatsApp notification links during testing. Never open the production domain with local test credentials. Once complete, retain database test results in the staging branch; production deployment is a separate review.

## Help requested in this chat

Share the output of `docker version`, `node --version` and `npm --version` **without any tokens, passwords or API keys**. We can then perform the next local staging steps with the verified setup.
