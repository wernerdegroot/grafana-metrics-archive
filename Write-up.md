# History of this script

## 1. Create a directory

```sh
mkdir grafana-metrics-archive
cd grafana-metrics-archive

mkdir -p data
```

Eventually, we'll have

```
grafana-metrics-archive/
├── .env
├── Dockerfile
├── compose.yaml
├── archive.sh
└── data/
    ├── state/
    └── tsdb/
```

Don't create the files yet except as we reach them.

---

## 2. Get the Grafana Cloud values

Go to our Grafana Cloud stack. Found ours at https://grafana.com/orgs/donorteam.

Find the Prometheus card and click **Details** on that card.

Locate the **Remote Write Endpoint**. Our Remote Write Endpoint will look roughly like:

```
https://prometheus-prod-XX-prod-eu-west-X.grafana.net/api/prom/push
```

From that we want the host portion:

```
https://prometheus-prod-XX-prod-eu-west-2.grafana.net
```

Grafana documents that Mimir-specific endpoints can be derived from the remote-write endpoint by removing `/api/prom/push` and adding `/prometheus`. See [Grafana Labs](https://grafana.com/docs/grafana-cloud/send-data/metrics/metrics-prometheus/query-http-api/).

Our Remote Read endpoint is:

```
https://prometheus-prod-24-prod-eu-west-2.grafana.net/prometheus/api/v1/read
```

Mimir itself exposes Remote Read at the Prometheus API's `/api/v1/read` endpoint. See [Grafana Labs](https://grafana.com/docs/mimir/latest/manage/tools/mimirtool/).

---

## 3. Create a read-only token

Go to our Grafana Cloud stack. Found ours at https://grafana.com/orgs/donorteam.

In the left menu, go to **Access Policies** (under **SECURITY**).

Click **New access policy**.

Give it a name such as `local-metrics-archive`.

Under **Scopes**, enable **Read** for **Metrics** only. This corresponds to `metrics:read`. You don't need `metrics:write`, logs, traces, etc. See [Grafana Labs](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/kubernetes-monitoring/configuration/control-access/).

Create the policy.

On the resulting policy, click **Add token**.

Give the token a name such as `local-metrics-archive-token`.

Create it and **copy the token immediately**; you'll use it as environment variable `MIMIR_API_KEY`. The token is the password, while our Metrics instance ID is the username. See [Grafana Labs](https://grafana.com/docs/grafana-cloud/security-and-account-management/authentication-and-permissions/access-policies/using-an-access-policy-token/).

---

## 4. Find Username / Instance ID

Go to our Grafana Cloud stack again. 

Find the Prometheus card and click **Details** on that card.

Look for **Username / Instance ID** (sometimes shown simply as **User**).

---

## 5. Create `.env`-file

Create:

```sh
touch .env
chmod 600 .env
````

Put this in it:

```dotenv
MIMIR_ADDRESS=https://prometheus-prod-XX-prod-eu-west-2.grafana.net
MIMIR_TENANT_ID=...
MIMIR_API_KEY=...

SELECTOR={__name__=~".+"}

# Config
LAG_SECONDS=600 # 10 minutes
INITIAL_LOOKBACK_SECONDS=1123200 # 13 days
WINDOW_SECONDS=21600 # 6 hours
```

Replace:

```
MIMIR_ADDRESS
MIMIR_TENANT_ID
MIMIR_API_KEY
```

with our actual values.

> [!note] Note
> `1123200` seconds is 13 days. Our Grafana Cloud retention is two weeks, so starting 13 days back gives us a little safety margin rather than trying to hit the retention boundary exactly.

> [!note] Note
> I've deliberately used `MIMIR_TENANT_ID` here. Remote-read historically uses the tenant ID as its Basic Auth username rather than the general `MIMIR_API_USER`; a Grafana maintainer specifically documented that behavior for `mimirtool remote-read`. See [GitHub](https://github.com/grafana/mimir/discussions/11435). For Grafana Cloud, that tenant ID is our Metrics instance ID anyway, so it fits perfectly.

> [!danger] Danger
> Do **not** commit `.env`.
>
> Add:
> 
> ```
> echo '.env' > .gitignore
> echo 'data/' >> .gitignore
> ```

---

## First test: can you query Grafana Cloud at all?
Before touching Remote Read, test ordinary Prometheus querying.

You can use the query endpoint you copied from Grafana Cloud:

```sh
export QUERY_URL="$MIMIR_ADDRESS"
export LOGIN="$MIMIR_TENANT_ID:$MIMIR_API_KEY"

curl -sS \
  -u "$LOGIN" \
  --data-urlencode 'query=count({__name__=~".+"})' \
  "$QUERY_URL/api/v1/query" \
| jq
```

Grafana documents exactly this query-endpoint + Basic-Auth pattern for the Prometheus HTTP API. [Grafana Labs](https://grafana.com/docs/grafana-cloud/send-data/metrics/metrics-prometheus/query-http-api/)

You should get JSON beginning roughly:

```json
{
  "status": "success",
  "data": {
    ...
  }
}
```

A successful query proves:

```
token          ✓
instance ID    ✓
metrics:read   ✓
Grafana data   ✓
```

It doesn't prove Remote Read yet.

---

## 7. Test `mimirtool`

There is an official `grafana/mimirtool` Docker image; Grafana's project publishes and uses it alongside Mimir releases. [GitHub](https://github.com/grafana/mimir/blob/main/RELEASE.md)

Run:

```sh
docker run --rm \
  grafana/mimirtool:3.1.4 \
  --help
```

If that prints the `mimirtool` help and lists commands including `remote-read`, the container itself is working.

Then check the command we're actually interested in:

You should see subcommands. Something along the lines of:

```
usage: mimirtool remote-read <command> [<args> ...]

Inspect stored series in Grafana Mimir using the remote read API.


Flags:
  --[no-]help                 Show context-sensitive help (also try --help-long
                              and --help-man).
  --log.level="info"          set level of the logger
  --push-gateway.endpoint=PUSH-GATEWAY.ENDPOINT  
                              url for the push-gateway to register metrics
  --push-gateway.job=PUSH-GATEWAY.JOB  
                              job name to register metrics
  --push-gateway.interval=1m  interval to forward metrics to the push gateway

Subcommands:
remote-read export --address=ADDRESS [<flags>]
    Export metrics remote read series into a local TSDB.

remote-read dump --address=ADDRESS [<flags>]
    Dump remote read series.

remote-read stats --address=ADDRESS [<flags>]
    Show statistic of remote read series.
```

Then:

```sh
docker run --rm \
  --env-file .env \
  grafana/mimirtool:3.1.4 \
  remote-read stats \
  --selector '{__name__=~".+"}' \
  --remote-read-path /prometheus/api/v1/read
```

Mimirtool's Remote Read `stats` command asks the server for the actual stored series and samples and reports things like sample count and number of series. See [Grafana Labs](https://grafana.com/docs/mimir/latest/manage/tools/mimirtool/).

You should see output resembling:

```
ts=2026-08-14T06:59:52.188043149Z level=info msg="created remote read client" endpoint=https://prometheus-prod-24-prod-eu-west-2.grafana.net/prometheus/api/v1/read

ts=2026-08-14T06:59:52.188064734Z level=info msg="querying time" from=2026-08-14T05:59:52Z to=2026-08-14T06:59:52Z selectors=1

ts=2026-08-14T06:59:52.68340712Z level=info msg="MIN TIME                           MAX TIME                           DURATION     NUM SAMPLES  NUM SERIES   NUM STALE NAN VALUES  NUM NAN VALUES"

ts=2026-08-14T06:59:52.683436581Z level=info msg="2026-08-14 06:00:03.625 +0000 UTC  2026-08-14 06:59:45.068 +0000 UTC  59m41.443s   171780       2863         0                     240"
```

By default you'll see a relatively short query window, which is perfect for this test.

> [!success] Success
>
> This is the important milestone. We've proven:
> 
> ```
> Laptop
>     ↓
> Docker
>     ↓
> mimirtool
>     ↓
> Grafana Cloud Remote Read
>     ↓
> Actual stored samples
> ```
> 
> At this point the central premise of the whole setup has been verified.

---

## 8. Inspect an individual metric

Before downloading everything, choose a metric that you know well.

For example, given our `donor-api` metrics, perhaps:

```sh
docker run --rm \
  --env-file .env \
  grafana/mimirtool:3.1.4 \
  remote-read dump \
  --selector 'drs_search_parameters_total{app = "donor-api"}' \
  --remote-read-path /prometheus/api/v1/read
```

The command `remote-read dump` prints each stored sample together with its timestamp. See [Grafana Labs](https://grafana.com/docs/mimir/latest/manage/tools/mimirtool/).

You should see something conceptually like:

```
{__name__="drs_search_parameters_total",app="donor-api",...} 1234 1786534567000
{__name__="drs_search_parameters_total",app="donor-api",...} 1235 1786534627000
{__name__="drs_search_parameters_total",app="donor-api",...} 1235 1786534687000
...
```

We're seeing **Grafana's individual stored scrape samples**, which is precisely what we want to preserve.

---

## 9. Do a disposable TSDB export

Now let's prove that Remote Read → Prometheus TSDB works.

Create:

```sh
mkdir -p data/test-tsdb
```

Run:

```sh
docker run --rm \
  --env-file .env \
  -v "$PWD/data/test-tsdb:/archive" \
  grafana/mimirtool:3.1.4 \
  remote-read export \
  --selector 'drs_search_parameters_total{app = "donor-api"}' \
  --remote-read-path /prometheus/api/v1/read \
  --tsdb-path /archive
```

Grafana explicitly documents this use of `remote-read export`: it exports matching series and samples into a local TSDB, and an existing TSDB path may be reused. See [Grafana Labs](https://grafana.com/docs/mimir/latest/manage/tools/mimirtool/).

You should get output like:

```
ts=2026-08-14T07:03:46.076523556Z level=info msg="created remote read client" endpoint=https://prometheus-prod-24-prod-eu-west-2.grafana.net/prometheus/api/v1/read
ts=2026-08-14T07:03:46.076587316Z level=info msg="using existing TSDB" path=/archive
ts=2026-08-14T07:03:46.076599777Z level=info msg="querying time" from=2026-08-14T06:03:46Z to=2026-08-14T07:03:46Z selectors=1
ts=2026-08-14T07:03:46.372271418Z level=info msg="BLOCK ULID                  MIN TIME                       MAX TIME                       DURATION     NUM SAMPLES  NUM CHUNKS   NUM SERIES   SIZE"
ts=2026-08-14T07:03:46.37230013Z level=info msg="01KZZHAZ8WQZ8TSBZHNXQEGJ7X  2026-08-14 06:04:21 +0000 UTC  2026-08-14 07:03:21 +0000 UTC  59m0.001s    357          6            6            1KiB931B"
```

Now:

```sh
find data/test-tsdb -maxdepth 3 -print
```

You should see Prometheus TSDB contents. Typically there will be block directories identified by ULIDs:

```
data/test-tsdb/
├── 01K...
│   ├── chunks/
│   ├── index
│   └── meta.json
...
```

We're now storing genuine Prometheus blocks locally.

---

## 10. Analyze the TSDB with `promtool`

Grafana specifically recommends `promtool tsdb analyze` for inspecting a TSDB produced by Mimirtool. See [Grafana Labs](https://grafana.com/docs/mimir/latest/manage/tools/mimirtool/).

We can do this without installing Prometheus locally:

```sh
docker run --rm \
  -v "$PWD/data/test-tsdb:/archive" \
  --entrypoint /bin/promtool \
  prom/prometheus:latest \
  tsdb analyze /archive
```

You should get statistics about labels, series and samples. Something like:

```
Block ID: 01KZZHAZ8WQZ8TSBZHNXQEGJ7X
Duration: 59m0.001s
Total Series: 6
Label names: 6
Postings (unique label pairs): 11
Postings entries (total label pairs): 36

Label pairs most involved in churning:
0 job=integrations/metrics_endpoint/1326963-metrics-endpoint-donor-api-accp
0 scrape_job=donor-api-accp
0 parameters=identity, dateOfBirth
0 env=test
0 job=integrations/metrics_endpoint/1326963-metrics-endpoint-donor-api-test
0 __name__=drs_search_parameters_total
0 env=accp
0 parameters=donorNumber
0 parameters=donorNumber, identity, dateOfBirth
0 scrape_job=donor-api-test
0 app=donor-api

Label names most involved in churning:
0 __name__
0 app
0 env
0 job
0 parameters
0 scrape_job

Most common label pairs:
6 __name__=drs_search_parameters_total
6 app=donor-api
3 scrape_job=donor-api-accp
3 env=accp
3 job=integrations/metrics_endpoint/1326963-metrics-endpoint-donor-api-accp
3 env=test
3 job=integrations/metrics_endpoint/1326963-metrics-endpoint-donor-api-test
3 scrape_job=donor-api-test
2 parameters=donorNumber
2 parameters=donorNumber, identity, dateOfBirth
2 parameters=identity, dateOfBirth

Label names with highest cumulative label value length:
138 job
66 parameters
28 scrape_job
27 __name__
9 app
8 env

Highest cardinality labels:
3 parameters
2 env
2 job
2 scrape_job
1 __name__
1 app

Highest cardinality metric names:
6 drs_search_parameters_total
```

Delete the disposable test whenever you're happy:

```sh
rm -rf data/test-tsdb
```

---

## 11. Build the archive container

Create this `Dockerfile`:

```Dockerfile
FROM grafana/mimirtool:3.1.4 AS mimirtool

FROM alpine:3.22

RUN apk add --no-cache \
    ca-certificates \
    coreutils

COPY --from=mimirtool /bin/mimirtool /usr/local/bin/mimirtool
COPY archive.sh /usr/local/bin/archive

RUN chmod +x /usr/local/bin/archive

ENTRYPOINT ["/bin/sh", "/usr/local/bin/archive"]
```

---

## 12. Create the incremental archiver

Create `archive.sh`:

```sh
#!/bin/sh

# Exit on errors and variables that have not been initialized.
set -eu


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TSDB_PATH="/data/tsdb"
STATE_DIR="/data/state"
BACKUP_PATH="/data/backups"

CHECKPOINT_FILE="${STATE_DIR}/checkpoint"

REMOTE_READ_PATH="/prometheus/api/v1/read"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

mkdir -p "$TSDB_PATH" "$STATE_DIR" "$BACKUP_PATH"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

timestamp() {
    # GNU date is available inside our Linux container.
    date -u --date="@$1" '+%Y-%m-%dT%H:%M:%SZ'
}

write_checkpoint() {
    # Write to a temporary file first, then atomically rename it.
    printf '%s\n' "$1" > "${CHECKPOINT_FILE}.tmp"
    mv "${CHECKPOINT_FILE}.tmp" "$CHECKPOINT_FILE"
}


# ---------------------------------------------------------------------------
# Initialize the checkpoint on the first run
# ---------------------------------------------------------------------------

if [ ! -f "$CHECKPOINT_FILE" ]; then
    now="$(date +%s)"
    start=$((now - INITIAL_LOOKBACK_SECONDS))

    echo "No checkpoint found."
    echo "Starting at $(timestamp "$start")"

    write_checkpoint "$start"
fi


# ---------------------------------------------------------------------------
# Back up the current archive before changing anything
# ---------------------------------------------------------------------------

backup_time="$(date -u '+%Y-%m-%dT%H-%M-%SZ')"
backup_dir="${BACKUP_PATH}/${backup_time}"

echo
echo "Creating backup:"
echo "  $backup_dir"

mkdir -p "${backup_dir}/tsdb" "${backup_dir}/state"

cp -a "${TSDB_PATH}/." "${backup_dir}/tsdb/"
cp -a "${STATE_DIR}/." "${backup_dir}/state/"

echo "Backup completed."


# ---------------------------------------------------------------------------
# Determine the fixed target for this run
# ---------------------------------------------------------------------------

from="$(cat "$CHECKPOINT_FILE")"

# Capture "now" once.
#
# The target for this entire run is now minus 10 minutes.
# It does not move while the script is running.
now="$(date +%s)"
target=$((now - LAG_SECONDS))

echo
echo "Current checkpoint: $(timestamp "$from")"
echo "Target:             $(timestamp "$target")"

if [ "$from" -ge "$target" ]; then
    echo
    echo "Archive is already caught up."
    exit 0
fi


# ---------------------------------------------------------------------------
# Export everything from the checkpoint up to the target
# ---------------------------------------------------------------------------

while [ "$from" -lt "$target" ]; do

    # Export at most WINDOW_SECONDS at a time.
    to=$((from + WINDOW_SECONDS))

    if [ "$to" -gt "$target" ]; then
        to="$target"
    fi

    from_text="$(timestamp "$from")"
    to_text="$(timestamp "$to")"

    echo
    echo "Exporting:"
    echo "  $from_text"
    echo "  -> $to_text"

    # Capture mimirtool's output while preserving its exit status.
    #
    # Using this if-form also means we don't need to temporarily disable
    # `set -e`.
    if output="$(
        mimirtool remote-read export \
            --selector "$SELECTOR" \
            --remote-read-path "$REMOTE_READ_PATH" \
            --from "$from_text" \
            --to "$to_text" \
            --tsdb-path "$TSDB_PATH" \
            2>&1
    )"; then
        exit_code=0
    else
        exit_code=$?
    fi

    # Show mimirtool's output so the run can be inspected manually.
    printf '%s\n' "$output"

    # Never advance the checkpoint after a failed export.
    if [ "$exit_code" -ne 0 ]; then
        echo >&2
        echo >&2 "Export failed."
        echo >&2 "Checkpoint remains at $from_text."
        exit 1
    fi

    # We've seen mimirtool 3.1.4 print this error prefix while returning
    # success, so check the output as an additional safeguard.
    if printf '%s\n' "$output" | grep -Fq 'mimirtool: error:'; then
        echo >&2
        echo >&2 "mimirtool reported an error."
        echo >&2 "Checkpoint remains at $from_text."
        exit 1
    fi

    # Only advance the checkpoint after a successful export.
    write_checkpoint "$to"
    from="$to"

    echo "Checkpoint advanced to $to_text."
