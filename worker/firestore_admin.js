// Creates Firestore documents as the church's service account, which bypasses
// firestore.rules. Only routes that have already decided the write is allowed
// may call this; the rules still deny every direct write from the app.

import { HttpError, requireEnv } from './firebase_user.js';
import { getServiceAccessToken } from './service_account.js';

const FIRESTORE_API = 'https://firestore.googleapis.com/v1';
const FIRESTORE_SCOPE = 'https://www.googleapis.com/auth/datastore';
const DOCUMENT_ID = /^[A-Za-z0-9_-]{1,128}$/;
const UPSTREAM_TIMEOUT_MS = 10000;

/// Firestore's typed JSON encoding for the field types the app stores.
export function encodeFields(data) {
  const fields = {};
  for (const [key, value] of Object.entries(data)) {
    fields[key] = encodeValue(value, key);
  }
  return fields;
}

export function encodeValue(value, key) {
  if (value === null) return { nullValue: null };
  if (typeof value === 'string') return { stringValue: value };
  if (typeof value === 'boolean') return { booleanValue: value };
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new TypeError(`${key} must be finite`);
    // Integers are sent as integerValue so Firestore keeps them integers.
    return Number.isInteger(value) ? { integerValue: String(value) } : { doubleValue: value };
  }
  if (value instanceof Date) return { timestampValue: value.toISOString() };
  throw new TypeError(`${key} has a type Firestore cannot store here`);
}

/// Creates `collection/docId`. Throws HttpError(409) if the document already
/// exists, so a second write for the same key is refused by Firestore itself
/// rather than by a read-then-write race in the worker.
export async function createDocument(env, collection, docId, data, fetchImpl = fetch) {
  if (!DOCUMENT_ID.test(docId)) throw new TypeError('document id is not safe for a path');
  const projectId = requireEnv(env, 'FIREBASE_PROJECT_ID');
  const token = await getServiceAccessToken(env, FIRESTORE_SCOPE, fetchImpl);
  const url =
    `${FIRESTORE_API}/projects/${encodeURIComponent(projectId)}` +
    `/databases/(default)/documents/${collection}` +
    `?documentId=${encodeURIComponent(docId)}`;

  let response;
  try {
    response = await fetchImpl(url, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ fields: encodeFields(data) }),
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch (error) {
    console.error('firestore create request failed', error?.name);
    throw new HttpError(502, '暂时无法写入打卡记录，请稍后再试');
  }

  if (response.status === 409) {
    throw new HttpError(409, '这个记录已经存在');
  }
  if (!response.ok) {
    console.error('firestore create failed', collection, response.status);
    throw new HttpError(502, '暂时无法写入打卡记录，请稍后再试');
  }
}

/// Turns one Firestore typed value back into plain JavaScript. Only the types
/// this app stores are handled; anything else reads as null rather than throwing,
/// so one odd document cannot break a whole list.
export function decodeValue(value) {
  if (!value || typeof value !== 'object') return null;
  if ('stringValue' in value) return value.stringValue;
  if ('integerValue' in value) return Number(value.integerValue);
  if ('doubleValue' in value) return value.doubleValue;
  if ('booleanValue' in value) return value.booleanValue;
  if ('timestampValue' in value) return value.timestampValue;
  if ('nullValue' in value) return null;
  if ('arrayValue' in value) return (value.arrayValue.values ?? []).map(decodeValue);
  if ('mapValue' in value) return decodeFields(value.mapValue.fields ?? {});
  return null;
}

export function decodeFields(fields) {
  const out = {};
  for (const [key, value] of Object.entries(fields ?? {})) out[key] = decodeValue(value);
  return out;
}

/// Every document in [collection] whose [field] equals [value], as plain objects
/// with their id. Used by the attendance route for one day's check-ins.
export async function queryDocumentsEqual(env, collection, field, value, fetchImpl = fetch) {
  const projectId = requireEnv(env, 'FIREBASE_PROJECT_ID');
  const token = await getServiceAccessToken(env, FIRESTORE_SCOPE, fetchImpl);
  const url = `${FIRESTORE_API}/projects/${encodeURIComponent(projectId)}/databases/(default)/documents:runQuery`;
  const response = await readFirestore(fetchImpl, url, token, {
    structuredQuery: {
      from: [{ collectionId: collection }],
      where: {
        fieldFilter: {
          field: { fieldPath: field },
          op: 'EQUAL',
          value: encodeValue(value, field),
        },
      },
    },
  });
  return response
    .filter((row) => row.document)
    .map((row) => ({ id: row.document.name.split('/').pop(), ...decodeFields(row.document.fields) }));
}

/// Every document in [collection], following the page tokens. Church membership
/// is a few hundred documents, so reading the whole collection is fine here.
export async function listAllDocuments(env, collection, fetchImpl = fetch) {
  const projectId = requireEnv(env, 'FIREBASE_PROJECT_ID');
  const token = await getServiceAccessToken(env, FIRESTORE_SCOPE, fetchImpl);
  const base = `${FIRESTORE_API}/projects/${encodeURIComponent(projectId)}/databases/(default)/documents/${collection}`;
  const documents = [];
  let pageToken = '';
  do {
    const url = `${base}?pageSize=300${pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : ''}`;
    const response = await readFirestore(fetchImpl, url, token, null);
    for (const doc of response.documents ?? []) {
      documents.push({ id: doc.name.split('/').pop(), ...decodeFields(doc.fields) });
    }
    pageToken = response.nextPageToken ?? '';
  } while (pageToken);
  return documents;
}

async function readFirestore(fetchImpl, url, token, body) {
  let response;
  try {
    response = await fetchImpl(url, {
      method: body ? 'POST' : 'GET',
      headers: {
        authorization: `Bearer ${token}`,
        ...(body ? { 'content-type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch (error) {
    console.error('firestore read request failed', error?.name);
    throw new HttpError(502, '暂时无法读取资料，请稍后再试');
  }
  if (!response.ok) {
    console.error('firestore read failed', response.status);
    throw new HttpError(502, '暂时无法读取资料，请稍后再试');
  }
  return response.json();
}

/// One document as plain fields, or null when it does not exist. Read with the
/// service account, so only use it where the route has already decided the read
/// is needed (for example, to explain a refusal).
export async function getDocumentOrNull(env, path, fetchImpl = fetch) {
  const projectId = requireEnv(env, 'FIREBASE_PROJECT_ID');
  const token = await getServiceAccessToken(env, FIRESTORE_SCOPE, fetchImpl);
  const url = `${FIRESTORE_API}/projects/${encodeURIComponent(projectId)}/databases/(default)/documents/${path}`;
  let response;
  try {
    response = await fetchImpl(url, {
      headers: { authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch (error) {
    console.error('firestore get request failed', error?.name);
    throw new HttpError(502, '暂时无法读取资料，请稍后再试');
  }
  if (response.status === 404) return null;
  if (!response.ok) {
    console.error('firestore get failed', response.status);
    throw new HttpError(502, '暂时无法读取资料，请稍后再试');
  }
  const doc = await response.json();
  return { id: path.split('/').pop(), ...decodeFields(doc.fields) };
}
