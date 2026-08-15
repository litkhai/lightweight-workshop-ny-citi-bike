# Instructor guide

Notes for delivering this to a room rather than working through it alone.

## Timing

| Module | Solo | In a room | Why the difference |
|---|---|---|---|
| 00 Prerequisites | 10 min | 15 min | Docker Desktop not installed on at least one laptop |
| 01 Provision | 20 min | **40 min** | Account creation, region choice, IP allow-lists |
| 02 Postgres and the schema | 10 min | 15 min | |
| 03 The feed | 20 min | **30 min** | The RMV needs a minute before anything moves, and the lag confuses people |
| 04 Spatial | 15 min | 20 min | Good discussion happens here; let it |
| 05 ClickPipes | 20 min | **35 min** | Second allow-list surprise, and it blocks everything after |
| 06 Pushdown | 25 min | 30 min | |
| 07 Dashboard | 15 min | 15 min | |
| 08 Wrap-up | 10 min | 15 min | Do the teardown *with* them, not as homework |

Budget **3½ hours** for a room, not two. The two console modules are where most
of it goes.

## Do this before the session

**Send prerequisites a day early.** Docker installed, ClickHouse Cloud account
created, repository cloned. Every minute spent on account signup is a minute
not spent on the actual content.

**Run the whole thing yourself the day before.** Not the week before — the
console changes, and the feed is a live third-party dependency.

**Check the feed on the morning of.** `./scripts/preflight.sh`. If Citi Bike is
down, point the two `url()` calls in `clickhouse/01-ingest-rmv.sql` at Capital
Bikeshare and mention it; nothing else changes.

**Have your own services already provisioned.** When somebody's pipe will not
connect, you need a working one to demo from rather than debugging in front of
everyone.

## The two places it goes wrong

**IP allow-lists, twice.** In module 01 they add their laptop's IP. In module
05 the pipe connects from ClickHouse Cloud's network, and their laptop's IP
does nothing for it. People assume they already did this step. Call it out
explicitly both times.

**The two-minute lag in module 03 reads as a broken pipeline.** It is the sum of
the two schedules — up to a minute for the refreshable MV, up to another for
pg_cron. Someone will run `02-verify.sql` fifteen seconds after finishing the
module, see nothing, and start debugging. Tell them to wait three minutes before
concluding anything.

**Replicating only the big table.** It is the intuitive optimisation — why
copy 2,500 rows? — and it silently breaks the pushdown two modules later. If
someone reaches module 06 and only ever gets `dragged`, this is why. Consider
letting one person make the mistake deliberately; the counter-example teaches
better than the warning does.

## Use the dashboard as the teaching surface

Two tabs in module 07 are worth more than the module's own page suggests.

**Checks** is the fastest way to unblock a room. Instead of debugging one
laptop's psql output on a projector, have everyone open `#checks` and read out
which line is red — it names the file to re-run. It also gives you a way to see
who is behind without asking.

**Lab** is where to spend any time you have left. Have the room run exercises 5
and 6 back to back: same query shape, one changed `ORDER BY`, and a `Sort` node
appears in the plan tree. That pair makes the argument for moving analytical
work far better than any timing does at workshop data volumes, and it is honest
in a way "ClickHouse is faster" is not. Then exercise 3, which breaks the
pushdown on purpose — the verdict flipping while nothing errors is the moment
people remember.

## Discussion prompts that work

**After module 04:** "What would you have to give up to put all of this in one
engine?" Gets at the actual trade-off rather than a feature comparison.

**After module 03:** "Whose job is it to fetch a feed?" The workshop's answer —
whichever engine actually can — usually starts an argument about where ingestion
belongs, which is the useful conversation.

**After module 06, showing the failed pushdown:** "How would you have caught
this in production?" The answer — you would not, unless you were reading plans
— is the most valuable thing in the workshop.

**After module 07:** "This dashboard exists because a number cannot tell you
where it came from. What else in your stack has that problem?"

## Small groups and shared services

If accounts are a problem, one shared pair of services works. Give everyone
read-only Postgres credentials, run the ingestion once on your own pair, and
have participants do modules 04–07 read-only. They lose the schema creation, the
feed setup and the ClickPipe, which are the three most valuable console skills —
so prefer individual accounts if you can.

## Common questions

**"Why not just use ClickHouse for everything?"** Show them
`ST_VoronoiPolygons` and ask how they would write it. Then note that this is
one of about three hundred functions.

**"Why not just use Postgres for everything?"** Resist the cheap answer here.
Module 06 shows Postgres handling the window function *well*, because the
module-02 index covers exactly that ordering. The real answer is the one that
survives scrutiny: you can index for one access path, not for all of them, and
the second and third analytical question you ask will not be covered. Leave the
job running overnight and demonstrate that with a second window over a
different key.

**"Is the pushdown always this good?"** No, and module 06 says so about window
functions specifically. The honest framing: pushdown works well for the shape
this workload has — filter, group, aggregate — and you should verify per query
rather than assume.

**"Could we do this with MySQL / StarRocks / Doris?"** Partly. Anything
speaking the MySQL wire protocol can be reached from Postgres through
`mysql_fdw`, which has had aggregate pushdown since 2.7.0. What does not exist
elsewhere is a vendor-built Postgres extension for exactly this pattern.

## Teardown is part of the session

Do not send people away with two running services and good intentions. Walk
through [module 08](08-wrap-up.md) together, and specifically check
`pg_replication_slots` after the pipe is deleted. An orphaned slot found weeks
later is a bad memory of your workshop.
