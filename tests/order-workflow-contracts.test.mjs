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
test("frontend RPC contract matches rollback or staged deployment mode",()=>{
 for(const id of ["oFulfillment","oRecipientType","oRecipientName","oRecipientPhone","oDeliveryState","oDeliveryCity","oDeliveryStreet","oDeliveryLandmark","oDeliveryInstructions","oSurprise"]){
  assert.match(index,new RegExp("id=[\\\x22']"+id+"[\\\x22']"));
 }
 const v2=index.includes('sb.rpc("submit_customer_order_v2",{');
 if(v2){
  for(const name of ["submit_customer_order_v2","get_order_status_v2","submit_payment_v2"])assert.ok(index.includes('sb.rpc(" '.trim()+'"'+name+'"'),"missing "+name);
 }else{
  assert.ok(index.includes('sb.rpc("submit_customer_order",{'),"rollback must use pre-v2 checkout");
  assert.ok(index.includes('sb.rpc("get_order_status",{'),"rollback must use pre-v2 tracker");
  assert.ok(index.includes('sb.rpc("submit_payment",{'),"rollback must use pre-v2 payment");
 }
});
test("admin staging guard or rollback mode",()=>{
 if(admin.includes("ORDER_DECLINE_BACKEND_READY=false")){
  assert.ok(admin.includes("decline_order_request"));
  assert.ok(!admin.includes("window.code="));
 }else{
  assert.ok(!admin.includes("decline_order_request"),"rollback should restore pre-PR3 admin");
  assert.ok(admin.includes('sb.rpc("approve_order_for_payment"'));
 }
});
test("private receipt migration remains staged",()=>{
 const policies=readFileSync(new URL("../supabase/migrations/20261126_receipt_storage_and_admin_payment_access_STAGING.sql",import.meta.url),"utf8");
 for(const name of ["Sila active admins can view payments","Sila customers can upload pending payment receipts","Sila active admins can view payment receipts"])assert.ok(policies.includes(name));
 assert.equal((policies.match(/^BEGIN;$/gm)||[]).length,1);
 assert.equal((policies.match(/^COMMIT;$/gm)||[]).length,1);
});
test("database script is a single explicit transaction with secure guards",()=>{
 assert.ok(sql.startsWith("-- Sila's Kitchen and More:"));
 assert.match(sql,/BEGIN;[\s\S]+COMMIT;/);
 assert.equal((sql.match(/^BEGIN;$/gm)||[]).length,1);
 assert.equal((sql.match(/^COMMIT;$/gm)||[]).length,1);
 assert.equal((sql.match(/CREATE OR REPLACE FUNCTION public\./g)||[]).length,11);
 assert.ok(!sql.includes("sila_valid_payment_receipt_upload_path"));
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
