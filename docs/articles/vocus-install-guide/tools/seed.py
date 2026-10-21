# Seeds the local Firebase emulator with a fake church for screenshots.
import json, urllib.request, secrets, datetime as dt

AUTH = "http://localhost:9199/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key"
FS = "http://localhost:8181/v1/projects/demo-church/databases/(default)/documents/"


def post(url, body, method="POST", owner=False):
    headers = {"Content-Type": "application/json"}
    if owner:
        headers["Authorization"] = "Bearer owner"
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method=method, headers=headers)
    return json.loads(urllib.request.urlopen(req).read())


def val(v):
    if isinstance(v, bool):
        return {"booleanValue": v}
    if isinstance(v, str):
        return {"stringValue": v}
    if isinstance(v, int):
        return {"integerValue": str(v)}
    if isinstance(v, dt.datetime):
        return {"timestampValue": v.strftime("%Y-%m-%dT%H:%M:%SZ")}
    if isinstance(v, list):
        return {"arrayValue": {"values": [val(x) for x in v]}}
    if isinstance(v, dict):
        return {"mapValue": {"fields": {k: val(x) for k, x in v.items()}}}
    raise TypeError(v)


def put(path, data):
    post(FS + path, {"fields": {k: val(v) for k, v in data.items()}}, method="PATCH", owner=True)


pw = secrets.token_urlsafe(12)
open("staff-pass", "w").write(pw)
people = {}
for name, email, role, zones in [
    ("王大卫", "admin@example.test", "admin", ["sundayService", "youth"]),
    ("陈美恩", "meien@example.test", "member", ["sundayService", "youth"]),
    ("林以诺", "enoch@example.test", "member", ["sundayService"]),
    ("张恩惠", "grace@example.test", "member", ["youth"]),
]:
    uid = post(AUTH, {"email": email, "password": pw, "returnSecureToken": True})["localId"]
    people[name] = uid
    put("users/" + uid, {
        "id": uid, "name": name, "email": email, "username": "", "role": role,
        "zones": [{"serviceType": z, "smallGroups": [], "ministries": []} for z in zones],
        "zoneTypes": zones, "groups": [],
    })

put("settings/roster_templates", {"sundayService": ["领会", "司琴", "读经", "招待"], "youth": ["领会", "司琴", "音控"], "children": ["老师"]})


def roster(day, type_, service_name, duties):
    date = dt.date.fromisoformat(day)
    put("rosters/" + date.strftime("%Y%m%d") + "_" + type_, {
        "date": dt.datetime(date.year, date.month, date.day) - dt.timedelta(hours=8),
        "dateKey": day, "type": type_, "serviceName": service_name,
        "specialEvents": [], "customEventColors": {},
        "duties": [{"role": r, "people": ps, "personIdsByName": {p: people[p] for p in ps}} for r, ps in duties],
    })


for day, duties in [
    ("2026-10-04", [("领会", ["王大卫"]), ("司琴", ["陈美恩"]), ("读经", ["林以诺"]), ("招待", ["张恩惠"])]),
    ("2026-10-11", [("领会", ["林以诺"]), ("司琴", ["王大卫"]), ("读经", ["张恩惠"]), ("招待", ["陈美恩"])]),
    ("2026-10-18", [("领会", ["王大卫"]), ("司琴", ["张恩惠"]), ("读经", ["陈美恩"]), ("招待", ["林以诺"])]),
    ("2026-10-25", [("领会", ["陈美恩"]), ("司琴", ["王大卫"]), ("读经", ["林以诺"]), ("招待", ["张恩惠"])]),
    ("2026-11-01", [("领会", ["林以诺"]), ("司琴", ["陈美恩"]), ("读经", ["王大卫"]), ("招待", ["陈美恩"])]),
]:
    roster(day, "sundayService", "主日崇拜", duties)
for day, duties in [
    ("2026-10-10", [("领会", ["张恩惠"]), ("司琴", ["陈美恩"]), ("音控", ["王大卫"])]),
    ("2026-10-24", [("领会", ["陈美恩"]), ("司琴", ["张恩惠"]), ("音控", ["王大卫"])]),
]:
    roster(day, "youth", "青年崇拜", duties)
print("seeded", len(people), "users")
