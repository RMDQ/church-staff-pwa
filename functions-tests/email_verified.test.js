import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { emailVerifiedFromIdToken } from '../worker/firebase_user.js';

/// A token-shaped string with the given payload. The signature is not checked
/// by emailVerifiedFromIdToken (identifyCaller has Firestore do that), so an
/// empty signature is enough here.
function fakeToken(payload) {
  const encode = (value) =>
    Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({ alg: 'RS256' })}.${encode(payload)}.signature`;
}

describe('emailVerifiedFromIdToken', () => {
  test('true only when the claim is exactly true', () => {
    assert.equal(emailVerifiedFromIdToken(fakeToken({ sub: 'u1', email_verified: true })), true);
  });

  test('false when the claim is false, missing, or a string', () => {
    assert.equal(emailVerifiedFromIdToken(fakeToken({ sub: 'u1', email_verified: false })), false);
    assert.equal(emailVerifiedFromIdToken(fakeToken({ sub: 'u1' })), false);
    assert.equal(emailVerifiedFromIdToken(fakeToken({ sub: 'u1', email_verified: 'true' })), false);
  });

  test('false for something that is not a token at all', () => {
    assert.equal(emailVerifiedFromIdToken('not-a-token'), false);
    assert.equal(emailVerifiedFromIdToken('a.b.c'), false);
  });
});
