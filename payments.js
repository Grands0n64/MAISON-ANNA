/* MAISON ANNA PAYMENT SUBMISSION
 * Uses the Supabase publishable key only. Never put a service-role key here.
 */
(() => {
  const SUPABASE_URL = "https://ypzseilwcmvrzcjxanrs.supabase.co";
  const SUPABASE_KEY = "sb_publishable_jgOjltlzCN42FWFiroFmig_VCW0TCZq";
  const BTC = "1HxpFiB5fpL2oPoxFcPiGB7JcHFauqzs2o";
  const USDT = "0x6588cd478cf2b229e72fa9c81f983d7922d8a840";
  const form = document.getElementById("deliveryForm");
  if (!form || !window.supabase) return;
  const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
  const submit = form.querySelector('button[type="submit"]');
  const box = document.createElement("section");
  box.className = "payment-panel";
  box.style.cssText = "margin:20px 0;padding:18px;background:#fff;border:1px solid #F5C6D4;border-radius:18px";
  box.innerHTML = `
    <h2 style="margin:0 0 8px">Payment method</h2>
    <p>Pay with Bitcoin, USDT (BEP20), or submit gift cards for manual review. Card payments via Paystack will be added later.</p>
    <label><input type="radio" name="paymentMethod" value="bitcoin" required> Bitcoin (BTC) — Bitcoin mainnet</label>
    <label><input type="radio" name="paymentMethod" value="usdt_bep20"> USDT — BNB Smart Chain (BEP20)</label>
    <label><input type="radio" name="paymentMethod" value="gift_card"> Gift card — manual review</label>
    <div id="ma-crypto" hidden style="margin-top:12px;padding:12px;background:#FFF5F8;border-radius:12px">
      <strong id="ma-wallet-title"></strong><p id="ma-wallet" style="overflow-wrap:anywhere;font-weight:800"></p>
      <button type="button" id="ma-copy">Copy wallet address</button>
      <p id="ma-network"></p>
      <label>Transaction hash / reference<input id="ma-tx" autocomplete="off" placeholder="Paste transaction hash" /></label>
    </div>
    <div id="ma-gift" hidden style="margin-top:12px;padding:12px;background:#FFF5F8;border-radius:12px">
      <p>Add each gift card separately. Multiple photos are accepted for every card.</p>
      <div id="ma-cards"></div><button type="button" id="ma-add">+ Add another card</button>
    </div>
    <p id="ma-status" role="status" style="margin-top:12px"></p>
  `;
  submit.parentNode.insertBefore(box, submit);
  const $ = id => document.getElementById(id);
  let wallet = "";
  const methodInputs = [...form.querySelectorAll('[name="paymentMethod"]')];
  function addCard() {
    const card = document.createElement("fieldset");
    card.style.cssText = "margin:12px 0;padding:12px;border:1px solid #F5C6D4;border-radius:12px";
    card.innerHTML = `
      <legend>Gift card</legend>
      <label>Provider<input class="ma-provider" required placeholder="Amazon, Apple, Google Play, etc."></label>
      <label>Card amount<input class="ma-amount" type="number" min="0.01" step="0.01" required></label>
      <label>Currency<select class="ma-currency"><option>USD</option><option>EUR</option><option>GBP</option><option>CAD</option><option>AUD</option></select></label>
      <label>Gift card code<input class="ma-code" required autocomplete="off"></label>
      <label>Photo(s)<input class="ma-photos" type="file" accept="image/jpeg,image/png,image/webp,image/heic" multiple required></label>
      <small>Maximum 5 MB per photo. Upload clear card images.</small>
      <button type="button" class="ma-remove">Remove card</button>`;
    card.querySelector(".ma-remove").onclick = () => card.remove();
    $("ma-cards").appendChild(card);
    card.querySelectorAll("input,select,textarea").forEach(control => { control.disabled = !$("ma-gift") || $("ma-gift").hidden; });
  }
  $("ma-add").onclick = addCard;
  addCard();
  function setGiftFieldsEnabled(enabled) {
    $("ma-cards").querySelectorAll("input,select,textarea").forEach(control => {
      control.disabled = !enabled;
    });
  }
  setGiftFieldsEnabled(false);
  methodInputs.forEach(input => input.addEventListener("change", () => {
    const crypto = input.value === "bitcoin" || input.value === "usdt_bep20";
    const gift = input.value === "gift_card";
    $("ma-crypto").hidden = !crypto;
    $("ma-gift").hidden = !gift;
    setGiftFieldsEnabled(gift);
    $("ma-tx").required = crypto;
    if (input.value === "bitcoin") {
      wallet = BTC; $("ma-wallet-title").textContent = "Bitcoin receiving address";
      $("ma-wallet").textContent = BTC;
      $("ma-network").textContent = "Bitcoin mainnet only. Do not send through another network.";
    } else if (input.value === "usdt_bep20") {
      wallet = USDT; $("ma-wallet-title").textContent = "USDT receiving address";
      $("ma-wallet").textContent = USDT;
      $("ma-network").textContent = "BNB Smart Chain (BEP20) only. Do not use ERC20 or TRC20.";
    }
  }));
  $("ma-copy").onclick = async () => {
    try { await navigator.clipboard.writeText(wallet); $("ma-copy").textContent = "Copied"; }
    catch { $("ma-status").textContent = "Copy unavailable. Select and copy the address manually."; }
  };
  const status = message => { $("ma-status").textContent = message; };
  const cleanFile = name => name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-90);
  async function saveGiftCards(customer) {
    const submissionId = crypto.randomUUID();
    const records = [];
    const cards = [...$("ma-cards").querySelectorAll("fieldset")];
    if (!cards.length) throw new Error("Add at least one gift card.");
    for (const card of cards) {
      const provider = card.querySelector(".ma-provider").value.trim();
      const amount = Number(card.querySelector(".ma-amount").value);
      const currency = card.querySelector(".ma-currency").value;
      const code = card.querySelector(".ma-code").value.trim();
      const files = [...card.querySelector(".ma-photos").files];
      if (!provider || !code || !(amount > 0) || !files.length) throw new Error("Complete each gift card and attach at least one photo.");
      const photoPaths = [];
      for (const file of files) {
        if (!file.type.startsWith("image/") || file.size > 5 * 1024 * 1024) throw new Error("Photos must be images no larger than 5 MB each.");
        const path = submissionId + "/" + crypto.randomUUID() + "-" + cleanFile(file.name);
        const { error } = await db.storage.from("gift-card-evidence").upload(path, file, { contentType:file.type, upsert:false });
        if (error) throw error;
        photoPaths.push(path);
      }
      records.push({submission_id:submissionId,customer_name:customer.customer_name,customer_email:customer.customer_email,gift_card_provider:provider,card_amount:amount,currency,gift_card_code:code,photo_paths:photoPaths,review_status:"pending"});
    }
    const { error } = await db.from("gift_card_submissions").insert(records);
    if (error) throw error;
    return {count:records.length, reference:submissionId};
  }
  form.addEventListener("submit", async event => {
    event.preventDefault();
    event.stopImmediatePropagation();
    if (!form.reportValidity()) return;
    const method = form.querySelector('[name="paymentMethod"]:checked')?.value;
    if (!method) return status("Choose a payment method.");
    const f = Object.fromEntries(new FormData(form));
    const cart = (() => { try { return JSON.parse(sessionStorage.getItem("maisonAnnaCart") || "{}"); } catch { return {}; } })();
    if (!Array.isArray(cart.items) || !cart.items.length) return status("Your cart is empty. Return to the shop and add flowers.");
    const customer = {customer_name:f.name.trim(),customer_email:f.email.trim(),customer_phone:f.phone.trim(),country:f.country,state:f.state || null,city:f.city.trim(),delivery_address:f.address.trim(),postal_code:f.postal || null};
    submit.disabled = true; submit.textContent = "SUBMITTING…"; status("");
    try {
      if (method === "gift_card") {
        const giftResult = await saveGiftCards(customer);
        status(giftResult.count + " gift card(s) submitted for manual review. Reference: " + giftResult.reference + ". Check status at payment-status.html. This is not payment confirmation.");
        $("ma-cards").innerHTML = ""; addCard(); form.reset();
      } else {
        const tx = $("ma-tx").value.trim();
        if (!tx) throw new Error("Enter the transaction hash or reference.");
        const {data:orderReference,error} = await db.rpc("ma_create_crypto_order",{p_order:{...customer,cart_items:cart.items,total_amount:Number(cart.total || 0),currency:"USD",payment_method:method,transaction_hash:tx,payment_network:method === "bitcoin" ? "Bitcoin mainnet" : "BNB Smart Chain (BEP20)",customer_notes:"Delivery: " + (f.shipping || "Not selected") + ". Notes: " + (f.notes || "")}});
        if (error) throw error;
        status("Order submitted. Payment is PENDING VERIFICATION. Reference: " + (orderReference || "Contact Maison Anna for your reference") + ". Check status at payment-status.html.");
        form.reset(); $("ma-crypto").hidden = true; wallet = "";
      }
    } catch (error) { status("Submission failed: " + (error.message || "Please try again.")); }
    finally { submit.disabled = false; submit.textContent = "SUBMIT ORDER & PAYMENT DETAILS"; }
  }, true);
})();