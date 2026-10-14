## Decisions

- PostgreSQL 14 to 17 migration: full dump on Saturday 18 October from 22:00.
- Andrés prepares logical replication as a fallback for the next window if Saturday fails.
- Nothing is automated on the payment provider's old refunds API.
- Mobile app launch: iOS on 10 November and Android on 17 November.
- Expanding the test environment's disk volume is approved; Lucía does it directly, without waiting for the meeting.

## Tasks

| Owner | Task | Date |
|---|---|---|
| Lucía | Share the migration runbook | Wednesday 15 October |
| Andrés | Have logical replication tested in the test environment (including the forty tables without a primary key) | Friday 24 October |
| Marta | Ask the payment provider for the 3 November date in writing | today (the day of the meeting) |
| Marta | If the provider hasn't confirmed by 20 October, escalate to their account manager | 20 October |
| Marta | Prepare a message for Android users explaining their version arrives a week later | 7 November |
| Diego | Submit the iOS version to Apple's review | Monday 27 October |
| Lucía | Expand the test environment's disk volume | no date |

## Risks and open questions

- Full dump: it may fail halfway; production data is 30 % larger than test data, and neither rehearsal failed. If it fails there is no room to roll back before Monday (Andrés), when recurring billing comes in (Marta).
- Refunds API: the new one was due on 1 October; the new date, 3 November, is not in writing. The old one is retired on 30 November.
- Support does about sixty manual refunds a week. If the API doesn't arrive and the November campaign doubles refunds, support would be one person short. To be reviewed at the 3 November meeting.
- Android: a week behind because of the notifications SDK on Android 15. Diego says 10 November was possible but "very tight".
- Apple's iOS review: risk of rejection; that's why it is submitted on 27 October, to leave room.
- Test environment: running out of space in about two weeks (solved by the approved expansion).

## Disagreements

- **Migration:** Andrés still thinks logical replication (15–20 minutes of downtime) is safer than the full dump, although he accepted the decision.
- **App launch:** Marta preferred launching iOS and Android at once, to avoid questions from Android users. Diego and Andrés argued for launching separately so as not to miss the iOS campaign window. They launch separately; Marta agreed to prepare the message.
