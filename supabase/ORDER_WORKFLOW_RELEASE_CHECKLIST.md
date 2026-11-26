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

## Prerequisite inspections still required
1. Get definitions, `SECURITY DEFINER` flags, and grants for `submit_payment`, `verify_payment`, `reject_payment`, and `get_order_status`. Verify legacy payment and customer-status RPCs cannot bypass cancelled-order or verified-payment guards. Do not assume they are safe.
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
15. Do not remove `admin-orders.html` or `admin-payments.html` before their remaining functions have been checked. Monitor after release.

## Invariant
No order is considered paid merely because `payment_type='full'` or `payment_percent=100`; only a verified payment record counts as received. WhatsApp messages are prepared, **not automatically delivered**.

## Status checks
- JavaScript syntax validation: passed for `index.html` and `admin.html` in this branch.
- Supabase staging execution tests: **NOT RUN**.
- Production rollout: **NOT RUN**.
- Existing production approval function remains revoked from anonymous and authenticated clients, as reported by seller.
