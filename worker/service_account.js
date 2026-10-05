// Access tokens for the church's Google service account, for any Google API
// scope. Used by routes that must write to Firestore on the server's authority.
//
// google_calendar.js has its own copy of this signing flow for the calendar
// scope. It is not shared yet so that the calendar path stays untouched; the
// two should be merged once check-in has shipped.

import { HttpError, requireEnv } from './firebase_user.js';

const TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token';
const UPSTREAM_TIMEOUT_MS = 10000;

/// Tokens by scope. Cached in the isolate: minting costs an RSA signature and a
/// round trip, and a token lasts an hour. The 60s margin covers a token that
/// expires mid-flight.
const cache = new Map();

export function resetServiceAccessTokenCache() {
  cache.clear();
}

function bytesToBase64Url(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function textToBase64Url(text) {
  return bytesToBase64Url(new TextEncoder().encode(text));
}

async function importPrivateKey(pem) {
  const body = pem
    .replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');
  let der;
  try {
    der = Uint8Array.from(atob(body), (char) => char.charCodeAt(0));
  } catch {
    throw new HttpError(500, '伺服器設定不完整，請聯絡管理員');
  }
  return crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}

function serviceAccount(env) {
  const raw = requireEnv(env, 'GOOGLE_SERVICE_ACCOUNT_JSON');
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // Never log the value itself: it contains a private key.
    console.error('GOOGLE_SERVICE_ACCOUNT_JSON is not valid JSON');
    throw new HttpError(500, '伺服器設定不完整，請聯絡管理員');
  }
  if (!parsed?.client_email || !parsed?.private_key) {
    console.error('GOOGLE_SERVICE_ACCOUNT_JSON is missing client_email/private_key');
    throw new HttpError(500, '伺服器設定不完整，請聯絡管理員');
  }
  return parsed;
}

async function fetchWithTimeout(fetchImpl, url, init = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
  try {
    return await fetchImpl(url, { ...init, signal: controller.signal });
  } catch (error) {
    console.error('service account token request failed', error?.name);
    throw new HttpError(502, '無法連上 Google 服務，請稍後再試');
  } finally {
    clearTimeout(timer);
  }
}

/// An access token for [scope], signed as the church's service account.
export async function getServiceAccessToken(env, scope, fetchImpl = fetch, now = Date.now()) {
  const cached = cache.get(scope);
  if (cached && cached.expiresAt > now + 60000) return cached.token;

  const account = serviceAccount(env);
  const issuedAt = Math.floor(now / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: account.client_email,
    scope,
    aud: TOKEN_ENDPOINT,
    iat: issuedAt,
    exp: issuedAt + 3600,
  };
  const unsigned = `${textToBase64Url(JSON.stringify(header))}.${textToBase64Url(JSON.stringify(claims))}`;
  // A literal \n in the key survives JSON.parse as a real newline, but a value
  // pasted through a dashboard field may keep the two characters: normalise.
  const key = await importPrivateKey(account.private_key.replace(/\\n/g, '\n'));
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));
  const assertion = `${unsigned}.${bytesToBase64Url(new Uint8Array(signature))}`;

  const response = await fetchWithTimeout(fetchImpl, TOKEN_ENDPOINT, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }).toString(),
  });
  if (!response.ok) {
    console.error('service account token exchange failed', response.status);
    throw new HttpError(502, '無法連上 Google 服務，請稍後再試');
  }
  const data = await response.json();
  if (typeof data?.access_token !== 'string') {
    throw new HttpError(502, '無法連上 Google 服務，請稍後再試');
  }
  const lifetimeMs = typeof data.expires_in === 'number' ? data.expires_in * 1000 : 3600000;
  cache.set(scope, { token: data.access_token, expiresAt: now + lifetimeMs });
  return data.access_token;
}
