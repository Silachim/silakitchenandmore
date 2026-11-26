import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const index = readFileSync(new URL("../index.html",import.meta.url),"utf8");
const admin = readFileSync(new URL("../admin.html",import.meta.url),"utf8");
const sql = readFileSync(
 new URL("../supabase/migrations/20261126_coordinated_order_workflow_STAGING.sql",import.meta.url),
 "utf8"
);

function scripts(html){
 return [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)]
   .map(m=>m[1]).filter(s=>s.trim());
}
test("customer and administrator inline JavaScript compiles",()=>{
 for(const [name,html] of [["index",index],["admin",admin]]){
  for(const js of scripts(html)) assert.doesNotThrow(
   ()=>new vm.Script(js,{filename:name+".html"}));
 }
});
test("customer checkout includes structured fulfillment and uses versioned RPCs",()=>{
 for(const id of ["oFulfillment","oRecipientType","oRecipientName",
    "oRecipientPhone","oDeliveryState","oDeliveryCity",
    "oDeliveryStreet","oDeliveryLandmark","oDeliveryInstructions",
    "oSurprise"]){
   assert.match(index,new RegExp("id=[\"']"+id+"[\"']"));
 }
 for(const name of ["submit_customer_order_v2","get_order_status_v2","submit_payment_v2"]){
   assert.ok(index.includes('sb.rpc("'+name+'"'),"missing "+name);
 }
 assert.ok(!index.includes('sb.rpc("submit_customer_order",{'));
});
test("admin has guarded payment and order workflows",()=>{
 for(const name of ["set_order_fulfillment","set_order_delivery_fee",
   "approve_order_for_payment","decline_order_request",
   "get_order_review_history","get_order_payment_summary",
   "verify_payment_v2","reject_payment_v2"]){
  assert.ok(admin.includes(name),"missing "+name);
 }
 assert.ok(admin.includes("ORDER_DECLINE_BACKEND_READY=false"),
   "feature gate must remain off until staging tests pass");
 assert.ok(!admin.includes("window.code="),"unsafe direct code path remains");
 assert.ok(!admin.includes('from("orders").update('),
   "unrestricted client orders update remains");
 assert.ok(admin.includes("pricingReviewed"),"seller pricing confirmation missing");
});
test("database script is a single explicit transaction with secure guards",()=>{
 assert.ok(sql.startsWith("-- Sila's Kitchen and More:"));
 assert.match(sql,/BEGIN;[\s\S]+COMMIT;/);
 for(const name of ["submit_customer_order_v2","get_order_status_v2",
  "submit_payment_v2","verify_payment_v2","reject_payment_v2",
  "set_order_fulfillment","set_order_delivery_fee",
  "approve_order_for_payment","decline_order_request",
  "get_order_review_history","get_order_payment_summary"]){
  assert.ok(sql.includes("FUNCTION public."+name+"("),"missing SQL "+name);
 }
 assert.ok(sql.includes("auth.uid()"),"admin authorization missing");
 assert.ok(sql.includes("FOR UPDATE"),"locking missing");
 assert.ok(sql.includes("payment_status='verified'"),
   "verified-only receipt aggregation missing");
 assert.ok(sql.includes("status='cancelled'"),"decline state missing");
 assert.ok(sql.includes("order_status_history"),"audit history missing");
});
