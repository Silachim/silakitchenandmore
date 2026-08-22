import { isAuthorizedInternalRequest, sendWhatsAppText } from "../_shared/whatsapp.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-whatsapp-internal-secret",
  "Content-Type": "application/json",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: corsHeaders,
  });
}

function escapeText(value: unknown): string {
  return String(value ?? "").trim();
}

function formatMoney(value: unknown): string {
  const amount = Number(value ?? 0);
  if (!Number.isFinite(amount)) return "₦0.00";
  return `₦${amount.toLocaleString("en-NG", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return json({ success: false, error: "POST required." }, 405);
  }

  if (!isAuthorizedInternalRequest(request)) {
    return json({ success: false, error: "Unauthorized." }, 401);
  }

  try {
    const payload = await request.json();
    const record = payload?.record ?? payload?.new ?? payload;

    const orderId = escapeText(record?.id);
    const orderCode = escapeText(record?.order_code || record?.order_number);
    const customerName = escapeText(record?.customer_name);
    const customerPhone = escapeText(record?.customer_phone);
    const desiredDate = escapeText(record?.desired_date);
    const notes = escapeText(record?.notes || record?.customer_notes);
    const amountDue = record?.amount_due ?? record?.total_amount ?? record?.subtotal;

    if (!orderId || !orderCode || !customerName || !customerPhone) {
      return json({
        success: false,
        error: "Webhook payload is missing id, order_code/order_number, customer_name, or customer_phone.",
      }, 400);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim();
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
    const adminNumber = Deno.env.get("SILA_ADMIN_WHATSAPP_NUMBER")?.trim();

    if (!supabaseUrl || !serviceRoleKey || !adminNumber) {
      throw new Error("Missing SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, or SILA_ADMIN_WHATSAPP_NUMBER.");
    }

    const itemResponse = await fetch(
      `${supabaseUrl}/rest/v1/order_items?order_id=eq.${encodeURIComponent(orderId)}&select=item_name,quantity,unit_price,line_total,metadata`,
      {
        headers: {
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
        },
      },
    );

    const itemText = await itemResponse.text();
    let items: Array<Record<string, unknown>> = [];
    try {
      items = itemText ? JSON.parse(itemText) : [];
    } catch {
      throw new Error(`Unable to parse order items response: ${itemText}`);
    }

    if (!itemResponse.ok) {
      throw new Error(`Unable to load order items: ${itemText}`);
    }

    const itemLines = items.length
      ? items.map((item) => {
          const name = escapeText(item.item_name || item.product_name || "Item");
          const quantity = Number(item.quantity ?? 1);
          const lineTotal = item.line_total ?? Number(item.unit_price ?? 0) * quantity;
          return `• ${name} × ${quantity} — ${formatMoney(lineTotal)}`;
        }).join("\n")
      : "• Order items are available on the Sila order dashboard.";

    const message = [
      "🔔 NEW SILA ORDER",
      "",
      `Order: ${orderCode}`,
      `Customer: ${customerName}`,
      `Phone: ${customerPhone}`,
      `Desired date: ${desiredDate || "Not specified"}`,
      `Amount: ${formatMoney(amountDue)}`,
      "",
      "Items:",
      itemLines,
      notes ? `\nNotes: ${notes}` : "",
      "",
      "Status: PENDING REVIEW",
      "",
      `Review this order in Sila's website/admin system: ${supabaseUrl}`,
    ].filter(Boolean).join("\n");

    const result = await sendWhatsAppText(adminNumber, message);

    const logPayload = {
      order_id: orderId,
      direction: "outbound",
      channel: "whatsapp",
      recipient_phone: adminNumber,
      message_type: "new_order_notification",
      message_body: message,
      provider_message_id: result.messageId ?? null,
      status: result.success ? "sent" : "failed",
      error_message: result.error ?? null,
    };

    const logResponse = await fetch(`${supabaseUrl}/rest/v1/whatsapp_messages`, {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
        Prefer: "return=minimal",
      },
      body: JSON.stringify(logPayload),
    });

    if (!logResponse.ok) {
      const logError = await logResponse.text();
      console.error("WhatsApp log insert failed:", logError);
    }

    if (!result.success) {
      console.error("WhatsApp send failed:", result.error);
      return json({ success: false, error: result.error }, 502);
    }

    return json({
      success: true,
      order_id: orderId,
      order_code: orderCode,
      whatsapp_message_id: result.messageId ?? null,
    });
  } catch (error) {
    console.error("whatsapp-order-notifier error:", error);
    return json({
      success: false,
      error: error instanceof Error ? error.message : String(error),
    }, 500);
  }
});
