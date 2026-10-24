"""
Write the owner's reviewed labels onto the August 2026 alert events that are in anomaly_logs.

    python backfill_owner_labels.py owner_labels.csv            # dry run: shows the matching, writes nothing
    python backfill_owner_labels.py owner_labels.csv --apply    # writes, in one transaction

The form lists 54 events (August readings scored with the current model); anomaly_logs holds only the
alerts the live system actually logged in August. Each logged event is matched to the form event whose
time span overlaps it (form span = start .. start + (n_readings - 1) x 5 min). Form events with no
logged event are reported and skipped: there is no alert row to label.

Per matched event (all its rows):
    normal  -> acknowledged = FALSE      anomaly -> acknowledged = TRUE      blank/unsure -> NULL
    reviewed_at  = the time this script runs (the real review date, not August)
    label_source = 'owner_review_form'   (new column; in-app answers keep NULL)
Nothing is written if a logged event matches no form event or more than one. Events already answered
in the app are kept as they are.
"""
import os
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

import pandas as pd
import psycopg2

LABEL = {"normal": False, "anomaly": True, "unsure": None, "": None}
SLACK = pd.Timedelta(minutes=1)


def _has_col(cur):
    cur.execute("""SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'anomaly_logs' AND column_name = 'label_source'""")
    return cur.fetchone() is not None


def main(path, apply):
    lab = pd.read_csv(path, dtype={"owner_label": str})
    lab["owner_label"] = lab["owner_label"].fillna("").str.strip().str.lower()
    bad = sorted(set(lab.owner_label) - set(LABEL))
    if bad:
        sys.exit(f"Unknown labels {bad}; use normal / anomaly / unsure. Nothing written.")
    lab["start"] = pd.to_datetime(lab["start"])
    lab["end"] = lab["start"] + pd.to_timedelta((lab["n_readings"] - 1) * 5, unit="min")

    conn = psycopg2.connect(dbname="energy_db", user="energy_user", password=os.environ["GRID_DB_PASSWORD"],
                            host="localhost", port=5432)
    with conn, conn.cursor() as cur:
        answered = ("reviewed_at IS NOT NULL AND label_source IS NULL" if _has_col(cur)
                    else "reviewed_at IS NOT NULL")
        cur.execute(f"""SELECT event_id, MIN(timestamp), MAX(timestamp), COUNT(*), BOOL_OR({answered})
                        FROM anomaly_logs
                        WHERE timestamp >= '2026-08-01' AND timestamp < '2026-09-01' AND event_id IS NOT NULL
                        GROUP BY event_id ORDER BY 2""")
        db = pd.DataFrame(cur.fetchall(), columns=["db_event_id", "db_start", "db_end", "db_readings", "answered_in_app"])
    db["db_start"], db["db_end"] = pd.to_datetime(db["db_start"]), pd.to_datetime(db["db_end"])

    rows, problems = [], []
    for r in db.itertuples():
        hit = lab[(lab.start - SLACK <= r.db_end) & (lab.end + SLACK >= r.db_start)]
        if len(hit) != 1:
            problems.append((r.db_event_id, r.db_start, len(hit)))
            continue
        h = hit.iloc[0]
        rows.append({"db_event_id": int(r.db_event_id), "db_start": r.db_start, "db_readings": int(r.db_readings),
                     "form_event": int(h.event_id), "form_start": h.start, "form_readings": int(h.n_readings),
                     "owner_label": h.owner_label or "unsure", "answered_in_app": bool(r.answered_in_app)})
    m = pd.DataFrame(rows)
    print(f"{len(db)} August events in anomaly_logs, {len(m)} matched to the form "
          f"({len(lab)} events in the form; {len(lab) - len(m)} have no logged alert and are skipped)\n")
    if len(m):
        print(m.drop(columns="answered_in_app").to_string(index=False))
    if problems:
        print("\nLogged events with no single matching form event:")
        for p in problems:
            print(f"  event {p[0]} at {p[1]}: {p[2]} matches")
        sys.exit("Nothing written.")
    todo = m[~m.answered_in_app]
    if len(m) - len(todo):
        print(f"\n{len(m) - len(todo)} events were already answered in the app and are kept as they are.")
    print("\nTo write:", todo.owner_label.value_counts().to_dict())

    if not apply:
        print("\nDry run only. Re-run with --apply to write.")
        return
    now = datetime.now(ZoneInfo("Asia/Manila")).replace(tzinfo=None)
    with conn, conn.cursor() as cur:
        cur.execute("ALTER TABLE anomaly_logs ADD COLUMN IF NOT EXISTS label_source TEXT")
        for r in todo.itertuples():
            cur.execute("""UPDATE anomaly_logs SET acknowledged = %s, reviewed_at = %s,
                                  label_source = 'owner_review_form'
                           WHERE event_id = %s""", (LABEL[r.owner_label], now, r.db_event_id))
    print(f"\nWritten: {len(todo)} events, reviewed_at = {now:%Y-%m-%d %H:%M}, label_source = 'owner_review_form'.")
    conn.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1], "--apply" in sys.argv)