done


# ---------------------------------------------------------------------------
# Finished successfully
# ---------------------------------------------------------------------------

echo
echo "Archive caught up successfully."
echo "Latest archived point: $(timestamp "$target")"
```

The export is six hours at a time. This matters if our laptop has been off for, say, ten days. Instead of asking Grafana Cloud for ten days of every series in one gigantic request, we make a series of bounded requests. Mimirtool has historically had bugs around very large Remote Read exports, and Grafana made fixes specifically for long time ranges, so bounded windows are a sensible additional guardrail. See [GitHub](https://github.com/grafana/mimir/actions/workflows/snyk.yml).

---

## 13. Create `compose.yaml`

```yaml
services:
  archive:
    build:
      context: .
      args:
        MIMIRTOOL_VERSION: 3.1.4

    env_file:
      - .env

    volumes:
      - ./data:/data
```

Build it:

```sh
docker-compose build
```

## 14. Before running it continuously, make the first run tiny

Don't immediately download 13 days.

Temporarily change `.env`:

```dotenv
INITIAL_LOOKBACK_SECONDS=3600 # 1 hour
```

Now:

```
docker compose up
```

Do **not** add `-d` yet.

You should see something like:

```
[+] up 1/1
 ✔ Container grafana-metrics-archive-archive-1 Recreated                                                                                                                                                        0.1s
