(() => {
  "use strict";

  const cfg = window.SILA_SUPABASE;
  if (!cfg || !cfg.url || !cfg.anonKey) {
    console.error("SILA_SUPABASE configuration is missing.");
    return;
  }

  const supabase = window.supabase.createClient(cfg.url, cfg.anonKey);
  const $ = (id) => document.getElementById(id);

  let session = null;

  function money(value) {
    return "₦" + Number(value || 0).toLocaleString("en-NG", {
      minimumFractionDigits: 0,
      maximumFractionDigits: 2
    });
  }

  function setStatus(message, type) {
    const el = $("status");
    el.textContent = message;
    el.className = "status show " + (type || "");
  }

  function clearStatus() {
    $("status").className = "status";
    $("status").textContent = "";
  }

  function cleanCode(value) {
    return String(value || "").trim().toUpperCase();
  }

  async function loadPayment() {
    clearStatus();
    const code = cleanCode($("paymentCode").value);

    if (!code) {
      setStatus("Please enter the payment code sent by Sila.", "error");
      return;
    }

    $("loadBtn").disabled = true;
    $("loadBtn").textContent = "Loading...";

    try {
      const response = await fetch(
        cfg.url + "/functions/v1/get-payment-session?code=" + encodeURIComponent(code),
        { headers: { apikey: cfg.anonKey } }
      );

      const data = await response.json();

      if (!response.ok) {
        throw new Error(data.error || "Payment code could not be found.");
      }

      session = data.session;
      $("summary").innerHTML =
        "<strong>Customer:</strong> " + escapeHtml(session.customer_name || "Customer") + "<br>" +
        "<strong>Order reference:</strong> " + escapeHtml(session.order_reference || "—") + "<br>" +
        "<strong>Order total:</strong> " + money(session.total_amount) + "<br>" +
        "<strong>Amount currently due:</strong> " + money(session.amount_due) + "<br>" +
        "<strong>Payment rule:</strong> " +
        (session.payment_rule === "85_percent_deposit"
          ? "85% deposit required"
          : "Full payment required") + "<br>" +
        "<strong>Status:</strong> " + escapeHtml(session.status);

      if (session.status !== "awaiting_payment") {
        $("uploadBtn").disabled = true;
        setStatus("This payment session is currently " + session.status.replaceAll("_", " ") + ".", "error");
      } else {
        $("uploadBtn").disabled = false;
        clearStatus();
      }

      $("paymentPanel").classList.remove("hidden");
    } catch (error) {
      $("paymentPanel").classList.add("hidden");
      setStatus(error.message || "Unable to load payment details.", "error");
    } finally {
      $("loadBtn").disabled = false;
      $("loadBtn").textContent = "Load Payment Details";
    }
  }

  async function uploadReceipt() {
    clearStatus();

    if (!session) {
      setStatus("Load your payment code first.", "error");
      return;
    }

    const file = $("receiptFile").files[0];
    const amountPaid = Number($("amountPaid").value);
    const note = $("customerNote").value.trim();

    if (!file) {
      setStatus("Please select your payment receipt.", "error");
      return;
    }

    if (!amountPaid || amountPaid <= 0) {
      setStatus("Please enter the amount you paid.", "error");
      return;
    }

    if (file.size > 10 * 1024 * 1024) {
      setStatus("The receipt must not be larger than 10MB.", "error");
      return;
    }

    const allowed = [
      "image/jpeg",
      "image/png",
      "image/webp",
      "application/pdf"
    ];

    if (!allowed.includes(file.type)) {
      setStatus("Only JPG, PNG, WEBP and PDF receipts are accepted.", "error");
      return;
    }

    $("uploadBtn").disabled = true;
    $("uploadBtn").textContent = "Preparing secure upload...";
    $("progressBar").style.width = "10%";

    try {
      // Step 1: ask the Edge Function for a short-lived signed upload token.
      const createResponse = await fetch(
        cfg.url + "/functions/v1/create-receipt-upload",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            apikey: cfg.anonKey
          },
          body: JSON.stringify({
            payment_code: session.payment_code,
            filename: file.name,
            content_type: file.type,
            file_size: file.size
          })
        }
      );

      const uploadInfo = await createResponse.json();

      if (!createResponse.ok) {
        throw new Error(uploadInfo.error || "Could not prepare the upload.");
      }

      $("progressBar").style.width = "35%";

      // Step 2: upload directly to the private Supabase Storage bucket
      // using the short-lived signed upload token.
      const { error: uploadError } = await supabase.storage
        .from(cfg.receiptBucket)
        .uploadToSignedUrl(
          uploadInfo.path,
          uploadInfo.token,
          file
        );

      if (uploadError) {
        throw uploadError;
      }

      $("progressBar").style.width = "75%";

      // Step 3: record the uploaded file against the payment session.
      const finalizeResponse = await fetch(
        cfg.url + "/functions/v1/finalize-receipt",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            apikey: cfg.anonKey
          },
          body: JSON.stringify({
            payment_code: session.payment_code,
            file_path: uploadInfo.path,
            original_filename: file.name,
            mime_type: file.type,
            file_size: file.size,
            amount_paid: amountPaid,
            customer_note: note
          })
        }
      );

      const result = await finalizeResponse.json();

      if (!finalizeResponse.ok) {
        throw new Error(result.error || "The receipt could not be recorded.");
      }

      $("progressBar").style.width = "100%";
      $("uploadBtn").disabled = true;
      $("uploadBtn").textContent = "Receipt Submitted";

      setStatus(
        "Payment receipt submitted successfully. Sila's Kitchen and More will verify the payment and update your order.",
        "success"
      );

      session.status = "receipt_submitted";
    } catch (error) {
      $("progressBar").style.width = "0";
      setStatus(error.message || "Receipt upload failed. Please try again.", "error");
      $("uploadBtn").disabled = false;
      $("uploadBtn").textContent = "Upload Receipt & Submit Payment";
    }
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (char) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#039;"
    }[char]));
  }

  $("loadBtn").addEventListener("click", loadPayment);
  $("uploadBtn").addEventListener("click", uploadReceipt);

  $("paymentCode").addEventListener("keydown", (event) => {
    if (event.key === "Enter") loadPayment();
  });
})();
