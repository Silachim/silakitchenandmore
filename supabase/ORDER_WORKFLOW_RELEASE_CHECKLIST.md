# Sila order workflow: staging and release gate

**STATUS: NOT APPROVED FOR PRODUCTION.** This branch contains staged code only. Do not merge or execute the SQL directly against production until all checks pass.

## Canonical SQL
Use `supabase/migrations/20261126_coordinated_order_workflow_STAGING.sql` as the **only** coordinated database change. The earlier separate `*_DRAFT.sql` migration files have been removed from this branch. Run only the consolidated staging migration when authorized.

The staged SQL:
- Adds optional structured delivery, recipient and fee columns and a payment deadline.
- Creates `submit_customer_order_v2` while leaving the existing eight-argument checkout function intact.
- Creates `get_order_status_v2` scoped by order code and buyer phone.
- Adds protected `set_order_fulfillment` for old pending orders.
- Adds protected `set_order_delivery_fee`, `decline_order_request`, `get_order_review_history` and `get_order_payment_summary`.
- Replaces the incompatible `approve_order_for_payment` body with active-admin checks, a locked pending-order transition, a one-time code, a payment row, and status history.
- Adds versioned `submit_payment_v2`, `verify_payment_v2` and `reject_payment_v2` with appropriate customer/admin access.
- Restricts all privileged RPCs to authenticated roles, with server-side `auth.uid()` + `admin_users` checks.

## Legacy payment security review (completed from seller-provided SQL)

The old `verify_payment` and `reject_payment` are `SECURITY DEFINER`,
executable by `anon` and `authenticated`, and have **no admin check**.
They also reference obsolete columns such as `orders.order_status`.
Their execution grants must be revoked immediately using
`supabase/security/20261126_revoke_unsafe_legacy_admin_payment_functions.sql`.
The canonical coordinated migration revokes these grants again defensively.
This intentionally disables current legacy admin payment verification/rejection
until the v2 functions are installed and tested.

The old `submit_payment` and `get_order_status` also have public execution
grants, use obsolete order columns and lack the new status guards.
They remain temporarily accessible for compatibility with the current
production customer frontend. After the revised frontend is deployed and
confirmed to use the versioned functions, revoke these using
`supabase/security/20261126_post_cutover_revoke_legacy_customer_rpcs.sql`.

**Important:** The old customer RPCs might be callable from copies, bookmarks
or other clients, so review API logs/dependencies before removal.
Do not treat a SQL schema error as a security control.

## Immediate security verification (seller confirmed)

On November 26, 2026, the seller ran the privilege verification query and
confirmed both `reject_payment` and `verify_payment` return
`anonymous_can_execute=false`, `authenticated_can_execute=false`.
This follows the earlier confirmed restriction on the obsolete
`approve_order_for_payment` function.

## Schema preflight results (seller-provided)

**PASS for basic schema compatibility:** no required columns missing. Six
business tables have RLS enabled: `admin_users`, `orders`, `order_items`,
`payments`, `payment_receipts`, and `order_status_history`. Orders status
constraint permits all the staged transitions. Existing `orders` and
`payments` triggers only update timestamps. Payment enum supports
`not_required`, `awaiting_payment`, `payment_submitted`, `verified`,
`rejected`, and `refunded`. Previously unsafe admin functions
`approve_order_for_payment`, `verify_payment` and `reject_payment`
remain revoked for `anon` and `authenticated`.

**Not established by this preflight:** RLS policy conditions, API table grants,
function owner privileges, the existence of duplicate payment codes or
duplicate payment rows, storage receipt policies, or end-to-end function tests.

**Next read-only gate:** `supabase/security/20261126_rls_payment_integrity_readonly.sql`.
Do not execute the coordinated migration until this report is reviewed and
potential payment-integrity issues resolved.

## Payments and receipt viewing

The unified Payments section has been corrected to filter by `payment_status`
and expose Verify / Reject only when `payment_status='payment_submitted'`.
The payment detail modal now offers a signed receipt link for payments whose
`customer_note` contains the checkout-generated `Receipt storage path:` entry.
The signed URL is valid for 60 seconds and is opened only on seller action.
The `payment-receipts` bucket policies must explicitly support authorized
admin receipt viewing before this is considered complete.

## Staging preflight (next action)

Read-only file:
`supabase/security/20261126_staging_readonly_preflight.sql`