Attaching to archive-1
archive-1  | No checkpoint found.
archive-1  | Starting at 2026-08-14T06:23:46Z
archive-1  | 
archive-1  | Creating backup:
archive-1  |   /data/backups/2026-08-14T07-23-46Z
archive-1  | Backup completed.
archive-1  | 
archive-1  | Current checkpoint: 2026-08-14T06:23:46Z
archive-1  | Target:             2026-08-14T07:13:46Z
archive-1  | 
archive-1  | Exporting:
archive-1  |   2026-08-14T06:23:46Z
archive-1  |   -> 2026-08-14T07:13:46Z
archive-1  | ts=2026-08-14T07:23:47.006787132Z level=info msg="created remote read client" endpoint=https://prometheus-prod-24-prod-eu-west-2.grafana.net/prometheus/api/v1/read
archive-1  | ts=2026-08-14T07:23:47.007885187Z level=info msg="using existing TSDB" path=/data/tsdb
archive-1  | ts=2026-08-14T07:23:47.007891649Z level=info msg="querying time" from=2026-08-14T06:23:46Z to=2026-08-14T07:13:46Z selectors=1
archive-1  | ts=2026-08-14T07:23:47.493974181Z level=info msg="BLOCK ULID                  MIN TIME                       MAX TIME                       DURATION     NUM SAMPLES  NUM CHUNKS   NUM SERIES   SIZE"
archive-1  | ts=2026-08-14T07:23:47.493999532Z level=info msg="01KZZJFM7DC8VH9EHFZZBS76VE  2026-08-14 06:24:03 +0000 UTC  2026-08-14 07:13:45 +0000 UTC  49m41.444s   143150       2863         2863         457KiB45B"
archive-1  | Checkpoint advanced to 2026-08-14T07:13:46Z.
archive-1  | 
archive-1  | Archive caught up successfully.
archive-1  | Latest archived point: 2026-08-14T07:13:46Z
archive-1 exited with code 0
```

---

## 15. Inspect the checkpoint

Run:

```sh
cat data/state/checkpoint
```

You'll see something like:

```
1786533902
```

Convert it:

```sh
date -r "$(cat data/state/checkpoint)"
```

On macOS that will show you the corresponding local date/time (minus 10 minutes).

## 16. Analyze the archive

Again:

```sh
docker run --rm \
  -v "$PWD/data/tsdb:/archive" \
  --entrypoint /bin/promtool \
  prom/prometheus:latest \
  tsdb analyze /archive
