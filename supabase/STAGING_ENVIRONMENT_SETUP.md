# Sila's Kitchen and More — staging environment runbook

**Status: Preparation only.** This repository branch is not a Supabase database branch. GitHub staging code must never be mistaken for an isolated database.

## Free-tier recommended path

On the Supabase Free Plan, hosted Branching is not included and additional free projects are limited. **Use the local Windows staging guide instead:** [LOCAL_STAGING_FREE_TIER_WINDOWS.md](LOCAL_STAGING_FREE_TIER_WINDOWS.md). The hosted branch/project instructions below are alternatives only if the account has available capacity or a paid plan. Never attempt to bypass account limits with production SQL.

## Preferred isolation (only when hosted branching is available)
Use **Supabase Dashboard → Branches → Create branch** on the Sila production Supabase project, selecting a persistent staging branch if supported by the plan. Name it `sila-order-workflow-staging`. Ensure **production data is NOT included**. Supabase documents that branches have isolated credentials and can copy schema without production data. If branching is not available, create a **separate Supabase project** and import only a reviewed schema-only baseline, never production customer data.

**Verify the project/branch identity twice** before any SQL. Do not run the staging migrations in production or from an SQL editor attached to the production branch.

Reference: https://supabase.com/docs/guides/deployment/branching/dashboard

## Staging bootstrap
1. Confirm the branch has the production application's baseline schema: public tables, public functions used by checkout, Supabase storage buckets, enum types, RLS policies, and any extension dependencies. An empty new project is **not** sufficient for our incremental SQL.
2. Create a fresh test-only administrator user in staging Auth and register that user in staging `public.admin_users` using its actual schema. Do not copy real user accounts or passwords.
3. Use fictional buyer/recipient names and phone numbers; do not connect staging to real WhatsApp contacts, payment processors, or delivery providers. Keep the test site unindexed and access-restricted.
4. Inspect `supabase/security/20261126_staging_readonly_preflight.sql` and `supabase/security/20261126_rls_payment_integrity_readonly.sql` **on staging**. The production inspection already showed no required columns missing, no duplicate payment codes and RLS enabled; staging must separately confirm that baseline.
5. Apply `supabase/migrations/20261126_coordinated_order_workflow_STAGING.sql` first **on staging only**, after schema review.
6. Apply `supabase/migrations/20261126_receipt_storage_and_admin_payment_access_STAGING.sql` second **on staging only**, after reviewing Storage policies for this branch.
7. Run `supabase/security/20261126_staging_post_migration_verify.sql`. Resolve any failure; do not enable the website's backend-readiness flag yet.
8. Configure a separate staging frontend with staging Supabase URL and **public publishable/anon key only**. Never embed a service-role or secret key in GitHub/HTML. Do not point the production domain or frontend at staging.
9. Exercise customer, administrator, payment and receipt scenarios with fake data and verify no data appears in production.
10. Leave all production approval/verify/reject grants restricted until a **separately approved** coordinated backend-first production cutover and frontend launch.

## Expected functional acceptance tests
- Guest: submit order pickup; submit delivery to buyer; send to another recipient; buyer-first surprise contact; custom small-chops metadata; missing delivery address rejected; order due-date rule.
- Seller: view pending order and structured details; confirm legacy delivery/pickup; quote a nonnegative delivery fee including free delivery; approve exactly once; decline pending order with reason; verify audit trail.
- Guest: check status with correct and wrong phone; receipt upload to `payment-receipts` only for matching order/payment code and an awaiting-payment order; repeat submission and cancelled order rejected.
- Seller: view payment and private receipt through signed URL; verify/reject only submitted payments; verified-only income; remaining balance after 85% product deposit.
- Security: anonymous/nonadmin/authenticated but inactive-admin denied all privileged admin RPCs; public cannot view another customer's order or receipt; no public receipt-bucket SELECT.
- Concurrency: simultaneous approval and decline; double approvals; repeated payment submissions and verification.
- Failures: invalid prices and amounts; receipt mime/size; expired payment deadline; interrupted upload; delivery fee edit while payment exists.
- Operational: no live WhatsApp notifications from test data and no accidental real transactions.

## Separate blockers before production
- Pricing: customer checkout currently transmits `unit_price` from the browser; staging v2 trusts that value. A seller checkbox alone does not make an unauthenticated payment amount authoritative. Implement server-verified product prices or a seller-confirmed server-side quote before production.
- Staging payment/receipt flows require end-to-end authorization tests and potential rate limiting.
- SQL migration syntax and role ownership must be verified on staging, not inferred from JavaScript tests.
- Confirm deposit policy: currently 85% of product subtotal over ₦50,000, else 100%, **plus 100% of delivery fee**.
- Supabase Auth/Storage branch configuration and GitHub Pages staging host are separate from database branching.

## Production safety
GitHub Pages currently deploys `main`, which was restored in PR #4. Do not merge staged client code or activate `ORDER_DECLINE_BACKEND_READY` until the backend has passed staged tests and a controlled deployment plan is approved.
