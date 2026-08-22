export type WhatsAppSendResult = {
  success: boolean;
  messageId?: string;
  error?: string;
  raw?: unknown;
};

function required(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function graphVersion(): string {
  return (Deno.env.get("WHATSAPP_GRAPH_VERSION") || "v23.0").trim();
}

function phoneNumberId(): string {
  return required("WHATSAPP_PHONE_NUMBER_ID");
}

function accessToken(): string {
  return required("WHATSAPP_ACCESS_TOKEN");
}

export async function sendWhatsAppText(
  to: string,
  body: string,
): Promise<WhatsAppSendResult> {
  const normalized = to.replace(/[^0-9]/g, "");
  if (!normalized) throw new Error("WhatsApp recipient number is empty.");

  const url = `https://graph.facebook.com/${graphVersion()}/${phoneNumberId()}/messages`;

  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: normalized,
      type: "text",
      text: {
        preview_url: false,
        body,
      },
    }),
  });

  const rawText = await response.text();
  let raw: unknown = rawText;
  try {
    raw = rawText ? JSON.parse(rawText) : null;
  } catch {
    // Keep the raw response text.
  }

  if (!response.ok) {
    const message =
      typeof raw === "object" && raw !== null
        ? JSON.stringify(raw)
        : String(raw);
    return { success: false, error: message, raw };
  }

  const messageId =
    typeof raw === "object" && raw !== null && "messages" in raw
      ? Array.isArray((raw as { messages?: unknown }).messages)
        ? String(
            ((raw as { messages: Array<{ id?: string }> }).messages[0] || {})
              .id || "",
          )
        : undefined
      : undefined;

  return { success: true, messageId, raw };
}

export function isAuthorizedInternalRequest(request: Request): boolean {
  const expected = Deno.env.get("WHATSAPP_INTERNAL_SECRET")?.trim();
  if (!expected) return false;

  const supplied = request.headers.get("x-whatsapp-internal-secret")?.trim();
  return Boolean(supplied) && supplied === expected;
}
