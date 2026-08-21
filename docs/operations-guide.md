# Operations Guide — Monitoring & Troubleshooting

Day-to-day operation of the stack: how to check health, read metrics, and fix
the problems that actually came up while building this.

---

## Quick health check

```bash
ssh app
cd /opt/devops-stack
docker compose ps
```

Every service should show `Up`. Note: Jenkins, SonarQube, and Nginx may show
`(unhealthy)` in the status column even when they're genuinely fine — their
Docker `HEALTHCHECK` definitions in `docker-compose.yml` still probe
un-prefixed paths (e.g. `/login` instead of `/jenkins/login`) from an earlier
version of the stack, before the Nginx sub-path routing was added. Verify the
*real* status instead of trusting the label:

```bash
docker exec jenkins curl -fsS http://localhost:8080/jenkins/login > /dev/null && echo OK
docker exec sonarqube wget -qO- http://localhost:9000/sonar/api/system/status
```

## Checking metrics are flowing

```bash
docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -B2 '"health"'
```

Four targets should show `"health": "up"`: `prometheus`, `app`,
`node-exporter`, `jenkins`. If you just changed `prometheus.yml` and don't
see the change reflected, **Prometheus does not auto-reload on file
change** — the bind-mounted file updates, but the running process keeps its
old config until restarted:

```bash
docker compose restart prometheus
```

## Viewing dashboards and alerts

Tunnel in:
```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 app
```

- Grafana dashboards: `http://localhost:3000/grafana` → Dashboards
- Prometheus alert status: `http://localhost:9090/alerts`

Alert rules currently defined (`docker-compose/prometheus/alert_rules.yml`):
| Alert | Condition | For |
|---|---|---|
| `JenkinsDown` | `up{job="jenkins"} == 0` | 5 min |
| `HighCPUUsage` | CPU > 70% (from node-exporter) | 5 min |
| `AppDown` | `up{job="app"} == 0` | 5 min |

All should show **Inactive** (green) in normal operation.

## Running a pipeline build manually

```
http://localhost:8080/jenkins/job/<job-name>/
```
Click **Build Now**, then **Console Output** on the resulting build.

**A build failing partway is often informative, not catastrophic** — check
which stage failed and read the actual error text before assuming something
is broken. Several real fixes this project needed were found exactly this
way (see `decision-log.md` for specifics).

---

## Common problems

### SSH tunnel keeps dropping / "connection refused" after a while

Your ISP-facing IP may have changed (check
`curl -s https://checkip.amazonaws.com` against the security group's allowed
CIDR), or the SSH connection genuinely idled out. Confirm
`ServerAliveInterval 30` / `ServerAliveCountMax 10` are set in `~/.ssh/config`
for both `bastion` and `app` hosts — without them, long idle periods (e.g.
clicking through a browser UI without terminal activity) can silently kill
the tunnel.

If the browser shows `ERR_CONNECTION_REFUSED` or `ERR_CONNECTION_RESET`,
reopen the tunnel with every port you need in one command:
```bash
ssh -L 8080:localhost:8080 -L 9000:localhost:9000 -L 3000:localhost:3000 -L 9090:localhost:9090 -L 8081:localhost:8081 app
```

### A service is unreachable even though the container shows "Up"

Check whether the port is actually **published to the host**, not just
**exposed to other containers**. `expose:` in `docker-compose.yml` only makes
a port reachable from other containers on the same Docker network — it does
**not** open it on the host at all. A service that needs to be reached from
your Mac (via SSH tunnel) needs `ports: ["127.0.0.1:PORT:PORT"]`, not
`expose:`.

```bash
grep -A 5 "^  <service>:" docker-compose/docker-compose.yml
```

### A Jenkins pipeline stage that used to pass now 404s against SonarQube or Jenkins itself

Check whether the URL in the Jenkinsfile or `deploy-stack.yml` includes the
correct sub-path. Since the stack is fronted by Nginx at `/jenkins`,
`/sonar`, `/grafana`, every internal reference to these services from *other*
parts of the system (health checks, the Jenkinsfile's `SONAR_HOST` variable)
needs the same prefix — e.g. `http://sonarqube:9000/sonar/...`, not
`http://sonarqube:9000/...`.

### `docker build` fails with a permission error reading the workspace

Sibling containers in earlier pipeline stages (Lint, Test) run as `root` and
can leave root-owned cache files in the workspace
(`.pytest_cache`, `.ruff_cache`, coverage reports). The `Fix workspace
permissions` stage in the Jenkinsfile (`chown -R 1000:1000 .`) resets
ownership before the build step runs. If this stage is missing or was
removed, re-add it directly before `Build image`.

### `docker push` fails with "incorrect username or password"

The DockerHub token in SSM may be stale or was never actually validated.
Test it directly, outside Jenkins, before touching the pipeline:
```bash
DOCKERHUB_TOKEN=$(aws ssm get-parameter --name "/devops-lab/dockerhub/token" --with-decryption --query Parameter.Value --output text)
echo "$DOCKERHUB_TOKEN" | docker login -u <username> --password-stdin
```
If this fails locally, generate a fresh token from DockerHub (Account
Settings → Personal access tokens → Read & Write scope), and overwrite the
SSM parameter (`--overwrite` flag required since it already exists).

### Terraform plan shows it wants to recreate/destroy everything

Check `terraform state list` first — if it only shows a handful of backend
resources (S3 bucket, DynamoDB table) and none of your actual
VPC/EC2/IAM resources, your state is out of sync with the tracked backend
key. Cross-check directly against AWS reality before assuming state is
wrong:
```bash
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,stopped" --output table
```
If nothing comes back, the infrastructure genuinely doesn't exist and
`terraform apply` will correctly rebuild it. If instances *do* exist but
Terraform doesn't know about them, you likely need `terraform import` rather
than a fresh apply.

### After a Terraform rebuild, nothing connects anymore

New instances get new IPs. Update `~/.ssh/config`, `ansible/inventory.ini`,
and if your own IP also changed, `terraform/variables.tf`'s `my_ip_cidr`
default — then re-run the Ansible playbooks from scratch (`site.yml`, then
`deploy-stack.yml`). Nothing on the fresh instances is configured until
Ansible runs again.

---

## Resource limits to keep an eye on

This stack runs six services plus the app on a single `t3.micro` (1GB RAM),
backed by a 4GB swap file set up specifically to prevent SonarQube's JVMs
from triggering the OOM killer. Check memory pressure periodically:
```bash
free -h
```
Swap usage climbing steadily over many hours (not just spiking briefly) is a
sign the stack is genuinely under-provisioned for sustained heavy use — a
`docker compose restart` on the heavier services (SonarQube, Jenkins) can
relieve pressure without a full stack rebuild.
