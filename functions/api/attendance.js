// GET /api/attendance?date=YYYY-MM-DD — one day's check-ins for the viewer.
//
// Only admins and leaders may call this. Which rows they see is decided by
// worker/attendance_rules.js. The date defaults to today in the church's time zone.

import { churchConfig, dateKeyInZone } from '../../worker/church_config.js';
import { HttpError, identifyCaller } from '../../worker/firebase_user.js';
import { handleWith, jsonResponse } from '../../worker/http.js';
import { listAllDocuments, queryDocumentsEqual } from '../../worker/firestore_admin.js';
import { attendanceFor, attendanceRows } from '../../worker/attendance_rules.js';

const DATE_KEY = /^\d{4}-\d{2}-\d{2}$/;

export const onRequestGet = ({ request, env }) =>
  handleWith('attendance function failed', async () => {
    const caller = await identifyCaller(request, env);
    if (caller.role !== 'admin' && caller.role !== 'leader') {
      throw new HttpError(403, '只有管理员和小组长可以查看出勤');
    }

    const config = churchConfig(env);
    const requested = new URL(request.url).searchParams.get('date');
    const date = requested ?? dateKeyInZone(new Date(), config.timeZone);
    if (!DATE_KEY.test(date)) {
      throw new HttpError(400, '日期格式应为 YYYY-MM-DD');
    }

    const serviceId = config.checkin.serviceId;
    const [records, members] = await Promise.all([
      queryDocumentsEqual(env, 'checkins', 'date', date),
      listAllDocuments(env, 'users'),
    ]);
    const users = new Map(members.map((member) => [member.id, member]));
    const viewer = { ...(users.get(caller.uid) ?? {}), role: caller.role };

    const visible = attendanceFor({ viewer, users, records, serviceId });
    const rows = attendanceRows({ records: visible, users, serviceId });
    const onTime = rows.filter((row) => row.status === 'onTime').length;

    return jsonResponse({
      date,
      records: rows,
      counts: { total: rows.length, onTime, late: rows.length - onTime },
    });
  });