```

At this point we have tested the automated writer's output independently of the writer itself.

---

## 17. Test failure recovery

This one is worth doing.

First:

```sh
echo "$(cat data/state/checkpoint)"
```

My current value is `1786691626` (`Fri Aug 14 09:13:46 CEST 2026`)

Then temporarily break the address:

```dotenv
MIMIR_ADDRESS=https://this-does-not-exist.invalid
```

Run:

```sh
docker compose up
```

You'll get a failed export:

```
[+] up 1/1
 ✔ Container grafana-metrics-archive-archive-1 Recreated                                                                                                                                                        0.1s
Attaching to archive-1
archive-1  | 
archive-1  | Creating backup:
archive-1  |   /data/backups/2026-08-14T07-30-29Z
archive-1  | Backup completed.
archive-1  | 
archive-1  | Current checkpoint: 2026-08-14T07:13:46Z
archive-1  | Target:             2026-08-14T07:20:29Z
archive-1  | 
archive-1  | Exporting:
archive-1  |   2026-08-14T07:13:46Z
archive-1  |   -> 2026-08-14T07:20:29Z
archive-1  | ts=2026-08-14T07:30:30.155291077Z level=info msg="created remote read client" endpoint=https://this-does-not-exist.invalid/prometheus/api/v1/read
archive-1  | ts=2026-08-14T07:30:30.155421534Z level=info msg="using existing TSDB" path=/data/tsdb
archive-1  | ts=2026-08-14T07:30:30.15543628Z level=info msg="querying time" from=2026-08-14T07:13:46Z to=2026-08-14T07:20:29Z selectors=1
archive-1  | mimirtool: error: error sending request: Post "https://this-does-not-exist.invalid/prometheus/api/v1/read": dial tcp: lookup this-does-not-exist.invalid on 127.0.0.11:53: no such host, try --help
archive-1  | 
archive-1  | Export failed.
archive-1  | Checkpoint remains at 2026-08-14T07:13:46Z.
archive-1 exited with code 1
```

Check:

```sh
echo "$(cat data/state/checkpoint)"
```

It should still be equal to the previous value.

Then restore the proper address and run again.

It should retry from the same place. That proves the most important failure property of the system.

---

## 18. Now perform the real 13-day backfill

Stop everything:

```sh
docker compose down
```

Because our one-hour test has already initialized the checkpoint, changing `INITIAL_LOOKBACK_SECONDS` won't affect it.

For the real archive, I would start clean:

```sh
rm -rf data
```

Restore:

```dotenv
INITIAL_LOOKBACK_SECONDS=1123200
```

Then run it interactively once:

```sh
docker compose up
```

You'll see it progress in six-hour pieces:

```
13 days ago
│
├── 6h ✓
├── 6h ✓
├── 6h ✓
├── 6h ✓
...
└── now - 10 min
```

The checkpoint moves after every six-hour chunk, so if Docker dies halfway through a 13-day initial import, you don't have to start the whole import again.

---

## 19. Compare local data against Grafana Cloud

This is the strongest test.

Pick a known metric:

```
drs_search_parameters_total
```

First ask Grafana Cloud for a period that is in our local archive. Then run a local Prometheus against the archive.  Grafana's Mimirtool documentation explicitly shows opening an exported TSDB directly with Prometheus. See [Grafana Labs](https://grafana.com/docs/mimir/latest/manage/tools/mimirtool/).

Create `prometheus.yml`:

```yaml
global:
  scrape_interval: 1m
```

Start:

```sh
docker run --rm \
  -p 9090:9090 \
  -v "$PWD/data/tsdb:/prometheus" \
  -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus
```

Then open:

```url
http://localhost:9090
```

Query:

```
drs_search_parameters_total
```

with time range `2w` and reference time about 15 minutes ago.

I got:

![Local](docs/images/local.png)

Compare the same timestamp against Grafana Cloud Explore.

![Remote](docs/images/remote.png)

> [!important] Important
> Don't run the archive container simultaneously with this Prometheus container. We want only one process manipulating that TSDB directory at a time.




