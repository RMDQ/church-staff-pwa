// POST /api/checkin — record one check-in for the signed-in member.
//
// The app sends only where the phone says it is. The server decides the day,
// the time window, the distance and whether the check-in is on time, using its
// own clock and the church's time zone. One check-in per member per day is
// enforced by the document id, which Firestore refuses to create twice.

import { churchConfig } from '../../worker/church_config.js';
import { bearerToken, emailVerifiedFromIdToken, identifyCaller, HttpError, uidFromIdToken } from '../../worker/firebase_user.js';
import { handleWith, jsonResponse, readJsonBody } from '../../worker/http.js';
import { createDocument, getDocumentOrNull } from '../../worker/firestore_admin.js';
import { evaluateCheckin, rulesFromConfig } from '../../worker/checkin_rules.js';

async function hasPendingSignup(request, env) {
  let uid;
  try {
    uid = uidFromIdToken(bearerToken(request));
  } catch {
    return false;
  }
  const pending = await getDocumentOrNull(env, `signup_requests/${uid}`);
  return pending !== null;
}

const isLatitude = (value) => typeof value === 'number' && Number.isFinite(value) && value >= -90 && value <= 90;
const isLongitude = (value) => typeof value === 'number' && Number.isFinite(value) && value >= -180 && value <= 180;

export const onRequestPost = ({ request, env }) =>
  handleWith('checkin function failed', async () => {
    // Who is calling. identifyCaller also refuses anyone with no users/{uid}
    // document, so a removed member cannot check in with an old token.
    let caller;
    try {
      caller = await identifyCaller(request, env);
    } catch (error) {
      // No users/{uid} document: either a pending sign-up or a removed member.
      // Say which one it is, so a new member is not told they are not allowed.
      if (error instanceof HttpError && error.status === 403 && (await hasPendingSignup(request, env))) {
        throw new HttpError(403, '注册申请正在等待管理员确认，确认后才能打卡');
      }
      throw error;
    }
    // Checked only after identifyCaller: that call has Firestore verify the
    // token, so the email_verified claim read here cannot be a forgery.
    if (!emailVerifiedFromIdToken(caller.token)) {
      throw new HttpError(403, '请先到邮箱点击验证链接，再打卡');
    }

    const body = await readJsonBody(request);
    const latitude = body?.latitude;
    const longitude = body?.longitude;
    if (!isLatitude(latitude) || !isLongitude(longitude)) {
      throw new HttpError(400, '无法取得位置，请打开定位后再试');
    }

    const config = churchConfig(env);
    const rules = rulesFromConfig(config.checkin);
    const service = config.services.find((entry) => entry.id === rules.serviceId);
    const decision = evaluateCheckin({
      instant: new Date(),
      timeZone: config.timeZone,
      service,
      latitude,
      longitude,
      rules,
    });
    if (!decision.ok) {
      throw new HttpError(403, decision.message);
    }

    try {
      await createDocument(env, 'checkins', `${decision.dateKey}_${caller.uid}`, {
        uid: caller.uid,
        name: caller.name || '',
        serviceId: rules.serviceId,
        date: decision.dateKey,
        time: decision.time,
        status: decision.status,
        distanceMeters: decision.distanceMeters,
        latitude,
        longitude,
        createdAt: new Date(),
      });
    } catch (error) {
      if (error instanceof HttpError && error.status === 409) {
        throw new HttpError(409, '今天已经打过卡了');
      }
      throw error;
    }

    return jsonResponse(
      { status: decision.status, time: decision.time, distanceMeters: decision.distanceMeters },
      201,
    );
  });
