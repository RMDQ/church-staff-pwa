// Check-in rules, decided on the server.
//
// The phone only reports where it is. Whether the time is inside the window,
// whether the phone is close enough to the church and whether the check-in is
// on time are all worked out here, from the server's clock. Nothing the app
// sends about time or status is trusted.
//
// The window, the on-time line, the distance and the church coordinates come
// from the deployment's church config (see checkinConfig in church_config.js).

/// The rules for one deployment, from its check-in configuration.
export function rulesFromConfig(checkin) {
  return {
    serviceId: checkin.serviceId,
    start: checkin.start,
    end: checkin.end,
    onTimeBefore: checkin.onTimeBefore,
    allowedMeters: checkin.allowedMeters,
    church: { lat: checkin.latitude, lng: checkin.longitude },
  };
}

const WEEKDAY_NUMBER = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };

/// The date, weekday (1 = Monday … 7 = Sunday), minutes past midnight and
/// HH:mm of [instant] on the wall clock of [timeZone]. The church's clock, not
/// the server's, decides which day it is.
export function zoneClock(instant, timeZone) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    weekday: 'short',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(instant);
  const part = (type) => parts.find((entry) => entry.type === type).value;
  const hour = Number(part('hour'));
  const minute = Number(part('minute'));
  return {
    dateKey: `${part('year')}-${part('month')}-${part('day')}`,
    weekday: WEEKDAY_NUMBER[part('weekday')],
    minutes: hour * 60 + minute,
    time: `${part('hour')}:${part('minute')}`,
  };
}

export function toMinutes(text) {
  const [hour, minute] = text.split(':').map(Number);
  return hour * 60 + minute;
}

/// Great-circle distance in whole metres.
export function distanceMeters(lat1, lng1, lat2, lng2) {
  const earthRadius = 6371000;
  const toRad = (degrees) => (degrees * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return Math.round(2 * earthRadius * Math.asin(Math.sqrt(a)));
}

/// Decides one check-in. [service] is the entry from church config for the
/// check-in service. Returns { ok: true, dateKey, time, status, distanceMeters }
/// or { ok: false, message, distanceMeters? }. The message is what the member
/// sees, so it says what to do, not what was checked.
export function evaluateCheckin({
  instant,
  timeZone,
  service,
  latitude,
  longitude,
  rules,
}) {
  if (!service || service.enabled !== true) {
    return { ok: false, message: '这个聚会目前没有开放打卡' };
  }

  const clock = zoneClock(instant, timeZone);
  if (clock.weekday !== service.weekday) {
    return { ok: false, message: `打卡只在每周${service.name}开放` };
  }
  if (clock.minutes < toMinutes(rules.start) || clock.minutes > toMinutes(rules.end)) {
    return { ok: false, message: `打卡时间是 ${rules.start}–${rules.end}` };
  }

  const distance = distanceMeters(latitude, longitude, rules.church.lat, rules.church.lng);
  if (distance > rules.allowedMeters) {
    return { ok: false, message: '不在教堂范围内，请到教堂附近再打卡', distanceMeters: distance };
  }

  return {
    ok: true,
    dateKey: clock.dateKey,
    time: clock.time,
    status: clock.minutes < toMinutes(rules.onTimeBefore) ? 'onTime' : 'late',
    distanceMeters: distance,
  };
}