Run in the Supabase SQL Editor on the target schema **before** testing or
applying the migration, then inspect the JSON output for missing columns,
current RLS settings, triggers, constraints and EXECUTE grants.
This query reads schema metadata only, not customer records.

During source review, the unified admin Payments view was found to use a
nonexistent `payments.status` field. It now uses the real
`payments.payment_status` enum and shows verification/rejection actions
only for submitted payments. This correction has not been tested against
staging yet.

## Prerequisite inspections still required
1. Legacy definitions and permissions inspected: all four were executable by `anon`; old verification/rejection are **unsafe**. Verify hotfix revocations and test safe legacy cutover; review other executable definer functions as a separate security audit.
2. Inspect RLS privileges for `orders`, `payments`, `order_status_history`, `admin_users`, and receipt storage policies.
3. Confirm pricing trust boundary: the current public checkout sends calculated unit prices, and both old submission RPC and staged v2 trust submitted prices. The seller must check each item, customization and subtotal before approval; the frontend now requires that confirmation. Server-side catalog/configurable-product price verification remains a prerequisite for fully automated payment approval.
4. Verify amount-due business rule: currently 85% of product subtotal above ₦50,000, otherwise 100%, **plus 100% of delivery fee**. Confirm with seller, especially whether a deposit may be applied to delivery charges.
5. Verify delivery, recipient and buyer privacy in WhatsApp handoffs. The `is_surprise_order` flag instructs seller to contact buyer first, but does not itself prevent misuse by authorized staff.

## Release sequence
1. Back up production database and confirm rollback route.
2. Clone production schema (not sensitive customer data) into staging; manually seed fake admins and orders.
3. Validate SQL syntax, table constraints, privileges and migration against staging.
4. Test function authorizations as anonymous, nonadmin authenticated, active admin, and deactivated admin; include all v2 payment RPCs.
5. Test new checkout: buyer=self/other, surprise, pickup, delivery, required address, optional landmark and instructions, custom small-chops metadata, date rule, and duplicate submissions.
6. Test old order: no fulfillment_method, seller classifies pickup/delivery; delivery fee required for delivery; no fee for pickup.
7. Test quote: free delivery (₦0), positive fee, invalid negative fee, re-quote before approval; check `amount_due` and history.
8. Test approval: exactly one payment record/code, expected amount and due timestamp; retry and simultaneous approvals fail. Verify no approval of cancelled, submitted or verified orders.
9. Test decline: required reason, one history event, no payment record, cancelled order not payable; repeat decline fails.
10. Test payment submission, verification, rejection and resubmission; validate verified-only receipts and remaining balances. Check old payment-function grants and safe legacy cutover. Refunds need a separately reviewed process; no automatic refunds are implemented. **Do not conduct real payment transactions in staging.**
11. Test order tracker: matching code+phone, incorrect phone, pending quote, awaiting payment, submitted, verified, cancelled. Ensure no unrelated customer data leaks.
12. Test admin dashboard tabs, item customization, orders/history, buyer/recipient details, fee quote, WhatsApp message link (manual send), payments and Gallery/Training unaffected.
13. Verify responsive/mobile checkout; test unexpected network errors and duplicate clicks.
14. Only after all tests pass: apply the coordinated SQL to production first, verify permissions and functions, change the frontend feature flag `ORDER_DECLINE_BACKEND_READY` to `true` on the reviewed branch, then merge frontend to main and verify GitHub Pages.
15. After frontend cutover tests, revoke legacy `submit_payment` and `get_order_status` with the separate post-cutover SQL, then verify permissions. Do not remove `admin-orders.html` or `admin-payments.html` before their remaining functions have been checked. Monitor after release.

## Invariant
No order is considered paid merely because `payment_type='full'` or `payment_percent=100`; only a verified payment record counts as received. WhatsApp messages are prepared, **not automatically delivered**.

## Status checks
- JavaScript syntax validation: passed for `index.html` and `admin.html` in this branch.
- Initial schema compatibility preflight: **PASSED** (seller-supplied report).
- RLS/payment-integrity release gate: **WAITING FOR REPORT**.
- Supabase staging execution tests: **NOT RUN**.
- Production rollout: **NOT RUN**.
- Existing production approval function remains revoked from anonymous and authenticated clients, as reported by seller.
- Legacy `verify_payment` / `reject_payment` privileged-function revocation: **VERIFIED** by seller: both `anon` and `authenticated` now return false.
- Four legacy payment/status RPC definitions inspected from seller-provided SQL.
