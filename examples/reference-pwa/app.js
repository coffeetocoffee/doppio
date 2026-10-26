// Reference PWA Application Script
import { Doppio } from "/node_modules/@doppio/js/dist/index.js";
import { registerServiceWorker } from "/node_modules/@doppio/sw/dist/index.js";

// Register Service Worker
registerServiceWorker("/sw.js").then((reg) => {
  if (reg) console.log("Doppio Service Worker registered");
});

// Initial mock flags
const initialFlags = [
  {
    key: "new-checkout-flow",
    enabled: true,
    rolloutPercentage: 25,
    variations: [
      { key: "off", value: "false" },
      { key: "on", value: "true" },
    ],
    defaultVariation: 1,
  },
  {
    key: "enterprise-dashboard",
    enabled: true,
    rules: [
      {
        id: "ent-rule",
        priority: 1,
        expression: 'account.plan == "enterprise"',
        variation: 1,
      },
    ],
    variations: [
      { key: "standard", value: "Standard View" },
      { key: "vip", value: "Enterprise Analytics View" },
    ],
    defaultVariation: 0,
  },
  {
    key: "pricing-banner",
    enabled: true,
    rolloutPercentage: 100,
    variations: [
      { key: "banner-a", value: '{"title":"Save 20%","cta":"Upgrade"}' },
    ],
    defaultVariation: 0,
  },
];

let doppioClient = null;

async function bootstrap() {
  doppioClient = await Doppio.init({
    clientKey: "pwa_demo_key",
    environment: "production",
    offline: true,
    flags: initialFlags,
  });

  doppioClient.on("change", (changedKeys) => {
    console.log("Flags updated in PWA:", changedKeys);
    renderEvaluations();
  });

  renderEvaluations();
  setupEventListeners();
  updateNetworkStatus();
}

function getContext() {
  return {
    userId: document.getElementById("ctx-user").value || "anonymous",
    country: document.getElementById("ctx-country").value,
    plan: document.getElementById("ctx-plan").value,
  };
}

function renderEvaluations() {
  if (!doppioClient) return;
  const ctx = getContext();
  const grid = document.getElementById("flags-grid");
  grid.innerHTML = "";

  const flagKeys = ["new-checkout-flow", "enterprise-dashboard", "pricing-banner"];

  for (const key of flagKeys) {
    const res = doppioClient.get(key, ctx);
    const card = document.createElement("div");
    card.className = "flag-card";

    const stateClass = res.enabled ? "enabled" : "disabled";
    const stateText = res.enabled ? "ENABLED" : "DISABLED";
    const valText = typeof res.value === "object" ? JSON.stringify(res.value) : String(res.value);

    card.innerHTML = `
      <div class="flag-name">${res.flagKey}</div>
      <div class="flag-state ${stateClass}">${stateText}</div>
      <div class="flag-meta">
        <strong>Variation:</strong> ${res.variation || "none"}<br>
        <strong>Value:</strong> ${valText}<br>
        <strong>Reason:</strong> ${res.reason}<br>
        <strong>Bucket:</strong> ${res.bucket}
      </div>
    `;
    grid.appendChild(card);
  }

  // Update exposure log
  const exposures = doppioClient.getExposures();
  document.getElementById("exposure-count").textContent = String(exposures.length);
  document.getElementById("exposure-log").textContent = JSON.stringify(exposures.slice(-5), null, 2);
}

function setupEventListeners() {
  document.getElementById("btn-re-eval").addEventListener("click", () => {
    renderEvaluations();
  });

  let simulatedRollout = 50;
  document.getElementById("btn-toggle-rollout").addEventListener("click", () => {
    simulatedRollout = simulatedRollout === 50 ? 100 : 50;
    const updated = initialFlags.map((f) => {
      if (f.key === "new-checkout-flow") {
        return { ...f, rolloutPercentage: simulatedRollout };
      }
      return f;
    });
    doppioClient.setFlags(updated);
  });

  window.addEventListener("online", updateNetworkStatus);
  window.addEventListener("offline", updateNetworkStatus);
}

function updateNetworkStatus() {
  const el = document.getElementById("net-status");
  if (navigator.onLine) {
    el.className = "badge badge-online";
    el.textContent = "ONLINE";
  } else {
    el.className = "badge badge-offline";
    el.textContent = "OFFLINE";
  }
}

bootstrap();
