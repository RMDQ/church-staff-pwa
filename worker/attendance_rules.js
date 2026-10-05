// Which check-ins a viewer may see on the attendance screen.
//
// Admin sees everyone. A leader sees people who share a small group with them
// in the same service. Anyone else sees nothing. This is decided here, on the
// server, because the check-in records are read with the service account, which
// bypasses firestore.rules.

/// The zone entry (serviceType, smallGroups, ministries) for [serviceId], or null.
export function zoneFor(user, serviceId) {
  const zones = Array.isArray(user?.zones) ? user.zones : [];
  return zones.find((zone) => zone?.serviceType === serviceId) ?? null;
}

/// [records] the viewer may see. [users] is a Map from uid to the decoded user.
export function attendanceFor({ viewer, users, records, serviceId }) {
  const inService = records.filter((record) => record.serviceId === serviceId);
  if (viewer?.role === 'admin') return inService;
  if (viewer?.role !== 'leader') return [];

  const mine = zoneFor(viewer, serviceId)?.smallGroups ?? [];
  if (mine.length === 0) return [];

  return inService.filter((record) => {
    const theirs = zoneFor(users.get(record.uid), serviceId);
    return Boolean(theirs) && theirs.smallGroups.some((group) => mine.includes(group));
  });
}

/// The rows the screen shows: name, small group and the time as the server wrote it.
export function attendanceRows({ records, users, serviceId }) {
  return records
    .filter((record) => record.serviceId === serviceId)
    .map((record) => {
      const zone = zoneFor(users.get(record.uid), serviceId);
      return {
        name: typeof record.name === 'string' && record.name !== '' ? record.name : '（未知）',
        smallGroups: zone?.smallGroups ?? [],
        time: typeof record.time === 'string' ? record.time : '',
        status: record.status === 'onTime' ? 'onTime' : 'late',
        distanceMeters: typeof record.distanceMeters === 'number' ? record.distanceMeters : null,
      };
    })
    .sort((a, b) => a.time.localeCompare(b.time));
}
