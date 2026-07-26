
const express = require('express');
const axios = require('axios');
const nodemailer = require('nodemailer');
const path = require('path');
const fs = require('fs');
const { randomUUID } = require('crypto');
require('dotenv').config();

const app = express();
app.use(express.json({ limit: '8mb' }));

const REPO_ROOT = path.resolve(__dirname, '..');
const RUNTIME_DIR = path.join(REPO_ROOT, 'runtime');
const INSTALL_IDENTITY_PATH = path.join(RUNTIME_DIR, 'install.identity.json');

// Allow Flutter web dev server and deployed frontends to call this API.
app.use((req, res, next) => {
  const corsOrigin = process.env.CORS_ORIGIN || '*';
  res.header('Access-Control-Allow-Origin', corsOrigin);
  res.header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') {
    return res.sendStatus(204);
  }
  return next();
});

// Serve demo web files from /web
app.use(express.static(path.join(__dirname, 'web')));

const { PORT = 3000 } = process.env;
const SUPABASE_URL = (process.env.SUPABASE_URL || '').trim();
const SUPABASE_SERVICE_ROLE_KEY = (process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
const AUTO_CLOSE_BATCH_SCHEDULER_ENABLED =
  (process.env.AUTO_CLOSE_BATCH_SCHEDULER_ENABLED || 'false').toLowerCase() === 'true';
const AUTO_CLOSE_BATCH_CHECK_INTERVAL_SEC =
  Number(process.env.AUTO_CLOSE_BATCH_CHECK_INTERVAL_SEC || '60');
const SPIN_AUTOCLOSE_SANDBOX =
  (process.env.SPIN_AUTOCLOSE_SANDBOX || 'true').toLowerCase() === 'true';
const AUTO_CLOSE_BATCH_API_KEY = (process.env.AUTO_CLOSE_BATCH_API_KEY || '').trim();
const SMTP_HOST = (process.env.SMTP_HOST || '').trim();
const SMTP_PORT = Number(process.env.SMTP_PORT || '587');
const SMTP_SECURE = (process.env.SMTP_SECURE || 'false').toLowerCase() === 'true';
const SMTP_USER = (process.env.SMTP_USER || '').trim();
const SMTP_PASS = (process.env.SMTP_PASS || '').trim();
const SMTP_FROM = (process.env.SMTP_FROM || '').trim();
const SMTP_REPLY_TO = (process.env.SMTP_REPLY_TO || '').trim();

const _autoCloseRunMemo = new Map();

const HPP_CHECKOUT_BASE_URL = (process.env.HPP_CHECKOUT_BASE_URL || '').trim();
const HPP_TOKEN_QUERY_PARAM = (process.env.HPP_TOKEN_QUERY_PARAM || 'authToken').trim();
const HPP_AMOUNT_QUERY_PARAM = (process.env.HPP_AMOUNT_QUERY_PARAM || 'amount').trim();
const HPP_REFERENCE_QUERY_PARAM = (process.env.HPP_REFERENCE_QUERY_PARAM || 'referenceId').trim();
const PAAAYIT_REQUESTS_ENABLED =
  (process.env.PAAAYIT_REQUESTS_ENABLED || 'false').toLowerCase() === 'true';
const PAAAYIT_REQUESTS_DEFAULT_EXPIRY_HOURS = Number(
  process.env.PAAAYIT_REQUESTS_DEFAULT_EXPIRY_HOURS || '72',
);
const IPOS_HPP_API_BASE_URL =
  (process.env.IPOS_HPP_API_BASE_URL || 'https://payment.ipospays.tech/api/v1').trim();
const IPOS_HPP_API_TOKEN = (process.env.IPOS_HPP_API_TOKEN || '').trim();
const IPOS_HPP_VERIFY_TIMEOUT_MS = Number(process.env.IPOS_HPP_VERIFY_TIMEOUT_MS || '20000');
const PAAAYIT_WEBHOOK_SECRET = (process.env.PAAAYIT_WEBHOOK_SECRET || '').trim();
const PAAAYIT_CALLBACK_BASE_URL = (process.env.PAAAYIT_CALLBACK_BASE_URL || '').trim();

function waitMs(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function buildHostedPaymentUrlFromAuthToken({
  hppAuthToken,
  amount,
  referenceId,
}) {
  const token = String(hppAuthToken || '').trim();
  const ref = String(referenceId || '').trim();
  const numericAmount = Number(amount);

  if (!token) {
    throw new Error('hppAuthToken is required');
  }
  if (!Number.isFinite(numericAmount) || numericAmount <= 0) {
    throw new Error('amount must be a positive number');
  }
  if (!ref) {
    throw new Error('referenceId is required');
  }

  // If the token already contains a full URL, use it as the base and only
  // append amount/reference query values.
  const tokenLooksLikeUrl = /^https?:\/\//i.test(token);
  let url;
  if (tokenLooksLikeUrl) {
    url = new URL(token);
  } else {
    if (!HPP_CHECKOUT_BASE_URL) {
      throw new Error(
        'HPP_CHECKOUT_BASE_URL is not configured in backend .env and token is not a URL.',
      );
    }
    url = new URL(HPP_CHECKOUT_BASE_URL);
    url.searchParams.set(HPP_TOKEN_QUERY_PARAM, token);
  }

  url.searchParams.set(HPP_AMOUNT_QUERY_PARAM, numericAmount.toFixed(2));
  url.searchParams.set(HPP_REFERENCE_QUERY_PARAM, ref);
  return url.toString();
}

function isTerminalBusySpinResponse(payload) {
  const general = payload?.GeneralResponse || {};
  const statusCode = String(general.StatusCode || '').trim();
  const detailedMessage = String(general.DetailedMessage || '').trim();
  const message = String(general.Message || '').trim();
  return statusCode === '2008' || /terminal in use/i.test(`${detailedMessage} ${message}`);
}

function terminalBusyDelaySeconds(payload) {
  const raw = payload?.GeneralResponse?.DelayBeforeNextRequest;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) return 30;
  // Keep delay bounded to avoid excessively long server waits.
  return Math.max(1, Math.min(Math.ceil(parsed), 120));
}

function _normalizePaaayitExpiryHours(rawHours) {
  const fallback = Number.isFinite(PAAAYIT_REQUESTS_DEFAULT_EXPIRY_HOURS)
    ? PAAAYIT_REQUESTS_DEFAULT_EXPIRY_HOURS
    : 72;
  const parsed = Number(rawHours);
  if (!Number.isFinite(parsed)) {
    return Math.max(48, Math.min(Math.round(fallback), 72));
  }
  return Math.max(48, Math.min(Math.round(parsed), 72));
}

function _amountToMinorUnits(rawAmount) {
  const amount = Number(rawAmount);
  if (!Number.isFinite(amount) || amount <= 0) {
    return null;
  }
  return Math.round(amount * 100);
}

function _decodeJwtPayload(token) {
  const jwt = String(token || '').trim();
  if (!jwt) return null;
  const parts = jwt.split('.');
  if (parts.length < 2) return null;

  try {
    const payload = Buffer.from(parts[1], 'base64url').toString('utf8');
    const parsed = JSON.parse(payload);
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch (_) {
    return null;
  }
}

function _resolveIposMerchantId({ requestedMerchantId, hppToken }) {
  const requested = String(requestedMerchantId || '').trim();
  const claims = _decodeJwtPayload(hppToken);
  const tokenMerchantId = String(claims?.merchantId || '').trim();

  if (!tokenMerchantId) {
    return requested;
  }

  const requestedLooksLikeNumericTpn = /^\d+$/.test(requested);
  if (!requested || requestedLooksLikeNumericTpn || requested !== tokenMerchantId) {
    return tokenMerchantId;
  }

  return requested;
}

function _newPaaayitRequestNumber() {
  const now = new Date();
  const yyyy = now.getFullYear().toString().padStart(4, '0');
  const mm = (now.getMonth() + 1).toString().padStart(2, '0');
  const dd = now.getDate().toString().padStart(2, '0');
  const hh = now.getHours().toString().padStart(2, '0');
  const mi = now.getMinutes().toString().padStart(2, '0');
  const ss = now.getSeconds().toString().padStart(2, '0');
  const suffix = randomUUID().replace(/-/g, '').slice(0, 6).toUpperCase();
  return `PRQ-${yyyy}${mm}${dd}-${hh}${mi}${ss}-${suffix}`;
}

function _newPaaayitReferenceId() {
  const suffix = randomUUID().replace(/-/g, '').slice(0, 10).toUpperCase();
  return `PAAAYIT-${Date.now()}-${suffix}`;
}

function _resolveRequestBaseUrl(req) {
  const explicit = _toPlainText(PAAAYIT_CALLBACK_BASE_URL);
  if (explicit) {
    return explicit.replace(/\/+$/, '');
  }

  const forwardedProto = _toPlainText(req?.headers?.['x-forwarded-proto']);
  const forwardedHost = _toPlainText(req?.headers?.['x-forwarded-host']);
  const host = forwardedHost || _toPlainText(req?.headers?.host);
  const proto = forwardedProto || req?.protocol || 'http';
  if (!host) return '';
  return `${proto}://${host}`.replace(/\/+$/, '');
}

function _isPublicCallbackBaseUrl(baseUrl) {
  const raw = _toPlainText(baseUrl);
  if (!raw) return false;

  try {
    const parsed = new URL(raw);
    const hostname = _toPlainText(parsed.hostname).toLowerCase();
    if (!hostname) return false;
    if (hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '::1') {
      return false;
    }
    if (/^10\./.test(hostname)) return false;
    if (/^192\.168\./.test(hostname)) return false;
    if (/^172\.(1[6-9]|2\d|3[0-1])\./.test(hostname)) return false;
    return true;
  } catch (_) {
    return false;
  }
}

function _toBooleanFlag(value, fallback = false) {
  if (value === undefined || value === null || value === '') {
    return fallback;
  }
  if (typeof value === 'boolean') return value;
  const normalized = String(value).trim().toLowerCase();
  if (['true', '1', 'yes', 'y'].includes(normalized)) return true;
  if (['false', '0', 'no', 'n'].includes(normalized)) return false;
  return fallback;
}

function _renderPaaayitCallbackPage({
  title,
  heading,
  bodyLines,
  autoCloseSeconds = 0,
  showManualCloseInstruction = true,
}) {
  const safeTitle = _toPlainText(title) || 'PaaayIT Payment';
  const safeHeading = _toPlainText(heading) || safeTitle;
  const paragraphs = (Array.isArray(bodyLines) ? bodyLines : [])
    .map((line) => _toPlainText(line))
    .filter(Boolean)
    .map((line) => `<p>${line.replace(/[&<>"']/g, (ch) => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;',
    }[ch]))}</p>`)
    .join('');

  const manualClosePanel = showManualCloseInstruction
    ? '<p id="manual-close-instruction">Close Browser Tab and proceed with Transaction.</p>'
    : '';

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${safeTitle}</title>
    <style>
      body { font-family: Segoe UI, Arial, sans-serif; background: #f3f6fb; color: #123; margin: 0; padding: 32px; }
      .card { max-width: 560px; margin: 8vh auto; background: #fff; border-radius: 16px; padding: 28px 32px; box-shadow: 0 18px 50px rgba(20, 45, 90, 0.14); }
      h1 { margin: 0 0 12px; font-size: 28px; }
      p { margin: 10px 0; line-height: 1.45; }
      #manual-close-instruction {
        margin: 16px 0 0;
        padding: 12px 14px;
        border-radius: 10px;
        background: #e8f0ff;
        color: #17365d;
        font-weight: 700;
      }
    </style>
  </head>
  <body>
    <div class="card">
      <h1>${safeHeading}</h1>
      ${paragraphs}
      ${manualClosePanel}
    </div>
  </body>
</html>`;
}

function _resolveHostedPaymentCallbackConfig({ req, hppReferenceId, requestBody }) {
  const baseUrl = _resolveRequestBaseUrl(req);
  if (!baseUrl) {
    return {
      callbackBaseUrl: '',
      returnUrl: '',
      cancelUrl: '',
      failureUrl: '',
      postApi: '',
      notifyByRedirect: false,
      notifyByPOST: false,
    };
  }

  const ref = encodeURIComponent(_toPlainText(hppReferenceId));
  const sendPaymentLink = _toBooleanFlag(requestBody?.sendPaymentLink, false);
  const callerRequestedCardToken = requestBody?.requestCardToken;
  const requestCardToken = callerRequestedCardToken === undefined
    ? true
    : _toBooleanFlag(callerRequestedCardToken, true);
  const keyedInteractiveFlow = !sendPaymentLink && requestCardToken;
  const publicBase = _isPublicCallbackBaseUrl(baseUrl);

  const webhookSecretQuery = PAAAYIT_WEBHOOK_SECRET
    ? `?webhookSecret=${encodeURIComponent(PAAAYIT_WEBHOOK_SECRET)}`
    : '';

  return {
    callbackBaseUrl: baseUrl,
    returnUrl: keyedInteractiveFlow
      ? `${baseUrl}/api/paaayit-requests/callback/payment-success?transactionReferenceId=${ref}`
      : '',
    cancelUrl: keyedInteractiveFlow
      ? `${baseUrl}/api/paaayit-requests/callback/payment-cancel?transactionReferenceId=${ref}`
      : '',
    failureUrl: keyedInteractiveFlow
      ? `${baseUrl}/api/paaayit-requests/callback/payment-failure?transactionReferenceId=${ref}`
      : '',
    postApi: publicBase
      ? `${baseUrl}/api/paaayit-requests/webhook/payment${webhookSecretQuery}`
      : '',
    notifyByRedirect: keyedInteractiveFlow,
    notifyByPOST: publicBase,
  };
}

function _resolveCallbackQueryValue(value) {
  const candidates = Array.isArray(value) ? value : [value];
  for (let i = candidates.length - 1; i >= 0; i -= 1) {
    const text = _toPlainText(candidates[i]);
    if (!text) continue;
    const normalized = text.split('?')[0].trim();
    if (normalized) {
      return normalized;
    }
  }
  return '';
}

function _buildPaaayitIposPayload({
  merchantId,
  transactionReferenceId,
  amountMinorUnits,
  feeAmount,
  calculateFee,
  customerName,
  customerEmail,
  customerMobile,
  description,
  sendPaymentLink,
  requestCardToken,
  txReferenceTag1,
  txReferenceTag2,
  txReferenceTag3,
  returnUrl,
  cancelUrl,
  failureUrl,
  postApi,
  authHeader,
  notifyByRedirect,
  notifyBySMS,
  notifyByPOST,
  eReceipt,
  avsVerification,
  eReceiptInputPrompt,
  integrationType,
}) {
  const includeFeeAmount =
    Number.isFinite(Number(feeAmount)) && Number(feeAmount) > 0;

  const normalizeTag = (tag) => {
    if (!tag || typeof tag !== 'object') {
      return null;
    }
    const rawLabel = String(tag.tagLabel || '').trim();
    const rawValue = String(tag.tagValue || '').trim();
    if (!rawLabel || !rawValue) {
      return null;
    }

    // iPOS rejects some punctuation-heavy values; keep tags conservative.
    const cleanLabel = rawLabel.replace(/[^A-Za-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim();
    const cleanValue = rawValue.replace(/[^A-Za-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim();
    if (!cleanLabel || !cleanValue) {
      return null;
    }

    return {
      tagLabel: cleanLabel.slice(0, 40),
      tagValue: cleanValue.slice(0, 40),
    };
  };

  const tag1 = normalizeTag(txReferenceTag1);
  const tag2 = normalizeTag(txReferenceTag2);
  const tag3 = normalizeTag(txReferenceTag3);

  return {
    merchantAuthentication: {
      merchantId,
      transactionReferenceId,
    },
    transactionRequest: {
      transactionType: 1,
      amount: String(amountMinorUnits),
      calculateFee: Boolean(calculateFee),
      ...(includeFeeAmount ? { feeAmount: Number(feeAmount) } : {}),
      ...(tag1 ? { txReferenceTag1: tag1 } : {}),
      ...(tag2 ? { txReferenceTag2: tag2 } : {}),
      ...(tag3 ? { txReferenceTag3: tag3 } : {}),
    },
    personalization: {
      logoUrl: '',
      themeColor: '',
      description,
      payNowButtonText: 'Pay Now',
      buttonColor: '',
      cancelButtonText: 'Cancel',
    },
    notificationOption: {
      postAPI: postApi,
      failureUrl,
      returnUrl,
      notifyByRedirect: Boolean(notifyByRedirect),
      notifyBySMS: Boolean(notifyBySMS),
      notifyByPOST: Boolean(notifyByPOST),
      authHeader,
      cancelUrl,
      mobileNumber: customerMobile,
    },
    preferences: {
      integrationType: Number.isFinite(Number(integrationType)) ? Number(integrationType) : 1,
      eReceipt: Boolean(eReceipt),
      avsVerification: Boolean(avsVerification),
      eReceiptInputPrompt: Boolean(eReceiptInputPrompt),
      customerName,
      customerEmail,
      customerMobile,
      sendPaymentLink: Boolean(sendPaymentLink),
      requestCardToken: Boolean(requestCardToken),
    },
  };
}

function _extractHostedUrl(payload) {
  const candidates = [
    payload?.information,
    payload?.paymentUrl,
    payload?.paymentURL,
    payload?.redirectUrl,
    payload?.paymentLink,
    payload?.requestLink,
    payload?.hostedPaymentLink,
    payload?.hostedPaymentPageUrl,
    payload?.hppUrl,
    payload?.transactionResponse?.paymentUrl,
    payload?.response?.paymentUrl,
    payload?.response?.redirectUrl,
    payload?.url,
    payload?.data?.paymentUrl,
    payload?.data?.redirectUrl,
    payload?.data?.requestLink,
    payload?.data?.hostedPaymentPageUrl,
    payload?.result?.paymentUrl,
    payload?.result?.redirectUrl,
    payload?.result?.hostedPaymentPageUrl,
  ];
  for (const candidate of candidates) {
    const text = String(candidate || '').trim();
    if (/^https?:\/\//i.test(text)) {
      return text;
    }
  }
  return '';
}

async function _insertPaaayitRequest(row) {
  const url = `${SUPABASE_URL}/rest/v1/paaayit_requests`;
  const response = await axios.post(url, row, {
    headers: {
      ..._supabaseHeaders(),
      Prefer: 'return=representation',
    },
    timeout: 20000,
  });
  const rows = Array.isArray(response.data) ? response.data : [];
  return rows[0] || null;
}

async function _updatePaaayitRequestById(id, patch) {
  const url = `${SUPABASE_URL}/rest/v1/paaayit_requests`;
  const response = await axios.patch(url, patch, {
    params: {
      id: `eq.${id}`,
      select: '*',
      limit: '1',
    },
    headers: {
      ..._supabaseHeaders(),
      Prefer: 'return=representation',
    },
    timeout: 20000,
  });
  const rows = Array.isArray(response.data) ? response.data : [];
  return rows[0] || null;
}

async function _getPaaayitRequestByHppReference(hppReferenceId) {
  const url = `${SUPABASE_URL}/rest/v1/paaayit_requests`;
  const response = await axios.get(url, {
    params: {
      select: '*',
      hpp_transaction_reference_id: `eq.${hppReferenceId}`,
      limit: '1',
    },
    headers: _supabaseHeaders(),
    timeout: 20000,
  });
  const rows = Array.isArray(response.data) ? response.data : [];
  return rows[0] || null;
}

async function _getPaaayitRequestByPaymentId(paymentId) {
  const resolved = _toPlainText(paymentId);
  if (!resolved) return null;

  const url = `${SUPABASE_URL}/rest/v1/paaayit_requests`;
  const response = await axios.get(url, {
    params: {
      select: '*',
      hpp_payment_id: `eq.${resolved}`,
      limit: '1',
    },
    headers: _supabaseHeaders(),
    timeout: 20000,
  });

  const rows = Array.isArray(response.data) ? response.data : [];
  return rows[0] || null;
}

async function _getPaaayitRequestById(id) {
  const url = `${SUPABASE_URL}/rest/v1/paaayit_requests`;
  const response = await axios.get(url, {
    params: {
      select: '*',
      id: `eq.${id}`,
      limit: '1',
    },
    headers: _supabaseHeaders(),
    timeout: 20000,
  });
  const rows = Array.isArray(response.data) ? response.data : [];
  return rows[0] || null;
}

function _normalizePaaayitStatus(rawStatus) {
  return _toPlainText(rawStatus).toLowerCase();
}

function _isCancelledPaaayitStatus(rawStatus) {
  const status = _normalizePaaayitStatus(rawStatus);
  return status === 'cancelled' || status === 'canceled';
}

async function _findExistingPaaayitDetailByReference({ organizationId, locationId, hppReferenceId }) {
  const org = _toPlainText(organizationId);
  const loc = _toPlainText(locationId);
  const ref = _toPlainText(hppReferenceId);
  if (!org || !loc || !ref) {
    return null;
  }

  const url = `${SUPABASE_URL}/rest/v1/transaction_details`;
  const response = await axios.get(url, {
    params: {
      select: 'id,transaction_header_id,status,reference_id,amount,fee_amount,auth_code,card_last4,card_type,gateway_token,gateway_raw,created_at',
      organization_id: `eq.${org}`,
      location_id: `eq.${loc}`,
      payment_type: 'eq.d',
      subtype: 'eq.s',
      reference_id: `eq.${ref}`,
      order: 'created_at.desc',
      limit: '1',
    },
    headers: _supabaseHeaders(),
    timeout: 15000,
  });

  const rows = Array.isArray(response.data) ? response.data : [];
  return rows[0] || null;
}

function _readPathValue(obj, pathText) {
  const source = obj && typeof obj === 'object' ? obj : null;
  const path = _toPlainText(pathText);
  if (!source || !path) return undefined;

  const keys = path.split('.').map((k) => _toPlainText(k)).filter(Boolean);
  let current = source;
  for (const key of keys) {
    if (!current || typeof current !== 'object') {
      return undefined;
    }
    current = current[key];
  }
  return current;
}

function _pickFirstPayloadText(payload, paths) {
  const source = payload && typeof payload === 'object' ? payload : null;
  if (!source || !Array.isArray(paths)) return '';

  for (const pathText of paths) {
    const value = _toPlainText(_readPathValue(source, pathText));
    if (value) return value;
  }
  return '';
}

function _pickFirstPayloadNumber(payload, paths) {
  const source = payload && typeof payload === 'object' ? payload : null;
  if (!source || !Array.isArray(paths)) return 0;

  for (const pathText of paths) {
    const raw = _readPathValue(source, pathText);
    if (raw === undefined || raw === null) continue;
    if (typeof raw === 'number' && Number.isFinite(raw)) {
      return Math.max(0, raw);
    }
    const text = _toPlainText(raw);
    if (!text) continue;
    const cleaned = text.replace(/[^0-9.\-]/g, '');
    if (!cleaned || cleaned === '.' || cleaned === '-') continue;
    const parsed = Number(cleaned);
    if (Number.isFinite(parsed)) {
      return Math.max(0, parsed);
    }
  }

  return 0;
}

function _buildMergedProviderPayload({ requestRow, providerPayload }) {
  const rowPayload =
    requestRow?.provider_response_payload && typeof requestRow.provider_response_payload === 'object'
      ? requestRow.provider_response_payload
      : {};
  const incoming = providerPayload && typeof providerPayload === 'object'
    ? providerPayload
    : {};
  return {
    ...rowPayload,
    ...incoming,
  };
}

function _extractPaaayitPaymentData({ requestRow, providerPayload }) {
  const payload = _buildMergedProviderPayload({ requestRow, providerPayload });

  function _toPositiveNumber(raw) {
    if (raw === undefined || raw === null) return null;
    if (typeof raw === 'number') {
      return Number.isFinite(raw) ? Math.max(0, raw) : null;
    }
    const text = _toPlainText(raw);
    if (!text) return null;
    const cleaned = text.replace(/[^0-9.\-]/g, '');
    if (!cleaned || cleaned === '.' || cleaned === '-') return null;
    const parsed = Number(cleaned);
    if (!Number.isFinite(parsed)) return null;
    return Math.max(0, parsed);
  }

  function _resolveBestFeeAmount(rawCandidates, baseAmount) {
    const base = Number.isFinite(Number(baseAmount))
      ? Math.max(0, Number(baseAmount))
      : 0;
    const hardMaxRate = 0.25;
    const preferredMaxRate = 0.08;
    const targetRate = 0.03;

    const normalized = [];
    for (const rawCandidate of rawCandidates) {
      const raw = _toPositiveNumber(rawCandidate);
      if (!(raw > 0)) continue;

      normalized.push({ value: raw, kind: 'raw' });
      if (raw >= 1) {
        normalized.push({ value: raw / 100, kind: 'cents' });
      }
      if (base > 0 && raw >= 1 && raw <= 10000) {
        normalized.push({ value: (raw / 10000) * base, kind: 'bps' });
      }
      if (base > 0 && raw > 0 && raw <= 100) {
        normalized.push({ value: (raw / 100) * base, kind: 'percent' });
      }
    }

    let best = null;
    let bestScore = -Infinity;
    for (const candidate of normalized) {
      const value = Number(candidate.value);
      if (!Number.isFinite(value) || value <= 0) continue;

      if (base > 0) {
        const rate = value / base;
        if (rate > hardMaxRate) continue;

        let score = 0;
        if (rate <= preferredMaxRate) score += 20;
        score += Math.max(0, 10 - Math.abs(rate - targetRate) * 200);
        if (candidate.kind === 'raw') score += 4;
        if (candidate.kind === 'cents') score += 2;

        if (score > bestScore || (score === bestScore && best && value < best)) {
          bestScore = score;
          best = value;
        }
      } else {
        if (value > 1000) continue;
        if (best == null || value < best) {
          best = value;
        }
      }
    }

    if (!(best > 0)) return 0;
    return Number(best.toFixed(2));
  }

  function _resolveFeeFromTotalAmount(payloadObj, baseAmount) {
    const base = Number.isFinite(Number(baseAmount))
      ? Math.max(0, Number(baseAmount))
      : 0;
    if (!(base > 0)) return 0;

    const amountPaths = [
      'amount',
      'Amount',
      'totalAmount',
      'TotalAmount',
      'transactionAmount',
      'TransactionAmount',
      'approvedAmount',
      'ApprovedAmount',
      'chargeAmount',
      'ChargeAmount',
      'result.amount',
      'result.Amount',
      'result.totalAmount',
      'result.TotalAmount',
      'response.amount',
      'response.Amount',
      'response.totalAmount',
      'response.TotalAmount',
      'data.amount',
      'data.Amount',
      'data.totalAmount',
      'data.TotalAmount',
      'payment.amount',
      'payment.Amount',
      'payment.totalAmount',
      'payment.TotalAmount',
      'GeneralResponse.amount',
      'GeneralResponse.Amount',
      'GeneralResponse.totalAmount',
      'GeneralResponse.TotalAmount',
      'CardData.amount',
      'CardData.Amount',
      'CardData.totalAmount',
      'CardData.TotalAmount',
      'ExtendedData.amount',
      'ExtendedData.Amount',
      'ExtendedData.totalAmount',
      'ExtendedData.TotalAmount',
    ];

    const candidates = [];
    for (const pathText of amountPaths) {
      const raw = _readPathValue(payloadObj, pathText);
      const parsed = _toPositiveNumber(raw);
      if (!(parsed > 0)) continue;
      candidates.push(parsed);
      if (parsed >= 1) {
        candidates.push(parsed / 100);
      }
    }

    let bestFee = 0;
    let bestScore = -Infinity;
    for (const totalCandidate of candidates) {
      if (!Number.isFinite(totalCandidate) || totalCandidate <= base) continue;
      const fee = totalCandidate - base;
      const rate = fee / base;
      if (rate <= 0 || rate > 0.25) continue;

      let score = 0;
      if (rate <= 0.08) score += 20;
      score += Math.max(0, 10 - Math.abs(rate - 0.03) * 200);
      if (score > bestScore || (score === bestScore && (bestFee === 0 || fee < bestFee))) {
        bestScore = score;
        bestFee = fee;
      }
    }

    return bestFee > 0 ? Number(bestFee.toFixed(2)) : 0;
  }

  const authCode = _pickFirstPayloadText(payload, [
    'authCode',
    'responseApprovalCode',
    'approvalCode',
    'authorizationCode',
    'auth_code',
    'ApprovalCode',
    'AuthCode',
    'result.authCode',
    'result.approvalCode',
    'result.authorizationCode',
    'transactionResponse.authCode',
    'transactionResponse.approvalCode',
    'transactionResponse.authorizationCode',
    'response.authCode',
    'response.approvalCode',
    'response.authorizationCode',
    'data.authCode',
    'data.approvalCode',
    'data.authorizationCode',
  ]);

  const rawCardLast4 = _pickFirstPayloadText(payload, [
    'cardLast4',
    'cardLast4Digit',
    'last4',
    'card.last4',
    'CardData.Last4',
    'CardData.last4',
    'transactionResponse.cardLast4',
    'response.cardLast4',
    'data.cardLast4',
    'maskedPan',
    'maskPan',
    'cardNumberMasked',
    'CardData.CardNumber',
  ]);
  const cardLast4Digits = rawCardLast4.replace(/\D/g, '');
  const cardLast4 = cardLast4Digits.length >= 4
    ? cardLast4Digits.slice(-4)
    : _toPlainText(rawCardLast4).slice(-4);

  const cardType = _pickFirstPayloadText(payload, [
    'cardType',
    'cardBrand',
    'brand',
    'card.type',
    'CardData.CardType',
    'CardData.CardBrand',
    'transactionResponse.cardType',
    'response.cardType',
    'data.cardType',
  ]);

  const paymentIdFromPayload = _pickFirstPayloadText(payload, [
    'paymentId',
    'transactionId',
    'id',
    'payment_id',
    'transaction_id',
    'result.paymentId',
    'result.transactionId',
    'transactionResponse.paymentId',
    'transactionResponse.transactionId',
    'response.paymentId',
    'response.transactionId',
    'data.paymentId',
    'data.transactionId',
  ]);

  const feeCandidatePaths = [
    'feeAmount',
    'FeeAmount',
    'customFee',
    'CustomFee',
    'manualOverrideFeeAmount',
    'manual_override_fee_amount',
    'surchargeAmount',
    'SurchargeAmount',
    'surchargeFee',
    'SurchargeFee',
    'GeneralResponse.feeAmount',
    'GeneralResponse.FeeAmount',
    'GeneralResponse.surchargeAmount',
    'GeneralResponse.SurchargeAmount',
    'GeneralResponse.surchargeFee',
    'GeneralResponse.SurchargeFee',
    'CardData.feeAmount',
    'CardData.FeeAmount',
    'CardData.surchargeAmount',
    'CardData.SurchargeAmount',
    'CardData.surchargeFee',
    'CardData.SurchargeFee',
    'ExtendedData.feeAmount',
    'ExtendedData.FeeAmount',
    'ExtendedData.surchargeAmount',
    'ExtendedData.SurchargeAmount',
    'ExtendedData.surchargeFee',
    'ExtendedData.SurchargeFee',
    'result.feeAmount',
    'result.FeeAmount',
    'result.surchargeAmount',
    'result.SurchargeAmount',
    'result.surchargeFee',
    'result.SurchargeFee',
    'response.feeAmount',
    'response.FeeAmount',
    'response.surchargeAmount',
    'response.SurchargeAmount',
    'response.surchargeFee',
    'response.SurchargeFee',
    'data.feeAmount',
    'data.FeeAmount',
    'data.surchargeAmount',
    'data.SurchargeAmount',
    'data.surchargeFee',
    'data.SurchargeFee',
    'payment.feeAmount',
    'payment.FeeAmount',
    'payment.surchargeAmount',
    'payment.SurchargeAmount',
    'payment.surchargeFee',
    'payment.SurchargeFee',
  ];

  const feeRawCandidates = feeCandidatePaths
    .map((pathText) => _readPathValue(payload, pathText))
    .filter((value) => value !== undefined && value !== null);

  const directResolvedFeeAmount = _resolveBestFeeAmount(
    feeRawCandidates,
    Number(requestRow?.amount),
  );
  const resolvedFeeAmount = directResolvedFeeAmount > 0
    ? directResolvedFeeAmount
    : _resolveFeeFromTotalAmount(payload, Number(requestRow?.amount));

  return {
    payload,
    authCode,
    cardLast4,
    cardType,
    paymentIdFromPayload,
    feeAmount: resolvedFeeAmount,
  };
}

function _isPaidLikeVerificationStatus(rawStatus) {
  const status = _toPlainText(rawStatus).toLowerCase();
  if (!status) return false;

  const positive = [
    'paid',
    'approved',
    'success',
    'successful',
    'completed',
    'captured',
    'settled',
  ];
  const negative = [
    'pending',
    'created',
    'sent',
    'failed',
    'declined',
    'cancel',
    'void',
    'expire',
    'error',
  ];

  if (negative.some((token) => status.includes(token))) {
    return false;
  }
  return positive.some((token) => status.includes(token));
}

function _resolveVerifyHeaders(token) {
  const jwt = _toPlainText(token);
  const headers = {
    Accept: 'application/json',
  };
  if (jwt) {
    // Keep both header styles because iPOS endpoints vary by deployment.
    headers.Token = jwt;
    headers.Authorization = `Bearer ${jwt}`;
  }
  return headers;
}

function _looksLikeProviderCancelSuccess(responsePayload) {
  const payload =
    responsePayload && typeof responsePayload === 'object' ? responsePayload : {};

  const errors = payload?.errors;
  if (Array.isArray(errors) && errors.length > 0) {
    return false;
  }

  const statusCandidates = [
    payload?.message,
    payload?.status,
    payload?.paymentStatus,
    payload?.transactionStatus,
    payload?.information,
    payload?.GeneralResponse?.Message,
    payload?.GeneralResponse?.DetailedMessage,
  ]
    .map((value) => _toPlainText(value).toLowerCase())
    .filter(Boolean);

  if (statusCandidates.length === 0) {
    return true;
  }

  const hasNegativeSignal = statusCandidates.some((text) =>
    ['fail', 'error', 'declin', 'denied', 'not found', 'invalid'].some((token) =>
      text.includes(token),
    ),
  );
  if (hasNegativeSignal) {
    return false;
  }

  return statusCandidates.some((text) =>
    ['cancel', 'void', 'success', 'ok', 'updated'].some((token) =>
      text.includes(token),
    ),
  );
}

function _extractIposTransactionIdFromPaymentUrl(paymentUrl) {
  const raw = _toPlainText(paymentUrl);
  if (!raw) return '';

  try {
    const parsed = new URL(raw);
    const token = _toPlainText(parsed.searchParams.get('t'));
    if (!token) return '';

    const parts = token.split('.');
    if (parts.length < 2) return '';

    const base64Payload = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64Payload + '='.repeat((4 - (base64Payload.length % 4)) % 4);
    const payload = JSON.parse(Buffer.from(padded, 'base64').toString('utf8'));

    return _toPlainText(
      payload?.transaction_id || payload?.transactionId || payload?.id,
    );
  } catch (_) {
    return '';
  }
}

async function _cancelPaaayitTransactionReference({ requestRow, hppReferenceId, cancelReason }) {
  const row = requestRow && typeof requestRow === 'object' ? requestRow : null;
  const ref = _toPlainText(hppReferenceId) || _toPlainText(row?.hpp_transaction_reference_id);
  if (!ref) {
    return {
      cancelled: false,
      reason: 'missing_reference',
    };
  }

  const tokenFromRow = _toPlainText(row?.request_payload?.requestBody?.hppAuthToken);
  const token = tokenFromRow || IPOS_HPP_API_TOKEN;
  if (!token) {
    return {
      cancelled: false,
      reason: 'missing_hpp_auth_token',
    };
  }

  const encodedRef = encodeURIComponent(ref);
  const paymentUrl =
    _toPlainText(row?.provider_response_payload?.information) ||
    _toPlainText(row?.hpp_payment_url);
  const transactionId = _extractIposTransactionIdFromPaymentUrl(paymentUrl);
  const encodedTransactionId = encodeURIComponent(transactionId);
  const timeout =
    Number.isFinite(IPOS_HPP_VERIFY_TIMEOUT_MS) && IPOS_HPP_VERIFY_TIMEOUT_MS > 0
      ? IPOS_HPP_VERIFY_TIMEOUT_MS
      : 20000;

  const reason = _toPlainText(cancelReason) || 'Cancelled by operator.';
  const cancelBody = {
    transactionReferenceId: ref,
    referenceId: ref,
    reason,
    ...(transactionId
      ? {
        transactionId,
        transaction_id: transactionId,
        id: transactionId,
      }
      : {}),
  };

  const attempts = [
    {
      method: 'post',
      url: `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/cancel`,
      data: cancelBody,
    },
    {
      method: 'post',
      url: `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/cancel?transactionReferenceId=${encodedRef}`,
      data: cancelBody,
    },
    {
      method: 'post',
      url: `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/${encodedRef}/cancel`,
      data: cancelBody,
    },
    {
      method: 'patch',
      url: `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/${encodedRef}`,
      data: {
        status: 'cancelled',
        ...cancelBody,
      },
    },
    ...(transactionId
      ? [
        {
          method: 'post',
          url: `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/cancel?transactionId=${encodedTransactionId}`,
          data: cancelBody,
        },
        {
          method: 'post',
          url: `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/${encodedTransactionId}/cancel`,
          data: cancelBody,
        },
        {
          method: 'patch',
          url: `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/${encodedTransactionId}`,
          data: {
            status: 'cancelled',
            ...cancelBody,
          },
        },
      ]
      : []),
  ];

  let lastFailure = null;
  for (const attempt of attempts) {
    try {
      const response = await axios({
        method: attempt.method,
        url: attempt.url,
        data: attempt.data,
        headers: {
          ..._resolveVerifyHeaders(token),
          'Content-Type': 'application/json',
        },
        timeout,
      });

      const payload =
        response?.data && typeof response.data === 'object' ? response.data : {};
      if (_looksLikeProviderCancelSuccess(payload)) {
        return {
          cancelled: true,
          endpoint: attempt.url,
          method: attempt.method,
          payload,
        };
      }

      lastFailure = {
        endpoint: attempt.url,
        method: attempt.method,
        status: response?.status || null,
        details: payload,
      };
    } catch (error) {
      lastFailure = {
        endpoint: attempt.url,
        method: attempt.method,
        status: error?.response?.status || null,
        details: error?.response?.data || error?.message || String(error),
      };
    }
  }

  return {
    cancelled: false,
    reason: 'provider_cancel_failed',
    status: lastFailure?.status || null,
    endpoint: lastFailure?.endpoint || null,
    method: lastFailure?.method || null,
    details: lastFailure?.details || null,
  };
}

function _extractVerificationSignals(payload) {
  const source = payload && typeof payload === 'object' ? payload : {};

  const statusCandidates = [
    source?.status,
    source?.paymentStatus,
    source?.transactionStatus,
    source?.result?.status,
    source?.result?.paymentStatus,
    source?.result?.transactionStatus,
    source?.response?.status,
    source?.response?.paymentStatus,
    source?.response?.transactionStatus,
    source?.data?.status,
    source?.data?.paymentStatus,
    source?.data?.transactionStatus,
    source?.GeneralResponse?.Message,
    source?.GeneralResponse?.DetailedMessage,
  ];

  const paidByStatus = statusCandidates.some((candidate) =>
    _isPaidLikeVerificationStatus(candidate),
  );

  const resultCode = _toPlainText(source?.GeneralResponse?.ResultCode);
  const hasErrorList = Array.isArray(source?.errors) && source.errors.length > 0;
  const extracted = _extractPaaayitPaymentData({ providerPayload: source });
  const hasPaymentEvidence = Boolean(
    extracted.authCode || extracted.paymentIdFromPayload || extracted.cardLast4,
  );

  const verifiedPaid = paidByStatus && !hasErrorList && (!resultCode || resultCode === '0');
  return {
    verifiedPaid,
    paidByStatus,
    resultCode,
    hasErrorList,
    hasPaymentEvidence,
    extracted,
  };
}

async function _verifyPaaayitTransactionReference({ requestRow, hppReferenceId }) {
  const row = requestRow && typeof requestRow === 'object' ? requestRow : null;
  const ref = _toPlainText(hppReferenceId);
  if (!ref) {
    return {
      verified: false,
      reason: 'missing_reference',
    };
  }

  const tokenFromRow = _toPlainText(row?.request_payload?.requestBody?.hppAuthToken);
  const token = tokenFromRow || IPOS_HPP_API_TOKEN;
  if (!token) {
    return {
      verified: false,
      reason: 'missing_hpp_auth_token',
    };
  }

  const encodedRef = encodeURIComponent(ref);
  const paymentUrl =
    _toPlainText(row?.provider_response_payload?.information) ||
    _toPlainText(row?.hpp_payment_url);
  const transactionId = _extractIposTransactionIdFromPaymentUrl(paymentUrl);
  const encodedTransactionId = encodeURIComponent(transactionId);
  const candidates = [
    `${IPOS_HPP_API_BASE_URL}/external-payment-transaction?transactionReferenceId=${encodedRef}`,
    `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/${encodedRef}`,
    `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/status?transactionReferenceId=${encodedRef}`,
    ...(transactionId
      ? [
        `${IPOS_HPP_API_BASE_URL}/external-payment-transaction?transactionId=${encodedTransactionId}`,
        `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/${encodedTransactionId}`,
        `${IPOS_HPP_API_BASE_URL}/external-payment-transaction/status?transactionId=${encodedTransactionId}`,
      ]
      : []),
  ];

  let lastError = null;
  for (const url of candidates) {
    try {
      const response = await axios.get(url, {
        headers: _resolveVerifyHeaders(token),
        timeout: Number.isFinite(IPOS_HPP_VERIFY_TIMEOUT_MS) && IPOS_HPP_VERIFY_TIMEOUT_MS > 0
          ? IPOS_HPP_VERIFY_TIMEOUT_MS
          : 20000,
      });
      const payload = response?.data && typeof response.data === 'object'
        ? response.data
        : {};

      const signals = _extractVerificationSignals(payload);
      if (signals.verifiedPaid) {
        return {
          verified: true,
          endpoint: url,
          payload,
          extracted: signals.extracted,
        };
      }

      return {
        verified: false,
        reason: 'verification_response_not_paid',
        endpoint: url,
        payload,
      };
    } catch (error) {
      lastError = error;
    }
  }

  return {
    verified: false,
    reason: 'verification_call_failed',
    status: lastError?.response?.status || null,
    details: lastError?.response?.data || lastError?.message || String(lastError),
  };
}

async function _fetchTerminalSnapshot({ terminalId, organizationId, locationId }) {
  const id = _toPlainText(terminalId);
  if (!id) {
    return null;
  }

  const url = `${SUPABASE_URL}/rest/v1/terminals`;
  const response = await axios.get(url, {
    params: {
      select: 'id,terminal_number,terminal_name,name,code',
      id: `eq.${id}`,
      ...(_toPlainText(organizationId) ? { organization_id: `eq.${_toPlainText(organizationId)}` } : {}),
      ...(_toPlainText(locationId) ? { location_id: `eq.${_toPlainText(locationId)}` } : {}),
      limit: '1',
    },
    headers: _supabaseHeaders(),
    timeout: 15000,
  });

  const rows = Array.isArray(response.data) ? response.data : [];
  const first = rows[0] || null;
  if (!first || typeof first !== 'object') {
    return null;
  }

  const terminalNumber = _toPlainText(first.terminal_number);
  const terminalName = _toPlainText(first.terminal_name || first.name || first.code);
  return {
    terminalId: _toPlainText(first.id),
    terminalNumber,
    terminalName,
  };
}

async function _resolvePaaayitBatchNumber({ organizationId, locationId, terminalId, terminalNumber }) {
  const org = _toPlainText(organizationId);
  const loc = _toPlainText(locationId);
  if (!org || !loc) {
    return 1;
  }

  try {
    const url = `${SUPABASE_URL}/rest/v1/transaction_headers`;
    const params = {
      select: 'batch_number',
      organization_id: `eq.${org}`,
      location_id: `eq.${loc}`,
      order: 'created_at.desc',
      limit: '1',
      batch_number: 'not.is.null',
    };

    const tId = _toPlainText(terminalId);
    const tNumber = _toPlainText(terminalNumber);
    if (tId) {
      params.terminal_id = `eq.${tId}`;
    } else if (tNumber) {
      params.terminal_number = `eq.${tNumber}`;
    }

    const response = await axios.get(url, {
      params,
      headers: _supabaseHeaders(),
      timeout: 15000,
    });

    const rows = Array.isArray(response.data) ? response.data : [];
    const parsed = Number(rows[0]?.batch_number);
    if (Number.isFinite(parsed) && parsed > 0) {
      return Math.round(parsed);
    }
  } catch (_) {}

  return 1;
}

async function _insertTransactionHeaderRow(row) {
  const url = `${SUPABASE_URL}/rest/v1/transaction_headers`;
  const response = await axios.post(url, row, {
    headers: {
      ..._supabaseHeaders(),
      Prefer: 'return=representation',
    },
    timeout: 20000,
  });
  const rows = Array.isArray(response.data) ? response.data : [];
  return rows[0] || null;
}

async function _insertTransactionDetailRow(row) {
  const url = `${SUPABASE_URL}/rest/v1/transaction_details`;
  const response = await axios.post(url, row, {
    headers: {
      ..._supabaseHeaders(),
      Prefer: 'return=representation',
    },
    timeout: 20000,
  });
  const rows = Array.isArray(response.data) ? response.data : [];
  return rows[0] || null;
}

async function _deleteTransactionHeaderById(id) {
  const headerId = _toPlainText(id);
  if (!headerId) return;

  const url = `${SUPABASE_URL}/rest/v1/transaction_headers`;
  await axios.delete(url, {
    params: {
      id: `eq.${headerId}`,
      limit: '1',
    },
    headers: {
      ..._supabaseHeaders(),
      Prefer: 'return=minimal',
    },
    timeout: 20000,
  });
}

function _isSupabaseUniqueViolation(error) {
  const data = error?.response?.data;
  const code = _toPlainText(data?.code);
  if (code === '23505') return true;

  const text = JSON.stringify(data || error?.message || '').toLowerCase();
  return text.includes('duplicate key value violates unique constraint');
}

async function _updateTransactionDetailById(id, patch) {
  const detailId = _toPlainText(id);
  if (!detailId || !patch || typeof patch !== 'object' || Object.keys(patch).length === 0) {
    return null;
  }

  const url = `${SUPABASE_URL}/rest/v1/transaction_details`;
  const response = await axios.patch(url, patch, {
    params: {
      id: `eq.${detailId}`,
      select: '*',
      limit: '1',
    },
    headers: {
      ..._supabaseHeaders(),
      Prefer: 'return=representation',
    },
    timeout: 20000,
  });

  const rows = Array.isArray(response.data) ? response.data : [];
  return rows[0] || null;
}

const _paaayitReferenceSyncLocks = new Map();

async function _withPaaayitReferenceSyncLock(lockKey, task) {
  const key = _toPlainText(lockKey);
  if (!key) {
    return task();
  }

  while (_paaayitReferenceSyncLocks.has(key)) {
    await _paaayitReferenceSyncLocks.get(key);
  }

  let release;
  const lockPromise = new Promise((resolve) => {
    release = resolve;
  });
  _paaayitReferenceSyncLocks.set(key, lockPromise);

  try {
    return await task();
  } finally {
    release();
    if (_paaayitReferenceSyncLocks.get(key) === lockPromise) {
      _paaayitReferenceSyncLocks.delete(key);
    }
  }
}

async function _ensurePaaayitOpenBatchTransaction({ requestRow, providerPayload }) {
  const row = requestRow && typeof requestRow === 'object' ? requestRow : null;
  const organizationId = _toPlainText(row?.organization_id);
  const locationId = _toPlainText(row?.location_id);
  const hppReferenceId = _toPlainText(row?.hpp_transaction_reference_id);
  const lockKey = [organizationId, locationId, hppReferenceId].join('|');

  return _withPaaayitReferenceSyncLock(lockKey, async () =>
    _ensurePaaayitOpenBatchTransactionUnlocked({ requestRow, providerPayload }),
  );
}

async function _ensurePaaayitOpenBatchTransactionUnlocked({ requestRow, providerPayload }) {
  const row = requestRow && typeof requestRow === 'object' ? requestRow : null;
  if (!row) {
    throw new Error('Missing request row for local transaction sync.');
  }

  const organizationId = _toPlainText(row.organization_id);
  const locationId = _toPlainText(row.location_id);
  const terminalId = _toPlainText(row.terminal_id);
  const hppReferenceId = _toPlainText(row.hpp_transaction_reference_id);
  const requestNumber = _toPlainText(row.request_number);
  const customerName = _toPlainText(row.customer_name);
  const customerEmail = _toPlainText(row.customer_email);
  const paymentReference = _toPlainText(row.payment_reference);
  const amount = Number(row.amount);

  if (!organizationId || !locationId || !hppReferenceId) {
    throw new Error('Missing organization/location/reference for local transaction sync.');
  }
  if (!terminalId) {
    throw new Error('Missing terminal_id; cannot create terminal-scoped open batch transaction.');
  }
  if (!Number.isFinite(amount) || amount <= 0) {
    throw new Error('Invalid amount for local transaction sync.');
  }

  const existing = await _findExistingPaaayitDetailByReference({
    organizationId,
    locationId,
    hppReferenceId,
  });

  const extracted = _extractPaaayitPaymentData({
    requestRow: row,
    providerPayload,
  });

  console.log(
    '[PaaayIT] extracted payment metadata:',
    JSON.stringify({
      hppReferenceId,
      amount,
      extractedFeeAmount: extracted.feeAmount,
      extractedCardType: extracted.cardType,
      extractedCardLast4: extracted.cardLast4,
      hasAuthCode: Boolean(extracted.authCode),
      providerKeys: Object.keys(extracted.payload || {}).slice(0, 20),
    }),
  );

  if (existing) {
    const enrichPatch = {};
    if (!(_toPlainText(existing.auth_code)) && extracted.authCode) {
      enrichPatch.auth_code = extracted.authCode;
    }
    if (!(_toPlainText(existing.card_last4)) && extracted.cardLast4) {
      enrichPatch.card_last4 = extracted.cardLast4;
    }
    if (!(_toPlainText(existing.card_type)) && extracted.cardType) {
      enrichPatch.card_type = extracted.cardType;
    }
    const existingToken = _toPlainText(existing.gateway_token);
    const resolvedToken =
      _toPlainText(row.hpp_payment_id) ||
      extracted.paymentIdFromPayload;
    if (!existingToken && resolvedToken) {
      enrichPatch.gateway_token = resolvedToken;
    }
    const existingFeeAmount = Number(existing.fee_amount);
    const existingAmount = Number(existing.amount);
    const expectedAmount = Number.isFinite(existingAmount) && existingAmount > 0
      ? existingAmount
      : amount;
    const existingFeeRate =
      Number.isFinite(existingFeeAmount) && existingFeeAmount > 0 && expectedAmount > 0
        ? existingFeeAmount / expectedAmount
        : 0;
    const extractedFeeRate =
      extracted.feeAmount > 0 && expectedAmount > 0
        ? extracted.feeAmount / expectedAmount
        : 0;

    const missingExistingFee = !(Number.isFinite(existingFeeAmount) && existingFeeAmount > 0);
    const existingLooksImplausible =
      existingFeeRate > 0.25 ||
      (existingFeeRate > 0.08 && extractedFeeRate > 0 && extractedFeeRate <= 0.08);
    const extractedLooksPlausible = extractedFeeRate > 0 && extractedFeeRate <= 0.25;

    if (extracted.feeAmount > 0 && (missingExistingFee || (existingLooksImplausible && extractedLooksPlausible))) {
      enrichPatch.fee_amount = Number(extracted.feeAmount.toFixed(2));
    }
    const existingRaw = existing.gateway_raw && typeof existing.gateway_raw === 'object'
      ? existing.gateway_raw
      : {};
    const mergedRaw = {
      ...existingRaw,
      ...extracted.payload,
    };
    if (Object.keys(mergedRaw).length > 0) {
      enrichPatch.gateway_raw = mergedRaw;
    }

    if (Object.keys(enrichPatch).length > 0) {
      await _updateTransactionDetailById(existing.id, enrichPatch);
    }

    console.log(
      '[PaaayIT] local transaction dedup hit (already_exists)',
      JSON.stringify({
        hppReferenceId,
        detailId: _toPlainText(existing.id),
        transactionHeaderId: _toPlainText(existing.transaction_header_id),
      }),
    );

    return {
      created: false,
      reason: 'already_exists',
      detailId: _toPlainText(existing.id),
      transactionHeaderId: _toPlainText(existing.transaction_header_id),
    };
  }

  const terminalSnapshot = await _fetchTerminalSnapshot({
    terminalId,
    organizationId,
    locationId,
  });
  const terminalNumber = _toPlainText(terminalSnapshot?.terminalNumber);
  const terminalName =
    _toPlainText(terminalSnapshot?.terminalName) ||
    (terminalNumber ? `Terminal ${terminalNumber}` : 'PaaayIT Online');
  const batchNumber = await _resolvePaaayitBatchNumber({
    organizationId,
    locationId,
    terminalId,
    terminalNumber,
  });

  const nowIso = new Date().toISOString();
  const headerPayload = {
    organization_id: organizationId,
    location_id: locationId,
    terminal_id: terminalId,
    ...(terminalNumber ? { terminal_number: terminalNumber } : {}),
    batch_number: batchNumber,
    subtotal: Number(amount.toFixed(2)),
    tax: 0,
    total: Number(amount.toFixed(2)),
    fee_amount: Number(extracted.feeAmount.toFixed(2)),
    amount_paid: 0,
    amount_due: Number(amount.toFixed(2)),
    status: 'open',
    staff_name: 'PaaayIT Online',
    terminal_name: terminalName,
    server_id: 'PAAAYIT',
    ...(requestNumber ? { invoice_reference: requestNumber } : {}),
    customer_snapshot: {
      source: 'paaayit_online',
      request_number: requestNumber,
      payment_reference: paymentReference,
      customer_name: customerName,
      customer_email: customerEmail,
    },
    created_at: nowIso,
  };

  const header = await _insertTransactionHeaderRow(headerPayload);
  if (!header?.id) {
    throw new Error('Failed to create transaction header for paid PaaayIT request.');
  }

  const payload = extracted.payload;
  const authCode = extracted.authCode;
  const cardLast4 = extracted.cardLast4;
  const cardType = extracted.cardType;
  const gatewayToken =
    _toPlainText(row.hpp_payment_id) ||
    extracted.paymentIdFromPayload;

  const detailPayload = {
    transaction_header_id: header.id,
    organization_id: organizationId,
    location_id: locationId,
    payment_type: 'd',
    subtype: 's',
    amount: Number(amount.toFixed(2)),
    fee_amount: Number(extracted.feeAmount.toFixed(2)),
    status: 'approved',
    reference_id: hppReferenceId,
    gateway_provider: 'paaayit_online',
    batch_status: 'o',
    ...(authCode ? { auth_code: authCode } : {}),
    ...(cardLast4 ? { card_last4: cardLast4 } : {}),
    ...(cardType ? { card_type: cardType } : {}),
    ...(gatewayToken ? { gateway_token: gatewayToken } : {}),
    gateway_raw: payload,
    created_at: nowIso,
  };

  let detail = null;
  try {
    detail = await _insertTransactionDetailRow(detailPayload);
  } catch (error) {
    if (_isSupabaseUniqueViolation(error)) {
      const existingAfterConflict = await _findExistingPaaayitDetailByReference({
        organizationId,
        locationId,
        hppReferenceId,
      });
      if (existingAfterConflict) {
        try {
          await _deleteTransactionHeaderById(header.id);
        } catch (cleanupError) {
          console.warn(
            '[PaaayIT] failed to cleanup duplicate-conflict header',
            JSON.stringify({
              headerId: _toPlainText(header.id),
              hppReferenceId,
              cleanupError: cleanupError?.message || String(cleanupError),
            }),
          );
        }

        console.log(
          '[PaaayIT] local transaction dedup hit (unique_conflict)',
          JSON.stringify({
            hppReferenceId,
            losingHeaderId: _toPlainText(header.id),
            detailId: _toPlainText(existingAfterConflict.id),
            transactionHeaderId: _toPlainText(existingAfterConflict.transaction_header_id),
          }),
        );

        return {
          created: false,
          reason: 'already_exists_unique_conflict',
          detailId: _toPlainText(existingAfterConflict.id),
          transactionHeaderId: _toPlainText(existingAfterConflict.transaction_header_id),
        };
      }
    }
    throw error;
  }

  if (!detail?.id) {
    throw new Error('Failed to create transaction detail for paid PaaayIT request.');
  }

  console.log(
    '[PaaayIT] local transaction created',
    JSON.stringify({
      hppReferenceId,
      detailId: _toPlainText(detail.id),
      transactionHeaderId: _toPlainText(header.id),
    }),
  );

  return {
    created: true,
    detailId: _toPlainText(detail.id),
    transactionHeaderId: _toPlainText(header.id),
    batchNumber,
    terminalId,
    terminalNumber,
  };
}

async function _resolveLocationName({ locationId, organizationId }) {
  const location = _toPlainText(locationId);
  const organization = _toPlainText(organizationId);
  if (!location) return '';

  const url = `${SUPABASE_URL}/rest/v1/locations`;
  const response = await axios.get(url, {
    params: {
      select: '*',
      id: `eq.${location}`,
      ...(organization ? { organization_id: `eq.${organization}` } : {}),
      limit: '1',
    },
    headers: _supabaseHeaders(),
    timeout: 15000,
  });

  const rows = Array.isArray(response.data) ? response.data : [];
  const first = rows[0] || null;
  if (!first || typeof first !== 'object') return '';

  return _toPlainText(
    first.location_name ||
      first.locationName ||
      first.name,
  );
}

async function _markPaaayitRequestPaidByPayload({
  hppReferenceId,
  hppPaymentId,
  providerPayload,
  skipExpiryCheck = false,
}) {
  const ref = _toPlainText(hppReferenceId);
  const paymentId = _toPlainText(hppPaymentId);
  if (!ref && !paymentId) {
    return {
      statusCode: 400,
      body: { ok: false, error: 'transactionReferenceId or paymentId is required.' },
    };
  }

  const found = ref
    ? await _getPaaayitRequestByHppReference(ref)
    : await _getPaaayitRequestByPaymentId(paymentId);
  if (!found) {
    return {
      statusCode: 404,
      body: {
        ok: false,
        error: 'No PaaayIT request found for transactionReferenceId.',
        transactionReferenceId: ref,
        paymentId,
      },
    };
  }

  const mergedPayload = _buildMergedProviderPayload({
    requestRow: found,
    providerPayload,
  });

  const currentStatus = _normalizePaaayitStatus(found.status);
  if (_isCancelledPaaayitStatus(currentStatus)) {
    return {
      statusCode: 409,
      body: {
        ok: false,
        error: 'Payment request has been cancelled.',
        requestId: found.id,
        status: found.status,
      },
    };
  }

  if (!skipExpiryCheck && _isExpiredTimestamp(found.expires_at) && !['paid', 'reconciled'].includes(currentStatus)) {
    const expired = await _updatePaaayitRequestById(found.id, {
      status: 'expired',
      expired_at: new Date().toISOString(),
      provider_response_payload: mergedPayload,
    });
    return {
      statusCode: 409,
      body: {
        ok: false,
        error: 'Payment request has expired.',
        requestId: expired?.id || found.id,
        status: expired?.status || 'expired',
      },
    };
  }

  const updated = await _updatePaaayitRequestById(found.id, {
    status: 'paid',
    paid_at: found.paid_at || new Date().toISOString(),
    hpp_payment_id:
      paymentId ||
      _toPlainText(providerPayload?.paymentId) ||
      _toPlainText(providerPayload?.transactionId) ||
      _toPlainText(providerPayload?.id) ||
      found.hpp_payment_id ||
      null,
    provider_response_payload: mergedPayload,
  });

  let localTransaction = null;
  try {
    localTransaction = await _ensurePaaayitOpenBatchTransaction({
      requestRow: updated || found,
      providerPayload: mergedPayload,
    });
  } catch (syncError) {
    return {
      statusCode: 502,
      body: {
        ok: false,
        error: 'Payment marked paid but local open-batch transaction sync failed.',
        requestId: updated?.id || found.id,
        status: updated?.status || 'paid',
        details: syncError?.message || String(syncError),
      },
    };
  }

  return {
    statusCode: 200,
    body: {
      ok: true,
      requestId: updated?.id || found.id,
      status: updated?.status || 'paid',
      paidAt: updated?.paid_at || found.paid_at,
      localTransaction,
    },
  };
}

function _isExpiredTimestamp(isoText) {
  const ts = Date.parse(String(isoText || ''));
  if (!Number.isFinite(ts)) return false;
  return ts <= Date.now();
}





app.post('/api/hpp/payment-link', async (req, res) => {
  const { amount, referenceId, hppAuthToken } = req.body || {};

  try {
    const paymentUrl = buildHostedPaymentUrlFromAuthToken({
      hppAuthToken,
      amount,
      referenceId,
    });
    return res.json({
      success: true,
      paymentUrl,
      referenceId: String(referenceId || '').trim(),
      amount: Number(Number(amount).toFixed(2)),
    });
  } catch (error) {
    return res.status(400).json({
      success: false,
      error: error?.message || error.toString(),
    });
  }
});

app.get('/api/paaayit-requests', async (req, res) => {
  if (!PAAAYIT_REQUESTS_ENABLED) {
    return res.status(404).json({ ok: false, error: 'PaaayIT Request flow is disabled.' });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ ok: false, error: 'Supabase is not configured.' });
  }

  const organizationId = _toPlainText(req.query?.organizationId);
  const locationId = _toPlainText(req.query?.locationId);
  const terminalId = _toPlainText(req.query?.terminalId);
  const status = _toPlainText(req.query?.status).toLowerCase();
  const fromDate = _toPlainText(req.query?.fromDate);
  const toDate = _toPlainText(req.query?.toDate);
  const requestedLimit = Number(req.query?.limit);
  const limit = Number.isFinite(requestedLimit)
    ? Math.max(1, Math.min(Math.round(requestedLimit), 500))
    : 100;

  if (!organizationId) {
    return res.status(400).json({ ok: false, error: 'organizationId is required.' });
  }
  if (!terminalId) {
    return res.status(400).json({ ok: false, error: 'terminalId is required.' });
  }

  try {
    const url = `${SUPABASE_URL}/rest/v1/paaayit_requests`;
    const params = {
      select:
        'id,request_number,request_title,status,amount,currency,customer_name,customer_email,created_at,expires_at,sent_at,hpp_payment_url,hpp_transaction_reference_id,provider_response_payload',
      organization_id: `eq.${organizationId}`,
      terminal_id: `eq.${terminalId}`,
      order: 'created_at.desc',
      limit: String(limit),
    };

    if (locationId) {
      params.location_id = `eq.${locationId}`;
    }
    if (status) {
      params.status = `eq.${status}`;
    }
    if (fromDate && toDate) {
      params.and = `(created_at.gte.${fromDate},created_at.lte.${toDate})`;
    } else if (fromDate) {
      params.created_at = `gte.${fromDate}`;
    } else if (toDate) {
      params.created_at = `lte.${toDate}`;
    }

    const response = await axios.get(url, {
      params,
      headers: _supabaseHeaders(),
      timeout: 20000,
    });

    return res.json({
      ok: true,
      items: Array.isArray(response.data) ? response.data : [],
      count: Array.isArray(response.data) ? response.data.length : 0,
    });
  } catch (error) {
    return res.status(502).json({
      ok: false,
      error: 'Failed to fetch PaaayIT requests.',
      details: error?.response?.data || error?.message || String(error),
    });
  }
});

app.post('/api/paaayit-requests/create', async (req, res) => {
  if (!PAAAYIT_REQUESTS_ENABLED) {
    return res.status(404).json({ ok: false, error: 'PaaayIT Request flow is disabled.' });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({
      ok: false,
      error: 'Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY.',
    });
  }

  const organizationId = _toPlainText(req.body?.organizationId);
  const locationId = _toPlainText(req.body?.locationId);
  const terminalId = _toPlainText(req.body?.terminalId) || null;
  const amount = Number(req.body?.amount);
  const customerName = _toPlainText(req.body?.customerName);
  const customerEmail = _toPlainText(req.body?.customerEmail);
  const customerMobile = _toPlainText(req.body?.customerMobile);
  const paymentReference = _toPlainText(req.body?.paymentReference || req.body?.txReferenceTag1);
  const attachmentPdfBase64 = _toPlainText(req.body?.attachmentPdfBase64);
  const attachmentPdfFileName =
    _toPlainText(req.body?.attachmentPdfFileName) || `${Date.now()}-e-invoice.pdf`;
  const description = _toPlainText(req.body?.description) || 'PaaayIT Request';
  const requestedMerchantId = _toPlainText(req.body?.merchantId);
  const requestNumber = _toPlainText(req.body?.requestNumber) || _newPaaayitRequestNumber();
  const requestTitle = _toPlainText(req.body?.requestTitle) || 'PaaayIT Request';
  const expiryHours = _normalizePaaayitExpiryHours(req.body?.expiryHours);
  const requestedLocationName = _toPlainText(req.body?.locationName);
  const amountMinorUnits = Number.isFinite(Number(req.body?.amountMinorUnits))
    ? Number(req.body?.amountMinorUnits)
    : _amountToMinorUnits(amount);
  const hppToken = _toPlainText(req.body?.hppAuthToken) || IPOS_HPP_API_TOKEN;
  const hppReferenceId = _toPlainText(req.body?.transactionReferenceId) || _newPaaayitReferenceId();
  const tokenClaims = _decodeJwtPayload(hppToken);

  if (!organizationId || !locationId) {
    return res.status(400).json({ ok: false, error: 'organizationId and locationId are required.' });
  }
  if (!requestedMerchantId) {
    return res.status(400).json({ ok: false, error: 'merchantId is required.' });
  }
  if (!customerEmail) {
    return res.status(400).json({ ok: false, error: 'customerEmail is required.' });
  }
  if (!_isValidEmail(customerEmail)) {
    return res.status(400).json({ ok: false, error: 'customerEmail format is invalid.' });
  }
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ ok: false, error: 'amount must be a positive number.' });
  }
  if (!Number.isFinite(amountMinorUnits) || amountMinorUnits <= 0) {
    return res.status(400).json({ ok: false, error: 'amountMinorUnits could not be derived from amount.' });
  }
  if (!hppToken) {
    return res.status(400).json({ ok: false, error: 'hppAuthToken is required (or set IPOS_HPP_API_TOKEN in env).' });
  }

  const merchantId = _resolveIposMerchantId({
    requestedMerchantId,
    hppToken,
  });
  const merchantIdCandidates = [
    merchantId,
    requestedMerchantId,
    _toPlainText(tokenClaims?.merchantId),
    _toPlainText(tokenClaims?.tpn),
  ].filter((value, index, arr) => value && arr.indexOf(value) === index);

  const now = new Date();
  const expiresAt = new Date(now.getTime() + expiryHours * 60 * 60 * 1000);
  const resolvedLocationName = requestedLocationName ||
    await _resolveLocationName({ locationId, organizationId }).catch(() => '');
  const callbackConfig = _resolveHostedPaymentCallbackConfig({
    req,
    hppReferenceId,
    requestBody: req.body || {},
  });

  const rowPayload = {
    organization_id: organizationId,
    location_id: locationId,
    terminal_id: terminalId,
    request_number: requestNumber,
    request_title: requestTitle,
    status: 'pending',
    amount: Number(amount.toFixed(2)),
    currency: _toPlainText(req.body?.currency) || 'USD',
    customer_name: customerName,
    customer_email: customerEmail,
    customer_mobile: customerMobile,
    description,
    hpp_transaction_reference_id: hppReferenceId,
    reconciliation_reference_id: hppReferenceId,
    expires_at: expiresAt.toISOString(),
    request_payload: {
      requestSource: 'backend-api',
      requestTitle,
      expiryHours,
      requestBody: req.body || {},
    },
  };

  let inserted = null;
  try {
    inserted = await _insertPaaayitRequest(rowPayload);
  } catch (error) {
    const message = error?.response?.data || error?.message || String(error);
    return res.status(502).json({ ok: false, error: 'Failed to insert PaaayIT request row.', details: message });
  }

  const callIposWithMerchantId = async (merchantIdToUse) => {
    const calculateFee = req.body?.calculateFee === true ||
      String(req.body?.calculateFee || '').toLowerCase() === 'true';

    const payload = _buildPaaayitIposPayload({
      merchantId: merchantIdToUse,
      transactionReferenceId: hppReferenceId,
      amountMinorUnits,
      // Operating parameter controls whether surcharge calculation is requested.
      calculateFee,
      customerName,
      customerEmail,
      customerMobile,
      description,
      sendPaymentLink: req.body?.sendPaymentLink ?? !_smtpConfigured(),
      requestCardToken: req.body?.requestCardToken ?? true,
      txReferenceTag1: paymentReference
        ? { tagLabel: 'Payment Reference', tagValue: paymentReference }
        : req.body?.txReferenceTag1,
      txReferenceTag2: req.body?.txReferenceTag2,
      txReferenceTag3: req.body?.txReferenceTag3,
      returnUrl: _toPlainText(req.body?.returnUrl) || callbackConfig.returnUrl,
      cancelUrl: _toPlainText(req.body?.cancelUrl) || callbackConfig.cancelUrl,
      failureUrl: _toPlainText(req.body?.failureUrl) || callbackConfig.failureUrl,
      postApi: _toPlainText(req.body?.postAPI) || callbackConfig.postApi,
      authHeader: _toPlainText(req.body?.authHeader),
      notifyByRedirect: req.body?.notifyByRedirect ?? callbackConfig.notifyByRedirect,
      notifyBySMS: req.body?.notifyBySMS ?? false,
      notifyByPOST: req.body?.notifyByPOST ?? callbackConfig.notifyByPOST,
      eReceipt: req.body?.eReceipt ?? true,
      avsVerification: req.body?.avsVerification ?? true,
      eReceiptInputPrompt: req.body?.eReceiptInputPrompt ?? true,
      integrationType: req.body?.integrationType ?? 1,
    });

    console.log(
      '[PaaayIT] create request fee flags:',
      JSON.stringify({
        hppReferenceId,
        amount,
        amountMinorUnits,
        requestCalculateFee: req.body?.calculateFee,
        payloadCalculateFee: payload?.transactionRequest?.calculateFee,
      }),
    );

    return axios.post(
      `${IPOS_HPP_API_BASE_URL}/external-payment-transaction`,
      payload,
      {
        headers: {
          Token: hppToken,
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        timeout: 45000,
      },
    );
  };

  const isInvalidMerchantIdError = (error) => {
    const upstreamData = error?.response?.data;
    const serialized = JSON.stringify(upstreamData || {}).toLowerCase();
    return serialized.includes('merchantauthentication.merchantid') ||
      serialized.includes('invalid merchant id');
  };

  try {
    let response = null;
    let usedMerchantId = merchantIdCandidates[0] || merchantId;
    let lastMerchantError = null;

    for (let i = 0; i < merchantIdCandidates.length; i += 1) {
      const candidate = merchantIdCandidates[i];
      try {
        response = await callIposWithMerchantId(candidate);
        usedMerchantId = candidate;
        break;
      } catch (candidateError) {
        lastMerchantError = candidateError;
        if (!isInvalidMerchantIdError(candidateError) || i === merchantIdCandidates.length - 1) {
          throw candidateError;
        }
        console.warn(
          '[PaaayIT] merchantId rejected by upstream, retrying with next candidate:',
          candidate,
        );
      }
    }

    if (!response) {
      throw lastMerchantError || new Error('Failed to create external payment transaction.');
    }

    const providerPayload = response?.data || {};
    console.log('[PaaayIT] iPOS external-payment-transaction response:', JSON.stringify(providerPayload, null, 2));

    const paymentUrl = _extractHostedUrl(providerPayload);
    const paymentId = _extractIposTransactionIdFromPaymentUrl(paymentUrl);
    console.log('[PaaayIT] Extracted paymentUrl:', paymentUrl);

    const paidStatus = paymentUrl ? 'sent' : 'pending';

    const updated = await _updatePaaayitRequestById(inserted.id, {
      status: paidStatus,
      sent_at: paymentUrl ? new Date().toISOString() : null,
      hpp_payment_id: paymentId || null,
      hpp_payment_url: paymentUrl || null,
      provider_response_payload: providerPayload,
    });

    let emailDispatch = { ok: false, skipped: 'not_attempted' };
    if (paymentUrl) {
      try {
        emailDispatch = await _sendPaaayitRequestEmail({
          recipientEmail: customerEmail,
          customerName,
          locationName: resolvedLocationName,
          paymentReference,
          requestNumber,
          amount,
          paymentUrl,
          expiresAt: expiresAt.toISOString(),
          pdfBase64: attachmentPdfBase64,
          pdfFilename: attachmentPdfFileName,
        });
      } catch (mailError) {
        emailDispatch = {
          ok: false,
          error: mailError?.message || String(mailError),
        };
      }
    }

    return res.json({
      ok: true,
      requestId: updated?.id || inserted.id,
      requestNumber,
      hppTransactionReferenceId: hppReferenceId,
      paymentUrl,
      expiresAt: expiresAt.toISOString(),
      status: updated?.status || paidStatus,
      usedMerchantId,
      emailDispatch,
    });
  } catch (error) {
    const upstreamStatus = error?.response?.status || null;
    const upstreamData = error?.response?.data || null;
    const upstreamMessage = error?.message || String(error);
    const upstreamCode = error?.code || null;
    const diagnostic = {
      upstreamStatus,
      upstreamCode,
      upstreamData,
      message: upstreamMessage,
      merchantIdCandidates,
      merchantIdSelected: merchantIdCandidates[0] || merchantId,
      tokenClaimsPresent: Boolean(tokenClaims && typeof tokenClaims === 'object'),
      tokenMerchantId: _toPlainText(tokenClaims?.merchantId),
      tokenTpn: _toPlainText(tokenClaims?.tpn),
    };

    console.error(
      '[PaaayIT] external-payment-transaction failed:',
      JSON.stringify(diagnostic, null, 2),
    );

    await _updatePaaayitRequestById(inserted.id, {
      status: 'failed',
      provider_response_payload: diagnostic,
    }).catch(() => {});

    return res.status(502).json({
      ok: false,
      error: 'Failed to create external payment transaction.',
      requestId: inserted.id,
      requestNumber,
      hppTransactionReferenceId: hppReferenceId,
      upstreamStatus,
      upstreamCode,
      details: upstreamMessage,
      upstreamData,
      merchantIdCandidates,
      tokenMerchantId: _toPlainText(tokenClaims?.merchantId),
      tokenTpn: _toPlainText(tokenClaims?.tpn),
    });
  }
});

app.post('/api/paaayit-requests/cancel', async (req, res) => {
  if (!PAAAYIT_REQUESTS_ENABLED) {
    return res.status(404).json({ ok: false, error: 'PaaayIT Request flow is disabled.' });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ ok: false, error: 'Supabase is not configured.' });
  }

  const requestId = _toPlainText(req.body?.requestId);
  const hppReferenceId =
    _toPlainText(req.body?.transactionReferenceId) ||
    _toPlainText(req.body?.hppTransactionReferenceId) ||
    _toPlainText(req.body?.referenceId);
  const cancelReason = _toPlainText(req.body?.cancelReason) || 'Cancelled by operator.';

  if (!requestId && !hppReferenceId) {
    return res.status(400).json({
      ok: false,
      error: 'requestId or transactionReferenceId is required.',
    });
  }

  const found = requestId
    ? await _getPaaayitRequestById(requestId)
    : await _getPaaayitRequestByHppReference(hppReferenceId);
  if (!found) {
    return res.status(404).json({ ok: false, error: 'No PaaayIT request found to cancel.' });
  }

  const currentStatus = _normalizePaaayitStatus(found.status);
  if (['paid', 'reconciled'].includes(currentStatus)) {
    return res.status(409).json({
      ok: false,
      error: 'Payment request cannot be cancelled after it has been paid/reconciled.',
      requestId: found.id,
      status: found.status,
    });
  }

  if (_isCancelledPaaayitStatus(currentStatus)) {
    return res.json({
      ok: true,
      requestId: found.id,
      status: found.status,
      alreadyCancelled: true,
      message: 'Payment request is already cancelled.',
    });
  }

  const providerCancel = await _cancelPaaayitTransactionReference({
    requestRow: found,
    hppReferenceId,
    cancelReason,
  });

  if (!providerCancel.cancelled) {
    return res.status(502).json({
      ok: false,
      error:
        'Unable to cancel upstream payment link. Request was NOT cancelled locally to avoid false state.',
      requestId: found.id,
      status: found.status,
      providerCancel,
    });
  }

  const mergedCancelPayload = _buildMergedProviderPayload({
    requestRow: found,
    providerPayload: {
      cancelSource: 'operator',
      cancelReason,
      cancelledAt: new Date().toISOString(),
      providerCancel,
    },
  });

  const updated = await _updatePaaayitRequestById(found.id, {
    status: 'cancelled',
    cancelled_at: new Date().toISOString(),
    provider_response_payload: mergedCancelPayload,
  });

  return res.json({
    ok: true,
    requestId: updated?.id || found.id,
    status: updated?.status || 'cancelled',
    message: 'Payment request has been cancelled.',
  });
});

app.post('/api/paaayit-requests/webhook/payment', async (req, res) => {
  if (!PAAAYIT_REQUESTS_ENABLED) {
    return res.status(404).json({ ok: false, error: 'PaaayIT Request flow is disabled.' });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ ok: false, error: 'Supabase is not configured.' });
  }
  if (PAAAYIT_WEBHOOK_SECRET) {
    const provided =
      _toPlainText(req.headers['x-paaayit-webhook-secret']) ||
      _toPlainText(req.query?.webhookSecret);
    if (provided !== PAAAYIT_WEBHOOK_SECRET) {
      return res.status(401).json({ ok: false, error: 'Unauthorized webhook request.' });
    }
  }

  const hppReferenceId =
    _toPlainText(req.body?.transactionReferenceId) ||
    _toPlainText(req.body?.hppTransactionReferenceId) ||
    _toPlainText(req.body?.referenceId);
  const hppPaymentId =
    _toPlainText(req.body?.paymentId) ||
    _toPlainText(req.body?.transactionId) ||
    _toPlainText(req.body?.id) ||
    _toPlainText(req.query?.paymentId) ||
    _toPlainText(req.query?.transactionId) ||
    _toPlainText(req.query?.id);
  const result = await _markPaaayitRequestPaidByPayload({
    hppReferenceId,
    hppPaymentId,
    providerPayload: {
      ...(req.body || {}),
      callbackSource: 'provider-webhook',
      callbackReceivedAt: new Date().toISOString(),
    },
  });
  return res.status(result.statusCode).json(result.body);
});

app.get('/api/paaayit-requests/callback/payment-success', async (req, res) => {
  const hppReferenceId =
    _resolveCallbackQueryValue(req.query?.transactionReferenceId) ||
    _resolveCallbackQueryValue(req.query?.hppTransactionReferenceId) ||
    _resolveCallbackQueryValue(req.query?.referenceId);
  const callbackUrl = `${_resolveRequestBaseUrl(req)}${req.originalUrl || req.url || ''}`;
  const paymentId =
    _resolveCallbackQueryValue(req.query?.paymentId) ||
    _resolveCallbackQueryValue(req.query?.transactionId) ||
    _resolveCallbackQueryValue(req.query?.id) ||
    _extractIposTransactionIdFromPaymentUrl(callbackUrl) ||
    _extractIposTransactionIdFromPaymentUrl(_toPlainText(req.query?.t));

  const providerPayload = {
    ...req.query,
    paymentId,
    callbackSource: 'browser-success-redirect',
    callbackReceivedAt: new Date().toISOString(),
  };

  console.log(
    '[PaaayIT callback success]',
    JSON.stringify({
      hppReferenceId,
      paymentId,
      query: req.query || {},
      callbackUrl,
    }),
  );

  const result = await _markPaaayitRequestPaidByPayload({
    hppReferenceId,
    hppPaymentId: paymentId,
    providerPayload,
    skipExpiryCheck: true,
  });

  const ok = result.statusCode >= 200 && result.statusCode < 300;
  return res.status(result.statusCode).send(
    _renderPaaayitCallbackPage({
      title: ok ? 'Payment Approved' : 'Payment Sync Failed',
      heading: ok ? 'Payment Approved' : 'Payment sync failed',
      autoCloseSeconds: 0,
      showManualCloseInstruction: !ok,
      bodyLines: ok
        ? ['Close Browser and Proceed']
        : [
            result.body?.error || 'The payment callback could not be processed automatically.',
            'Return to the register window for manual follow-up if needed.',
          ],
    }),
  );
});

app.get('/api/paaayit-requests/callback/payment-cancel', async (req, res) => {
  return res.status(200).send(
    _renderPaaayitCallbackPage({
      title: 'Payment Cancelled',
      heading: 'Payment cancelled',
      autoCloseSeconds: 0,
      bodyLines: [
        'The hosted payment page reported a cancellation.',
        'Return to the register window to continue.',
      ],
    }),
  );
});

app.get('/api/paaayit-requests/callback/payment-failure', async (req, res) => {
  return res.status(200).send(
    _renderPaaayitCallbackPage({
      title: 'Payment Failed',
      heading: 'Payment failed',
      autoCloseSeconds: 0,
      bodyLines: [
        'The hosted payment page reported a failure.',
        'Return to the register window for the current status.',
      ],
    }),
  );
});

app.post('/api/paaayit-requests/temp-sync-paid', async (req, res) => {
  if (!PAAAYIT_REQUESTS_ENABLED) {
    return res.status(404).json({ ok: false, error: 'PaaayIT Request flow is disabled.' });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ ok: false, error: 'Supabase is not configured.' });
  }

  const hppReferenceId =
    _toPlainText(req.body?.transactionReferenceId) ||
    _toPlainText(req.body?.hppTransactionReferenceId) ||
    _toPlainText(req.body?.referenceId);
  if (!hppReferenceId) {
    return res.status(400).json({ ok: false, error: 'transactionReferenceId is required.' });
  }

  const found = await _getPaaayitRequestByHppReference(hppReferenceId);
  if (!found) {
    return res.status(404).json({ ok: false, error: 'No PaaayIT request found for transactionReferenceId.' });
  }

  const currentStatus = _normalizePaaayitStatus(found.status);
  if (_isCancelledPaaayitStatus(currentStatus)) {
    return res.status(409).json({
      ok: false,
      error: 'Payment request has been cancelled.',
      requestId: found.id,
      status: found.status,
    });
  }

  if (_isExpiredTimestamp(found.expires_at) && !['paid', 'reconciled'].includes(currentStatus)) {
    const expired = await _updatePaaayitRequestById(found.id, {
      status: 'expired',
      expired_at: new Date().toISOString(),
      provider_response_payload: _buildMergedProviderPayload({
        requestRow: found,
        providerPayload: {
          tempSyncSource: 'temp-sync-paid',
          rejectedReason: 'expired',
          rejectedAt: new Date().toISOString(),
        },
      }),
    });
    return res.status(409).json({
      ok: false,
      error: 'Payment request has expired.',
      requestId: expired?.id || found.id,
      status: expired?.status || 'expired',
    });
  }

  const expectedRequestNumber = _toPlainText(req.body?.expectedRequestNumber);
  const expectedAmountRaw = req.body?.expectedAmount;
  const expectedAmount = Number(expectedAmountRaw);
  const foundAmount = Number(found.amount);
  const amountExpectedProvided =
    expectedAmountRaw !== undefined &&
    expectedAmountRaw !== null &&
    String(expectedAmountRaw).trim().length > 0;

  if (expectedRequestNumber && expectedRequestNumber !== _toPlainText(found.request_number)) {
    return res.status(409).json({
      ok: false,
      error: 'Temp sync safety check failed: request number mismatch.',
      expectedRequestNumber,
      actualRequestNumber: _toPlainText(found.request_number),
    });
  }

  if (
    amountExpectedProvided &&
    Number.isFinite(expectedAmount) &&
    Number.isFinite(foundAmount) &&
    Math.abs(expectedAmount - foundAmount) > 0.009
  ) {
    return res.status(409).json({
      ok: false,
      error: 'Temp sync safety check failed: amount mismatch.',
      expectedAmount: Number(expectedAmount.toFixed(2)),
      actualAmount: Number(foundAmount.toFixed(2)),
    });
  }

  // If another channel (for example webhook processing) already marked the
  // request as paid/reconciled, do not block local ledger sync on an
  // additional provider verification round-trip.
  if (['paid', 'reconciled'].includes(currentStatus)) {
    let localTransaction = null;
    try {
      localTransaction = await _ensurePaaayitOpenBatchTransaction({
        requestRow: found,
        providerPayload: found.provider_response_payload || {},
      });
    } catch (syncError) {
      return res.status(502).json({
        ok: false,
        error: 'Request is already paid but local open-batch transaction sync failed.',
        requestId: found.id,
        status: found.status,
        details: syncError?.message || String(syncError),
      });
    }

    return res.json({
      ok: true,
      requestId: found.id,
      status: found.status,
      paidAt: found.paid_at || null,
      localTransaction,
      tempSync: true,
      source: 'request-status-short-circuit',
    });
  }

  const manualOverrideRequested =
    req.body?.manualOverride === true ||
    String(req.body?.manualOverride || '').toLowerCase() === 'true';
  const manualOverrideReason = _toPlainText(req.body?.manualOverrideReason);
  const manualOverrideFeeAmountRaw = req.body?.manualOverrideFeeAmount;
  const manualOverrideFeeAmount = Number(manualOverrideFeeAmountRaw);
  const hasManualOverrideFeeAmount =
    manualOverrideFeeAmountRaw !== undefined &&
    manualOverrideFeeAmountRaw !== null &&
    String(manualOverrideFeeAmountRaw).trim().length > 0;

  if (
    hasManualOverrideFeeAmount &&
    (!Number.isFinite(manualOverrideFeeAmount) || manualOverrideFeeAmount < 0)
  ) {
    return res.status(400).json({
      ok: false,
      error: 'manualOverrideFeeAmount must be a non-negative number.',
    });
  }

  const verification = await _verifyPaaayitTransactionReference({
    requestRow: found,
    hppReferenceId,
  });
  if (!verification.verified) {
    const currentStatus = _normalizePaaayitStatus(found.status);
    const canManualOverride =
      ['pending', 'sent'].includes(currentStatus) &&
      ['verification_call_failed', 'missing_hpp_auth_token'].includes(verification.reason);

    if (manualOverrideRequested && canManualOverride) {
      const mergedTempSyncPayload = _buildMergedProviderPayload({
        requestRow: found,
        providerPayload: {
          ...(verification.payload || {}),
          tempSyncSource: 'temp-sync-paid',
          manualOverride: true,
          ...(hasManualOverrideFeeAmount
            ? { manualOverrideFeeAmount: Number(manualOverrideFeeAmount.toFixed(2)) }
            : {}),
          manualOverrideReason:
            manualOverrideReason || 'Operator confirmed paid after external verification.',
          verificationFailure: verification,
          verifiedAt: new Date().toISOString(),
        },
      });

      const nextStatus = ['reconciled'].includes(currentStatus) ? 'reconciled' : 'paid';
      const updated = await _updatePaaayitRequestById(found.id, {
        status: nextStatus,
        paid_at: found.paid_at || new Date().toISOString(),
        provider_response_payload: mergedTempSyncPayload,
      });

      let localTransaction = null;
      try {
        localTransaction = await _ensurePaaayitOpenBatchTransaction({
          requestRow: updated || found,
          providerPayload: mergedTempSyncPayload,
        });
      } catch (syncError) {
        return res.status(502).json({
          ok: false,
          error: 'Manual temp sync marked paid but local open-batch transaction sync failed.',
          requestId: updated?.id || found.id,
          status: updated?.status || nextStatus,
          details: syncError?.message || String(syncError),
        });
      }

      return res.json({
        ok: true,
        requestId: updated?.id || found.id,
        status: updated?.status || nextStatus,
        paidAt: updated?.paid_at || found.paid_at,
        localTransaction,
        tempSync: true,
        manualOverride: true,
      });
    }

    const verificationError =
      verification.reason === 'missing_hpp_auth_token'
        ? 'Temp sync is blocked: missing hppAuthToken for provider verification.'
        : verification.reason === 'verification_response_not_paid'
          ? 'Temp sync is blocked: provider verification did not confirm a paid transaction.'
          : 'Temp sync is blocked: provider transaction verification failed.';

    return res.status(409).json({
      ok: false,
      error: verificationError,
      verification,
      canManualOverride,
    });
  }

  const mergedTempSyncPayload = _buildMergedProviderPayload({
    requestRow: found,
    providerPayload: {
      ...(verification.payload || {}),
      tempSyncSource: 'temp-sync-paid',
      verifiedByEndpoint: verification.endpoint,
      verifiedAt: new Date().toISOString(),
    },
  });

  const nextStatus = ['reconciled'].includes(currentStatus) ? 'reconciled' : 'paid';

  const updated = await _updatePaaayitRequestById(found.id, {
    status: nextStatus,
    paid_at: found.paid_at || new Date().toISOString(),
    provider_response_payload: mergedTempSyncPayload,
  });

  let localTransaction = null;
  try {
    localTransaction = await _ensurePaaayitOpenBatchTransaction({
      requestRow: updated || found,
      providerPayload: mergedTempSyncPayload,
    });
  } catch (syncError) {
    return res.status(502).json({
      ok: false,
      error: 'Temp sync marked paid but local open-batch transaction sync failed.',
      requestId: updated?.id || found.id,
      status: updated?.status || nextStatus,
      details: syncError?.message || String(syncError),
    });
  }

  return res.json({
    ok: true,
    requestId: updated?.id || found.id,
    status: updated?.status || nextStatus,
    paidAt: updated?.paid_at || found.paid_at,
    localTransaction,
    tempSync: true,
  });
});

app.post('/api/paaayit-requests/reconcile', async (req, res) => {
  if (!PAAAYIT_REQUESTS_ENABLED) {
    return res.status(404).json({ ok: false, error: 'PaaayIT Request flow is disabled.' });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ ok: false, error: 'Supabase is not configured.' });
  }

  const hppReferenceId =
    _toPlainText(req.body?.transactionReferenceId) ||
    _toPlainText(req.body?.hppTransactionReferenceId);
  const reconciliationReferenceId =
    _toPlainText(req.body?.reconciliationReferenceId) || hppReferenceId;
  if (!hppReferenceId) {
    return res.status(400).json({ ok: false, error: 'transactionReferenceId is required.' });
  }

  const found = await _getPaaayitRequestByHppReference(hppReferenceId);
  if (!found) {
    return res.status(404).json({ ok: false, error: 'No PaaayIT request found for transactionReferenceId.' });
  }

  const currentStatus = String(found.status || '').toLowerCase();
  if (!['paid', 'reconciled'].includes(currentStatus)) {
    return res.status(409).json({
      ok: false,
      error: `Request status must be paid/reconciled before reconciliation, current=${currentStatus || 'unknown'}.`,
      requestId: found.id,
      status: found.status,
    });
  }

  const updated = await _updatePaaayitRequestById(found.id, {
    status: 'reconciled',
    reconciliation_reference_id: reconciliationReferenceId,
    provider_response_payload: req.body || {},
  });

  let localTransaction = null;
  try {
    localTransaction = await _ensurePaaayitOpenBatchTransaction({
      requestRow: updated || found,
      providerPayload: req.body || {},
    });
  } catch (syncError) {
    return res.status(502).json({
      ok: false,
      error: 'Reconcile marked but local open-batch transaction sync failed.',
      requestId: updated?.id || found.id,
      status: updated?.status || 'reconciled',
      details: syncError?.message || String(syncError),
    });
  }

  return res.json({
    ok: true,
    requestId: updated?.id || found.id,
    status: updated?.status || 'reconciled',
    reconciliationReferenceId: updated?.reconciliation_reference_id || reconciliationReferenceId,
    localTransaction,
  });
});

// ── SPIn (Dejavoo / iPOSpays) proxy ─────────────────────────────────────────
// Flutter web cannot call test.spinpos.net / api.spinpos.net directly due to
// browser CORS restrictions, so requests are proxied through this backend.

const SPIN_SANDBOX_BASE = 'https://test.spinpos.net';
const SPIN_PROD_BASE    = 'https://api.spinpos.net';

function spinBase(sandbox) {
  return sandbox ? SPIN_SANDBOX_BASE : SPIN_PROD_BASE;
}

function maskSpinToken(value, { head = 4, tail = 2 } = {}) {
  const text = String(value || '').trim();
  if (!text) return '(empty)';
  if (text.length <= head + tail) return `${text.slice(0, 1)}***`;
  return `${text.slice(0, head)}***${text.slice(-tail)}`;
}

function spinResponseSummary(payload) {
  const general = payload?.GeneralResponse || {};
  return {
    resultCode: String(general.ResultCode || ''),
    statusCode: String(general.StatusCode || ''),
    message: String(general.Message || ''),
    detailedMessage: String(general.DetailedMessage || ''),
  };
}

function _isSpinApproved(response) {
  const resultCode = response?.data?.GeneralResponse?.ResultCode?.toString() || '';
  return resultCode === '0';
}

async function _spinCloseBatch({ sandbox, tpn, authKey }) {
  const headers = {
    'Content-Type': 'application/json',
    Accept: 'application/json',
  };

  const callSettle = async (settlementType) => {
    return axios.post(
      `${spinBase(sandbox)}/v2/Payment/Settle`,
      {
        ReferenceId: `CLOSE-${settlementType}-${Date.now()}`,
        GetReceipt: false,
        SettlementType: settlementType,
        Tpn: tpn,
        Authkey: authKey,
      },
      { headers, timeout: 60000 },
    );
  };

  const summarize = (resp) => {
    const general = resp?.data?.GeneralResponse || {};
    return {
      resultCode: String(general.ResultCode || ''),
      statusCode: String(general.StatusCode || ''),
      message: String(general.Message || ''),
      detailedMessage: String(general.DetailedMessage || ''),
    };
  };

  // Primary close path: current SPIn close-batch operation.
  try {
    const settleResponse = await callSettle('Close');
    console.log('[SPIn CloseBatch] Settle(Close):', summarize(settleResponse));

    if (_isSpinApproved(settleResponse)) {
      return settleResponse;
    }

    // Some deployments return terminal-level Canceled on Settle while still
    // supporting the legacy close route; try it before surfacing failure.
    try {
      const legacyResponse = await axios.post(
        `${spinBase(sandbox)}/v2/Batch/Close`,
        { Tpn: tpn, Authkey: authKey },
        { headers, timeout: 60000 },
      );
      console.log('[SPIn CloseBatch] Batch/Close:', summarize(legacyResponse));
      if (_isSpinApproved(legacyResponse)) {
        return legacyResponse;
      }

      // Final fallback: some setups require Force settlement when Close is
      // rejected for validation reasons.
      const forceResponse = await callSettle('Force');
      console.log('[SPIn CloseBatch] Settle(Force):', summarize(forceResponse));
      return _isSpinApproved(forceResponse) ? forceResponse : settleResponse;
    } catch (_) {
      try {
        const forceResponse = await callSettle('Force');
        console.log('[SPIn CloseBatch] Settle(Force):', summarize(forceResponse));
        return _isSpinApproved(forceResponse) ? forceResponse : settleResponse;
      } catch {
        return settleResponse;
      }
    }
  } catch (err) {
    const status = err?.response?.status;
    // Legacy fallback for environments still exposing the older route.
    if (status === 404) {
      return axios.post(
        `${spinBase(sandbox)}/v2/Batch/Close`,
        { Tpn: tpn, Authkey: authKey },
        { headers, timeout: 60000 },
      );
    }
    throw err;
  }
}

async function _spinReport({ sandbox, tpn, authKey, endpoint }) {
  return axios.post(
    `${spinBase(sandbox)}${endpoint}`,
    {
      Tpn: tpn,
      Authkey: authKey,
      SPInProxyTimeout: null,
      CustomFields: {},
    },
    {
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      timeout: 60000,
    },
  );
}

async function _spinTerminalBestEffort({ sandbox, body, endpoints }) {
  const headers = {
    'Content-Type': 'application/json',
    Accept: 'application/json',
  };

  let lastError = null;
  for (const endpoint of endpoints) {
    try {
      const response = await axios.post(
        `${spinBase(sandbox)}${endpoint}`,
        body,
        { headers, timeout: 10000 },
      );
      return {
        ok: true,
        endpoint,
        status: response.status,
        data: response.data,
      };
    } catch (err) {
      lastError = err;
    }
  }

  return {
    ok: false,
    endpoint: null,
    status: lastError?.response?.status || 502,
    data: lastError?.response?.data || { error: lastError?.message || 'terminal action failed' },
  };
}

function _supabaseHeaders() {
  return {
    apikey: SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    'Content-Type': 'application/json',
    Accept: 'application/json',
  };
}

function _todayKey() {
  const now = new Date();
  const yyyy = now.getFullYear().toString().padStart(4, '0');
  const mm = (now.getMonth() + 1).toString().padStart(2, '0');
  const dd = now.getDate().toString().padStart(2, '0');
  return `${yyyy}${mm}${dd}`;
}

function _smtpConfigured() {
  return Boolean(SMTP_HOST && SMTP_PORT > 0 && SMTP_USER && SMTP_PASS && SMTP_FROM);
}

function _toPlainText(value) {
  return String(value || '').trim();
}

function _isValidEmail(value) {
  const email = _toPlainText(value);
  if (!email) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

async function _sendPaaayitRequestEmail({
  recipientEmail,
  customerName,
  locationName,
  paymentReference,
  requestNumber,
  amount,
  paymentUrl,
  expiresAt,
  pdfBase64,
  pdfFilename,
}) {
  if (!_smtpConfigured()) {
    return { ok: false, skipped: 'smtp_not_configured' };
  }

  const recipient = _toPlainText(recipientEmail);
  const url = _toPlainText(paymentUrl);
  if (!recipient || !url) {
    return { ok: false, skipped: 'missing_recipient_or_url' };
  }

  const safeName = _toPlainText(customerName);
  const safeLocationName = _toPlainText(locationName);
  const safeReference = _toPlainText(paymentReference);
  const safeRequestNumber = _toPlainText(requestNumber);
  const amountValue = Number(amount);
  const amountText = Number.isFinite(amountValue)
    ? amountValue.toFixed(2)
    : _toPlainText(amount);
  const payButtonText = amountText ? `PaaayIT Now - $${amountText}` : 'PaaayIT Now';
  const safeExpiresAt = _toPlainText(expiresAt);
  const expiresDate = safeExpiresAt ? new Date(safeExpiresAt) : null;
  const hasValidExpiry = Boolean(expiresDate) && !Number.isNaN(expiresDate.getTime());
  const expiresLocal = hasValidExpiry
    ? expiresDate.toLocaleString('en-US', {
        year: 'numeric',
        month: 'short',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        timeZoneName: 'short',
      })
    : '';
  const expiresUtc = hasValidExpiry ? expiresDate.toISOString() : '';

  const logoPath = path.join(REPO_ROOT, 'assets', 'icons', 'Blue arrows-icon.png');
  const logoCid = 'paaayit-logo';
  const invoiceTitle = `${safeLocationName || 'PaaayIT'} - E-Invoice`;

  const lines = [
    invoiceTitle,
    '',
    safeLocationName ? `Location Name: ${safeLocationName}` : null,
    safeName ? `Customer Name: ${safeName}` : null,
    safeReference ? `Payment Reference: ${safeReference}` : null,
    safeRequestNumber ? `Request Number: ${safeRequestNumber}` : null,
    amountText ? `Amount: $${amountText}` : null,
    expiresLocal ? `Link Expires: ${expiresLocal}` : null,
    expiresUtc ? `UTC Reference: ${expiresUtc}` : null,
    '',
    'Complete payment using the secure link below:',
    url,
  ].filter(Boolean);

  const attachments = [];
  let attachedPdf = false;
  if (fs.existsSync(logoPath)) {
    attachments.push({
      filename: 'paaayit-logo.png',
      path: logoPath,
      cid: logoCid,
    });
  }

  const base64Raw = _toPlainText(pdfBase64);
  if (base64Raw) {
    const cleaned = base64Raw.replace(/^data:application\/pdf;base64,/i, '');
    const bytes = Buffer.from(cleaned, 'base64');
    if (bytes.length > 0) {
      attachedPdf = true;
      attachments.push({
        filename: _toPlainText(pdfFilename) || `e-invoice-${Date.now()}.pdf`,
        content: bytes,
        contentType: 'application/pdf',
      });
    }
  }

  const transporter = nodemailer.createTransport({
    host: SMTP_HOST,
    port: SMTP_PORT,
    secure: SMTP_SECURE,
    auth: {
      user: SMTP_USER,
      pass: SMTP_PASS,
    },
  });

  const logoHtml = fs.existsSync(logoPath)
    ? `<img src="cid:${logoCid}" alt="PaaayIT" style="height:28px;vertical-align:middle;margin-right:8px;" />`
    : '';
  const htmlBody = `
    <div style="font-family:Segoe UI,Arial,sans-serif;color:#13325b;line-height:1.45;">
      <div style="margin-bottom:12px;font-size:20px;font-weight:700;display:flex;align-items:center;">
        ${logoHtml}<span>${invoiceTitle}</span>
      </div>
      <p style="margin:0 0 8px 0;">${safeLocationName ? `Location Name: <strong>${safeLocationName}</strong><br/>` : ''}${safeName ? `Customer Name: <strong>${safeName}</strong><br/>` : ''}${safeReference ? `Payment Reference: <strong>${safeReference}</strong><br/>` : ''}${safeRequestNumber ? `Request Number: <strong>${safeRequestNumber}</strong><br/>` : ''}${amountText ? `Amount: <strong>$${amountText}</strong><br/>` : ''}${expiresLocal ? `Link Expires: <strong>${expiresLocal}</strong><br/>` : ''}${expiresUtc ? `UTC Reference: <strong>${expiresUtc}</strong>` : ''}</p>
      <p style="margin:12px 0 14px 0;">Use the button below to pay securely:</p>
      <a href="${url}" style="display:inline-block;background:#0A4FAF;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;font-weight:700;">${payButtonText}</a>
      <p style="margin:14px 0 0 0;font-size:12px;color:#4a607b;">If the button does not open, copy and paste this link:<br/>${url}</p>
    </div>
  `;

  const sendResult = await transporter.sendMail({
    from: SMTP_FROM,
    to: recipient,
    replyTo: SMTP_REPLY_TO || undefined,
    subject: invoiceTitle,
    text: lines.join('\n'),
    html: htmlBody,
    attachments,
  });

  return {
    ok: true,
    messageId: sendResult?.messageId || null,
    attachedPdf,
  };
}

function _parseTimeToMinutes(value) {
  const text = String(value || '').trim();
  const m = text.match(/^(\d{1,2}):(\d{2})(?::\d{2})?$/);
  if (!m) return null;
  const hh = Number(m[1]);
  const mm = Number(m[2]);
  if (Number.isNaN(hh) || Number.isNaN(mm) || hh < 0 || hh > 23 || mm < 0 || mm > 59) {
    return null;
  }
  return hh * 60 + mm;
}

async function _fetchAutoCloseTerminals() {
  const url = `${SUPABASE_URL}/rest/v1/terminals`;
  const response = await axios.get(url, {
    params: {
      select:
        'id,organization_id,location_id,spin_tpn,spin_auth_key,is_active,auto_close_batch_enabled,auto_close_batch_time',
      is_active: 'eq.true',
      auto_close_batch_enabled: 'eq.true',
    },
    headers: _supabaseHeaders(),
    timeout: 15000,
  });
  return Array.isArray(response.data) ? response.data : [];
}

async function _fetchOpenBatchRowsForTerminal({ organizationId, locationId, terminalId }) {
  const url = `${SUPABASE_URL}/rest/v1/transaction_details`;
  const response = await axios.get(url, {
    params: {
      select: 'id,status,transaction_headers!inner(terminal_id)',
      organization_id: `eq.${organizationId}`,
      location_id: `eq.${locationId}`,
      payment_type: 'eq.d',
      batch_status: 'eq.o',
      status: 'in.(approved,voided)',
      'transaction_headers.terminal_id': `eq.${terminalId}`,
      order: 'created_at.desc',
      limit: '1000',
    },
    headers: _supabaseHeaders(),
    timeout: 20000,
  });
  return Array.isArray(response.data) ? response.data : [];
}

async function _markBatchClosed(detailIds) {
  if (!Array.isArray(detailIds) || detailIds.length === 0) return;
  const url = `${SUPABASE_URL}/rest/v1/transaction_details`;
  await axios.patch(
    url,
    { batch_status: 'c' },
    {
      params: {
        id: `in.(${detailIds.map((v) => String(v)).join(',')})`,
      },
      headers: {
        ..._supabaseHeaders(),
        Prefer: 'return=minimal',
      },
      timeout: 20000,
    },
  );
}

async function _runAutoCloseBatchSweep() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return {
      ok: false,
      message: 'Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY.',
      terminalsProcessed: 0,
      terminalsClosed: 0,
      terminalsSkipped: 0,
    };
  }

  const now = new Date();
  const nowMinutes = now.getHours() * 60 + now.getMinutes();
  const dayKey = _todayKey();
  let terminalsProcessed = 0;
  let terminalsClosed = 0;
  let terminalsSkipped = 0;

  const terminals = await _fetchAutoCloseTerminals();
  for (const terminal of terminals) {
    const targetMinutes = _parseTimeToMinutes(terminal.auto_close_batch_time);
    if (targetMinutes == null || nowMinutes < targetMinutes) {
      terminalsSkipped += 1;
      continue;
    }

    terminalsProcessed += 1;

    const memoKey = `${terminal.organization_id}:${terminal.id}:${dayKey}`;
    if (_autoCloseRunMemo.get(memoKey) === true) {
      terminalsSkipped += 1;
      continue;
    }

    const tpn = String(terminal.spin_tpn || '').trim();
    const authKey = String(terminal.spin_auth_key || '').trim();
    if (!tpn || !authKey) {
      terminalsSkipped += 1;
      continue;
    }

    const openRows = await _fetchOpenBatchRowsForTerminal({
      organizationId: terminal.organization_id,
      locationId: terminal.location_id,
      terminalId: terminal.id,
    });
    const openIds = openRows.map((r) => r.id).filter(Boolean);
    const approvedCount = openRows.filter((r) => String(r.status || '').toLowerCase() === 'approved').length;

    if (openIds.length === 0) {
      _autoCloseRunMemo.set(memoKey, true);
      terminalsSkipped += 1;
      continue;
    }

    if (approvedCount === 0) {
      await _markBatchClosed(openIds);
      _autoCloseRunMemo.set(memoKey, true);
      terminalsClosed += 1;
      continue;
    }

    try {
      const response = await _spinCloseBatch({
        sandbox: SPIN_AUTOCLOSE_SANDBOX,
        tpn,
        authKey,
      });
      const resultCode = response?.data?.GeneralResponse?.ResultCode?.toString() || '';
      if (resultCode === '0') {
        await _markBatchClosed(openIds);
        _autoCloseRunMemo.set(memoKey, true);
        terminalsClosed += 1;
        console.log(
          `[AutoCloseBatch] Closed terminal=${terminal.id} org=${terminal.organization_id} location=${terminal.location_id} approved=${approvedCount} rows=${openIds.length}`,
        );
      } else {
        terminalsSkipped += 1;
      }
    } catch (_) {
      terminalsSkipped += 1;
    }
  }

  return {
    ok: true,
    terminalsProcessed,
    terminalsClosed,
    terminalsSkipped,
    checkedAt: now.toISOString(),
  };
}

app.post('/api/spin/sale', async (req, res) => {
  const { sandbox, tpn, authKey, amount, paymentType, referenceId, calculateFee } = req.body;
  if (!tpn || !authKey || amount == null || !referenceId) {
    return res.status(400).json({ error: 'tpn, authKey, amount, referenceId are required' });
  }

  console.log(
    `[SPIn] Sale request ref=${referenceId} amount=${amount} sandbox=${Boolean(
      sandbox,
    )} base=${spinBase(Boolean(sandbox))} tpn=${maskSpinToken(tpn, {
      head: 6,
      tail: 2,
    })} authKey=${maskSpinToken(authKey, { head: 2, tail: 2 })}`,
  );

  const saleUrl = `${spinBase(sandbox)}/v2/Payment/Sale`;
  const saleBody = {
    Amount: amount,
    PaymentType: paymentType || 'Credit',
    CalculateFee: calculateFee === true,
    ReferenceId: referenceId,
    PrintReceipt: 'No',
    GetReceipt: 'No',
    GetExtendedData: true,
    IsReadyForIS: false,
    Tpn: tpn,
    Authkey: authKey,
  };
  const saleConfig = {
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    timeout: 125000,
  };

  const postSale = () => axios.post(saleUrl, saleBody, saleConfig);

  try {
    const response = await postSale();
    console.log('[SPIn] Sale response:', spinResponseSummary(response.data));
    res.status(response.status).json(response.data);
  } catch (err) {
    if (err.response && isTerminalBusySpinResponse(err.response.data)) {
      const waitSeconds = terminalBusyDelaySeconds(err.response.data);
      console.warn(
        `[SPIn] Terminal busy for sale (ref=${referenceId}). Waiting ${waitSeconds}s and retrying once.`,
      );
      await waitMs(waitSeconds * 1000);

      try {
        const retryResponse = await postSale();
        console.log('[SPIn] Sale retry response:', spinResponseSummary(retryResponse.data));
        return res.status(retryResponse.status).json(retryResponse.data);
      } catch (retryErr) {
        if (retryErr.response) {
          console.warn('[SPIn] Sale retry error:', spinResponseSummary(retryErr.response.data));
          return res.status(retryErr.response.status).json(retryErr.response.data);
        }
        return res.status(502).json({ error: retryErr.message });
      }
    }

    if (err.response) {
      console.warn('[SPIn] Sale error:', spinResponseSummary(err.response.data));
      res.status(err.response.status).json(err.response.data);
    } else {
      res.status(502).json({ error: err.message });
    }
  }
});

app.post('/api/spin/sale-keyed', async (req, res) => {
  const {
    sandbox,
    tpn,
    authKey,
    amount,
    paymentType,
    calculateFee,
    referenceId,
    cardNumber,
    expirationDate,
    cvv,
    streetAddress,
    zipCode,
  } = req.body;

  if (!tpn || !authKey || amount == null || !referenceId) {
    return res.status(400).json({ error: 'tpn, authKey, amount, referenceId are required' });
  }

  const digitsOnly = (v) => String(v || '').replace(/\D/g, '');
  const cardNumberDigits = digitsOnly(cardNumber);
  const cvvDigits = digitsOnly(cvv);
  const expDigits = digitsOnly(expirationDate);
  if (cardNumberDigits.length < 12 || cardNumberDigits.length > 19) {
    return res.status(400).json({ error: 'cardNumber must be 12-19 digits' });
  }
  if (cvvDigits.length < 3 || cvvDigits.length > 4) {
    return res.status(400).json({ error: 'cvv must be 3-4 digits' });
  }
  if (expDigits.length !== 4) {
    return res.status(400).json({ error: 'expirationDate must be MMYY or MM/YY' });
  }

  const mm = expDigits.slice(0, 2);
  const yy = expDigits.slice(2);
  const month = Number(mm);
  if (!Number.isFinite(month) || month < 1 || month > 12) {
    return res.status(400).json({ error: 'expirationDate month must be 01-12' });
  }

  const maskedPan = `${'*'.repeat(Math.max(0, cardNumberDigits.length - 4))}${cardNumberDigits.slice(-4)}`;
  console.log(`[SPIn] Keyed sale request ref=${referenceId} amount=${amount} pan=${maskedPan}`);

  const saleUrl = `${spinBase(sandbox)}/v2/Payment/Sale`;
  const saleBody = {
    Amount: amount,
    PaymentType: paymentType || 'Credit',
    CalculateFee: calculateFee === true,
    ReferenceId: referenceId,
    PrintReceipt: 'No',
    GetReceipt: 'No',
    GetExtendedData: true,
    IsReadyForIS: false,
    Tpn: tpn,
    Authkey: authKey,

    // Include common keyed-entry field aliases because SPIn variants differ
    // by gateway version/profile.
    CardNumber: cardNumberDigits,
    ExpirationDate: `${mm}${yy}`,
    ExpDate: `${mm}${yy}`,
    CVV: cvvDigits,
    Cvv: cvvDigits,
    CVV2: cvvDigits,
    AvsAddress: String(streetAddress || '').trim(),
    AvsZip: digitsOnly(zipCode),
    EntryMode: 'Keyed',
    ManualEntry: true,
    CardData: {
      CardNumber: cardNumberDigits,
      ExpirationDate: `${mm}${yy}`,
      CVV: cvvDigits,
      AVSAddress: String(streetAddress || '').trim(),
      AVSZip: digitsOnly(zipCode),
      EntryMode: 'Keyed',
    },
  };

  const saleConfig = {
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    timeout: 125000,
  };

  const postSale = () => axios.post(saleUrl, saleBody, saleConfig);

  try {
    const response = await postSale();
    res.status(response.status).json(response.data);
  } catch (err) {
    if (err.response && isTerminalBusySpinResponse(err.response.data)) {
      const waitSeconds = terminalBusyDelaySeconds(err.response.data);
      console.warn(
        `[SPIn] Terminal busy for keyed sale (ref=${referenceId}). Waiting ${waitSeconds}s and retrying once.`,
      );
      await waitMs(waitSeconds * 1000);

      try {
        const retryResponse = await postSale();
        return res.status(retryResponse.status).json(retryResponse.data);
      } catch (retryErr) {
        if (retryErr.response) {
          return res.status(retryErr.response.status).json(retryErr.response.data);
        }
        return res.status(502).json({ error: retryErr.message });
      }
    }

    if (err.response) {
      res.status(err.response.status).json(err.response.data);
    } else {
      res.status(502).json({ error: err.message });
    }
  }
});

app.post('/api/spin/abort', async (req, res) => {
  const { sandbox, tpn, authKey, referenceId } = req.body;
  if (!tpn || !authKey || !referenceId) {
    return res.status(400).json({ error: 'tpn, authKey, referenceId are required' });
  }
  try {
    const response = await axios.post(
      `${spinBase(sandbox)}/v2/Payment/AbortTransaction`,
      { ReferenceId: referenceId, Tpn: tpn, Authkey: authKey },
      { headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, timeout: 15000 },
    );
    res.status(response.status).json(response.data);
  } catch (err) {
    if (err.response) {
      res.status(err.response.status).json(err.response.data);
    } else {
      res.status(502).json({ error: err.message });
    }
  }
});

app.post('/api/spin/void', async (req, res) => {
  const { sandbox, tpn, authKey, referenceId, gatewayToken, amount, paymentType } = req.body;
  if (!tpn || !authKey || !referenceId) {
    return res.status(400).json({ error: 'tpn, authKey, referenceId are required' });
  }

  const numericAmount = Number(amount);
  if (!Number.isFinite(numericAmount) || numericAmount <= 0) {
    return res.status(400).json({
      error: 'amount must be a positive number for void requests',
      providedAmount: amount,
    });
  }

  const voidUrl = `${spinBase(sandbox)}/v2/Payment/Void`;
  const headers = { 'Content-Type': 'application/json', Accept: 'application/json' };
  const txToken = String(gatewayToken || '').trim();
  const hasDistinctTxToken = txToken.isNotEmpty && txToken !== String(referenceId || '').trim();

  const baseBody = {
    PrintReceipt: 'No',
    GetReceipt: 'No',
    IsReadyForIS: false,
    Tpn: tpn,
    Authkey: authKey,
    Amount: Number(numericAmount.toFixed(2)),
    PaymentType: paymentType || 'Credit',
  };

  const primaryBody = {
    ...baseBody,
    ReferenceId: referenceId,
    ...(hasDistinctTxToken ? { TransactionId: txToken } : {}),
  };

  const isSpinNotFound = (payload) => {
    const statusCode = String(payload?.GeneralResponse?.StatusCode || '').trim();
    const message = String(payload?.GeneralResponse?.Message || '').trim().toLowerCase();
    const detailed = String(payload?.GeneralResponse?.DetailedMessage || '').trim().toLowerCase();
    return statusCode === '1001' || message.includes('not found') || detailed.includes('not found');
  };

  try {
    const response = await axios.post(voidUrl, primaryBody, { headers, timeout: 30000 });
    return res.status(response.status).json(response.data);
  } catch (err) {
    if (!err.response) {
      return res.status(502).json({ error: err.message });
    }

    // Some gateways require a fresh void request ReferenceId while targeting
    // the original sale via TransactionId. Retry once when initial lookup is
    // "not found" and we have a distinct gateway token.
    if (hasDistinctTxToken && isSpinNotFound(err.response.data)) {
      try {
        const retryBody = {
          ...baseBody,
          ReferenceId: `VOID-${Date.now()}`,
          TransactionId: txToken,
        };
        const retry = await axios.post(voidUrl, retryBody, { headers, timeout: 30000 });
        return res.status(retry.status).json(retry.data);
      } catch (retryErr) {
        if (retryErr.response) {
          return res.status(retryErr.response.status).json(retryErr.response.data);
        }
        return res.status(502).json({ error: retryErr.message });
      }
    }

    return res.status(err.response.status).json(err.response.data);
  }
});

app.post('/api/spin/refund', async (req, res) => {
  const { sandbox, tpn, authKey, amount, referenceId, gatewayToken } = req.body;
  if (!tpn || !authKey || amount == null || !referenceId) {
    return res.status(400).json({ error: 'tpn, authKey, amount, referenceId are required' });
  }

  const numericAmount = Number(amount);
  if (!Number.isFinite(numericAmount) || numericAmount <= 0) {
    return res.status(400).json({
      error: 'amount must be a positive number for refund requests',
      providedAmount: amount,
    });
  }

  const refundUrl = `${spinBase(sandbox)}/v2/Payment/Return`;
  const headers = { 'Content-Type': 'application/json', Accept: 'application/json' };
  const txToken = String(gatewayToken || '').trim();
  const hasDistinctTxToken = txToken.isNotEmpty && txToken !== String(referenceId || '').trim();

  const baseBody = {
    Amount: Number(numericAmount.toFixed(2)),
    PaymentType: 'Credit',
    PrintReceipt: 'No',
    GetReceipt: 'No',
    GetExtendedData: true,
    IsReadyForIS: false,
    Tpn: tpn,
    Authkey: authKey,
  };

  const primaryBody = {
    ...baseBody,
    ReferenceId: referenceId,
    ...(hasDistinctTxToken ? { TransactionId: txToken } : {}),
  };

  const isSpinNotFound = (payload) => {
    const statusCode = String(payload?.GeneralResponse?.StatusCode || '').trim();
    const message = String(payload?.GeneralResponse?.Message || '').trim().toLowerCase();
    const detailed = String(payload?.GeneralResponse?.DetailedMessage || '').trim().toLowerCase();
    return statusCode === '1001' || message.includes('not found') || detailed.includes('not found');
  };

  try {
    const response = await axios.post(refundUrl, primaryBody, { headers, timeout: 60000 });
    return res.status(response.status).json(response.data);
  } catch (err) {
    if (!err.response) {
      return res.status(502).json({ error: err.message });
    }

    // Some gateways require a fresh Return request ReferenceId while targeting
    // the original sale via TransactionId. Retry once when lookup is "not found"
    // and a distinct transaction token is available.
    if (hasDistinctTxToken && isSpinNotFound(err.response.data)) {
      try {
        const retryBody = {
          ...baseBody,
          ReferenceId: `REFUND-${Date.now()}`,
          TransactionId: txToken,
        };
        const retry = await axios.post(refundUrl, retryBody, { headers, timeout: 60000 });
        return res.status(retry.status).json(retry.data);
      } catch (retryErr) {
        if (retryErr.response) {
          return res.status(retryErr.response.status).json(retryErr.response.data);
        }
        return res.status(502).json({ error: retryErr.message });
      }
    }

    return res.status(err.response.status).json(err.response.data);
  }
});

app.post('/api/spin/tip-adjust', async (req, res) => {
  const { sandbox, tpn, authKey, amount, tipAmount, referenceId, paymentType, gatewayProvider } = req.body;
  if (!tpn || !authKey || amount == null || tipAmount == null || !referenceId) {
    return res.status(400).json({ error: 'tpn, authKey, amount, tipAmount, referenceId are required' });
  }

  const numericAmount = Number(amount);
  const numericTipAmount = Number(tipAmount);
  if (!Number.isFinite(numericAmount) || numericAmount <= 0) {
    return res.status(400).json({
      error: 'amount must be a positive number for tip-adjust requests',
      providedAmount: amount,
    });
  }
  if (!Number.isFinite(numericTipAmount) || numericTipAmount < 0) {
    return res.status(400).json({
      error: 'tipAmount must be a non-negative number for tip-adjust requests',
      providedTipAmount: tipAmount,
    });
  }

  try {
    const body = {
      Amount: Number(numericAmount.toFixed(2)),
      TipAmount: Number(numericTipAmount.toFixed(2)),
      PaymentType: paymentType || 'Credit',
      ReferenceId: referenceId,
      GetExtendedData: true,
      IsReadyForIS: false,
      Tpn: tpn,
      Authkey: authKey,
    };

    const response = await axios.post(
      `${spinBase(sandbox)}/v2/Payment/TipAdjust`,
      body,
      { headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, timeout: 60000 },
    );
    res.status(response.status).json(response.data);
  } catch (err) {
    if (err.response) {
      res.status(err.response.status).json(err.response.data);
    } else {
      res.status(502).json({ error: err.message });
    }
  }
});

app.post('/api/spin/device-message', async (req, res) => {
  const { sandbox, tpn, authKey, message } = req.body;
  if (!tpn || !authKey || !String(message || '').trim()) {
    return res.status(400).json({ error: 'tpn, authKey, and message are required' });
  }

  const payload = {
    Message: String(message).trim().slice(0, 64),
    Tpn: tpn,
    Authkey: authKey,
  };

  const result = await _spinTerminalBestEffort({
    sandbox,
    body: payload,
    endpoints: ['/v2/Terminal/DisplayMessage', '/v2/Payment/DisplayMessage'],
  });

  if (result.ok) {
    return res.status(200).json(result.data);
  }

  // Keep this non-fatal to the register flow.
  return res.status(200).json({
    ok: false,
    warning: 'Unable to display message on terminal',
    status: result.status,
    upstream: result.data,
  });
});

app.post('/api/spin/device-ready', async (req, res) => {
  const { sandbox, tpn, authKey } = req.body;
  if (!tpn || !authKey) {
    return res.status(400).json({ error: 'tpn and authKey are required' });
  }

  const payload = {
    IsReadyForIS: true,
    Tpn: tpn,
    Authkey: authKey,
  };

  const result = await _spinTerminalBestEffort({
    sandbox,
    body: payload,
    endpoints: ['/v2/Terminal/SetReadyForIS', '/v2/Payment/SetReadyForIS'],
  });

  if (result.ok) {
    return res.status(200).json(result.data);
  }

  // Keep this non-fatal to the register flow.
  return res.status(200).json({
    ok: false,
    warning: 'Unable to set terminal ready state',
    status: result.status,
    upstream: result.data,
  });
});

app.post('/api/spin/closebatch', async (req, res) => {
  const { sandbox, tpn, authKey } = req.body;
  if (!tpn || !authKey) {
    return res.status(400).json({ error: 'tpn and authKey are required' });
  }
  try {
    const response = await _spinCloseBatch({ sandbox, tpn, authKey });
    res.status(response.status).json(response.data);
  } catch (err) {
    if (err.response) {
      if (typeof err.response.data === 'string') {
        res.status(err.response.status).send(err.response.data);
      } else {
        res.status(err.response.status).json(err.response.data);
      }
    } else {
      res.status(502).json({ error: err.message });
    }
  }
});

app.post('/api/spin/report/daily', async (req, res) => {
  const { sandbox, tpn, authKey } = req.body;
  if (!tpn || !authKey) {
    return res.status(400).json({ error: 'tpn and authKey are required' });
  }
  try {
    const response = await _spinReport({
      sandbox,
      tpn,
      authKey,
      endpoint: '/v2/Report/Daily',
    });
    res.status(response.status).json(response.data);
  } catch (err) {
    if (err.response) {
      res.status(err.response.status).json(err.response.data);
    } else {
      res.status(502).json({ error: err.message });
    }
  }
});

app.post('/api/spin/report/summary', async (req, res) => {
  const { sandbox, tpn, authKey } = req.body;
  if (!tpn || !authKey) {
    return res.status(400).json({ error: 'tpn and authKey are required' });
  }
  try {
    const response = await _spinReport({
      sandbox,
      tpn,
      authKey,
      endpoint: '/v2/Report/Summary',
    });
    res.status(response.status).json(response.data);
  } catch (err) {
    if (err.response) {
      res.status(err.response.status).json(err.response.data);
    } else {
      res.status(502).json({ error: err.message });
    }
  }
});

app.post('/api/batch/mark-closed', async (req, res) => {
  const detailIds = Array.isArray(req.body?.detailIds)
    ? req.body.detailIds.map((v) => String(v || '').trim()).filter(Boolean)
    : [];

  if (detailIds.length === 0) {
    return res.status(400).json({ error: 'detailIds array is required' });
  }

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({
      ok: false,
      error: 'Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in backend environment.',
      hasSupabaseUrl: Boolean(SUPABASE_URL),
      hasServiceRoleKey: Boolean(SUPABASE_SERVICE_ROLE_KEY),
    });
  }

  try {
    await _markBatchClosed(detailIds);
    return res.json({ ok: true, closedCount: detailIds.length });
  } catch (error) {
    console.error('[Batch MarkClosed] failed:', error?.response?.status || '', error?.response?.data || error);
    return res.status(500).json({
      ok: false,
      error: error.toString(),
      upstreamStatus: error?.response?.status || null,
      upstreamData: error?.response?.data || null,
    });
  }
});

app.post('/api/receipts/email', async (req, res) => {
  const recipientEmail = _toPlainText(req.body?.recipientEmail);
  const pdfBase64Raw = _toPlainText(req.body?.pdfBase64);
  const filename = _toPlainText(req.body?.filename) || `receipt-${Date.now()}.pdf`;
  const requestReplyTo = _toPlainText(req.body?.replyTo);
  const subject =
    _toPlainText(req.body?.subject) || 'Your Receipt';
  const bodyText =
    _toPlainText(req.body?.textBody) ||
    'Thank you for your payment. Your receipt is attached.';

  if (!recipientEmail) {
    return res.status(400).json({ ok: false, error: 'recipientEmail is required' });
  }
  if (!_isValidEmail(recipientEmail)) {
    return res.status(400).json({ ok: false, error: 'recipientEmail format is invalid' });
  }
  if (!pdfBase64Raw) {
    return res.status(400).json({ ok: false, error: 'pdfBase64 is required' });
  }
  if (!_smtpConfigured()) {
    return res.status(500).json({
      ok: false,
      error: 'SMTP is not configured on backend',
      hasHost: Boolean(SMTP_HOST),
      hasPort: Boolean(SMTP_PORT),
      hasUser: Boolean(SMTP_USER),
      hasPass: Boolean(SMTP_PASS),
      hasFrom: Boolean(SMTP_FROM),
    });
  }

  try {
    const transporter = nodemailer.createTransport({
      host: SMTP_HOST,
      port: SMTP_PORT,
      secure: SMTP_SECURE,
      auth: {
        user: SMTP_USER,
        pass: SMTP_PASS,
      },
    });

    const pdfBase64 = pdfBase64Raw.replace(/^data:application\/pdf;base64,/i, '');
    const attachmentBytes = Buffer.from(pdfBase64, 'base64');

    const sendResult = await transporter.sendMail({
      from: SMTP_FROM,
      to: recipientEmail,
      replyTo: requestReplyTo || SMTP_REPLY_TO || undefined,
      subject,
      text: bodyText,
      attachments: [
        {
          filename,
          content: attachmentBytes,
          contentType: 'application/pdf',
        },
      ],
    });

    return res.json({
      ok: true,
      messageId: sendResult?.messageId || null,
      recipientEmail,
      filename,
    });
  } catch (error) {
    console.error('[ReceiptEmail] send failed:', error);
    return res.status(502).json({
      ok: false,
      error: error?.message || String(error),
    });
  }
});

app.get('/api/health', (req, res) => {
  res.json({
    ok: true,
    service: 'pregister-backend',
    uptimeSec: Math.floor(process.uptime()),
    port: Number(PORT),
    hasSupabaseUrl: Boolean(SUPABASE_URL),
    hasServiceRoleKey: Boolean(SUPABASE_SERVICE_ROLE_KEY),
    hasSmtpConfig: _smtpConfigured(),
    paaayitRequestsEnabled: PAAAYIT_REQUESTS_ENABLED,
    timestamp: new Date().toISOString(),
  });
});

app.post('/api/install-identity', (req, res) => {
  const identity = req.body?.identity;
  if (!identity || typeof identity !== 'object' || Array.isArray(identity)) {
    return res.status(400).json({
      ok: false,
      error: 'identity object is required',
    });
  }

  const normalize = (value) => String(value || '').trim();
  const nextIdentity = {
    appLicenseKey: normalize(identity.appLicenseKey),
    organizationNumber: normalize(identity.organizationNumber),
    terminalNumber: normalize(identity.terminalNumber),
    locationName: normalize(identity.locationName),
    spinTpn: normalize(identity.spinTpn),
    spinAuthKey: normalize(identity.spinAuthKey),
    appDeviceId: normalize(identity.appDeviceId),
    appDeviceLabel: normalize(identity.appDeviceLabel),
  };

  if (!nextIdentity.appLicenseKey && !nextIdentity.organizationNumber) {
    return res.status(400).json({
      ok: false,
      error: 'appLicenseKey or organizationNumber is required',
    });
  }

  if (!nextIdentity.terminalNumber) {
    nextIdentity.terminalNumber = '0001';
  }

  try {
    fs.mkdirSync(RUNTIME_DIR, { recursive: true });
    fs.writeFileSync(
      INSTALL_IDENTITY_PATH,
      `${JSON.stringify(nextIdentity, null, 2)}\n`,
      'utf8',
    );
    return res.json({
      ok: true,
      relativePath: 'runtime/install.identity.json',
    });
  } catch (error) {
    return res.status(500).json({
      ok: false,
      error: `Failed to write install identity file: ${error}`,
    });
  }
});

app.post('/api/batch/auto-close/run', async (req, res) => {
  if (AUTO_CLOSE_BATCH_API_KEY) {
    const key = String(req.headers['x-auto-close-key'] || '').trim();
    if (key !== AUTO_CLOSE_BATCH_API_KEY) {
      return res.status(401).json({ ok: false, error: 'Unauthorized' });
    }
  }

  try {
    const result = await _runAutoCloseBatchSweep();
    res.json(result);
  } catch (error) {
    res.status(500).json({ ok: false, error: error.toString() });
  }
});

if (AUTO_CLOSE_BATCH_SCHEDULER_ENABLED) {
  setInterval(() => {
    _runAutoCloseBatchSweep().catch(() => {});
  }, Math.max(15, AUTO_CLOSE_BATCH_CHECK_INTERVAL_SEC) * 1000);
  console.log(`[AutoCloseBatch] Scheduler enabled (interval=${AUTO_CLOSE_BATCH_CHECK_INTERVAL_SEC}s)`);
}

app.listen(PORT, () => console.log(`PRegister backend listening on port ${PORT}`));

// If you want to expose the CLIENT_KEY to the demo page via an endpoint (optional):
app.get('/api/client-key', (req, res) => {
  if (!CLIENT_KEY) return res.status(404).json({ error: 'CLIENT_KEY not set' });
  res.json({ apiLoginId: API_LOGIN_ID, clientKey: CLIENT_KEY });
});
