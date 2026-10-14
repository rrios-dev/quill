# Meeting analysis

## 1. Billing database migration (PostgreSQL 14 → 17)

**Context from Lucía:** the migration is ready in the test environment. She has rehearsed the full dump twice and it takes about three and a half hours. Billing can't be down that long during working hours.

**Options on the table**

| Option | Argued by | Argument |
|---|---|---|
| A. Full dump on Saturday 18 October at night | Lucía (proposal), with Marta's support on the window | Avoids another week of work. Neither rehearsal failed. Marta: on a Saturday night there are hardly any manual invoices, so the impact on customers would be minimal if something goes down. |
| B. Logical replication before migrating | Andrés | Would cut the real downtime to fifteen or twenty minutes. Above all, if the dump goes wrong there is no room to roll back before Monday. |

**Lucía's objection to B:** about forty tables without a primary key in the old invoices schema would need reviewing, which means another week of work.

**Decision (proposed by Roberto, accepted by everyone):** full dump on Saturday 18 October from ten at night. In parallel, Andrés prepares logical replication as a fallback for the next window if Saturday fails.

**Final position:** Andrés accepted, but put on record that he still thinks replication is safer. Lucía agreed.

**Commitments**
- Lucía: the migration runbook, shared on Wednesday 15.
- Andrés: logical replication tested by Friday 24 October, including the forty tables without a primary key.

## 2. The payment provider's delay

**Situation (Marta):** the new refunds API was promised for 1 October and hasn't arrived. The provider now says 3 November, with nothing in writing. Meanwhile, support does about sixty refunds a week by hand.

| Option | Argued by | Argument |
|---|---|---|
| Automate on the old API | Lucía (asked as a question) | Would ease the manual load. |
| Leave the old API alone | Marta, Andrés | Marta: it is retired on 30 November. Andrés: it doesn't return the original transaction ID, and reconciliation would be "a nightmare". |

**Decision (Roberto):** the old API is left alone. Lucía didn't insist.

**Open risk:** if the API doesn't arrive and the November campaign doubles refunds, support would be one person short. To be reviewed at the 3 November meeting.
