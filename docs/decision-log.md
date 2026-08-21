# Decision Log

Why each major tool and pattern was chosen, not just what was built. Organized
by area, in the order decisions actually needed to be made.

---

## Terraform / Infrastructure

**Bastion + private app server, instead of a single public instance.**
The app server holds the actual workload (Docker, Jenkins, secrets). Giving
it no public IP at all means it simply cannot be reached except through one
controlled path — the bastion. This is defense in depth: compromising the
bastion alone isn't enough, since `app-sg`'s SSH rule only trusts traffic
*from `bastion-sg`*, not from any IP.

**A route table determines "private," not a flag.** AWS has no literal
"private subnet" setting. A subnet is private because its route table has no
path to an Internet Gateway. The private subnet's default route points to
the NAT Gateway instead — outbound-only, so package installs still work, but
nothing external can initiate a connection in. This is worth understanding
precisely, because "private" is a consequence of routing, not a checkbox.

**NAT Gateway lives in the public subnet, not the private one.** It needs its
own path to the Internet Gateway to actually forward traffic outward, so it
has to sit somewhere with that route already — the public subnet.

**S3 + DynamoDB for Terraform state, not local state.** Local state has no
locking (two people running `apply` simultaneously can corrupt it), no
sharing, no history. DynamoDB provides the lock; S3 (with versioning) gives a
rollback path. This mattered in practice: state was intentionally protected
with `lifecycle.prevent_destroy` on the S3 bucket specifically so a
targeted destroy of the rest of the infrastructure could never accidentally
also destroy the ability to track what Terraform owns.

**Single availability zone, not multi-AZ.** A second AZ would need its own
NAT Gateway (a real per-hour cost) for genuine redundancy. For a lab
environment, that cost isn't justified — this is a documented, deliberate
scope decision, not an oversight.

**AMI owner pinned explicitly (`099720109477`, Canonical).** Filtering by
name alone (`ubuntu/images/hvm-ssd-gp3/ubuntu-noble-*`) without pinning the
owner account means any AWS account could technically publish a
similarly-named AMI. This is a real, if narrow, supply-chain risk — pinning
the owner closes it.

---

## Security & IAM

**Security group referencing a security group, not a CIDR.** `app-sg`'s SSH
rule allows traffic *from `bastion-sg`*, not from a specific IP range. This
means the rule is correct forever, regardless of what IP the bastion
actually has at any moment — a CIDR-based rule would need updating every
time an instance was replaced.

**IAM instance profile, never access keys.** The EC2 role gives
temporary, automatically-rotating credentials via the metadata service.
Nothing is ever written to disk on the instance — verified directly by
checking `aws sts get-caller-identity` from inside the box and seeing an
assumed-role identity, not a stored user.

**Two separate secret systems — Ansible Vault and SSM Parameter Store — used
for different secret lifecycles, not interchangeably.** Vault secrets are
needed *at configuration time*, by a playbook run from a laptop, decrypted
with a local passphrase. SSM secrets are needed *at runtime*, by a process
already running on the instance, fetched using the instance's own IAM role.
Using Vault for a runtime secret (like a DockerHub token a pipeline needs
live) would mean that secret sits permanently in a file on disk. Using SSM
for a config-time secret (like the initial devops user's password hash)
would mean authenticating to AWS just to configure a local Linux account —
unnecessary coupling.

**SSM parameter *values* are never written by Terraform.** Only the IAM
*permission* to read a given path lives in Terraform (`ssm.tf`). If
Terraform also created the parameter's actual value
(`aws_ssm_parameter` with a real secret), that value would land in
Terraform state — plaintext-readable in most configurations — which is
precisely what "not hardcoded" is meant to prevent. Values are set
out-of-band via the AWS CLI.

**SSH hardening via a numbered drop-in config file, not editing the main
`sshd_config`.** Ubuntu's main config includes everything in
`sshd_config.d/*.conf` at the very top, and sshd keeps the *first* value it
sees per keyword. Cloud-init ships its own `50-cloud-init.conf` in that same
directory. A hardening file named `01-devops-hardening.conf` sorts
alphabetically *before* that file, so its settings win — confirmed with
`sshd -T`, which shows the actual effective configuration rather than just
what one file claims.

---

## Ansible

**Fail2Ban configured with `backend = systemd`, not the default log-file
backend.** Ubuntu has no `/var/log/secure` (that's a RHEL/CentOS convention),
and minimal images may not even run rsyslog. Reading directly from the
systemd journal works regardless of what logging stack is present.

**A dedicated `devops` user, with root SSH disabled, rather than continuing
to use the default cloud-init `ubuntu` user for everything.** Establishes a
named, auditable account for ongoing administration, separate from the
account cloud-init itself provisions.

---

## Docker Compose / Jenkins CI/CD

**Jenkins runs pipeline steps as sibling containers via a mounted Docker
socket, not via Docker-in-Docker.** The alternative — running a Docker
daemon *inside* the Jenkins container — adds real complexity and its own
security surface. Mounting the host's socket and using
`--volumes-from jenkins` on every `docker run` in the pipeline means new
containers are created as true siblings on the host's daemon, sharing
Jenkins's own workspace mount exactly. This is also *why* a plain
`-v $WORKSPACE:/src` bind mount doesn't work here: `$WORKSPACE` on the host
filesystem isn't a real path at all, since Jenkins's actual files live
inside its own named Docker volume — a bind mount using that path would
silently mount an empty directory with no error.

**Explicitly acknowledged trade-off:** mounting the Docker socket gives the
Jenkins container effective root on the host — anyone who can run a Jenkins
job can, in principle, mount `/` and escape the container. Acceptable for a
single-user lab; a production setup would use a remote build agent or a
rootless Docker daemon instead.

**Custom Jenkins image (not the stock `jenkins/jenkins:lts`) to bake in the
Docker CLI, AWS CLI, and Prometheus plugin.** The stock image has none of
these, and the pipeline cannot function without the first two — installing
them at container-build time (not runtime) means every container start is
identical and fast, with no first-boot provisioning step.

**Every service given an explicit sub-path identity, once fronted by
Nginx.** Jenkins, SonarQube, and Grafana were all originally built assuming
they'd be served from `/`. Once routed behind Nginx at `/jenkins`, `/sonar`,
`/grafana`, each needed to be told about its actual root — Jenkins via
`--prefix=/jenkins`, SonarQube via `SONAR_WEB_CONTEXT=/sonar`, Grafana via
`GF_SERVER_ROOT_URL` / `GF_SERVER_SERVE_FROM_SUB_PATH`. Skipping this for
any one service means that service's own internal links and API calls
silently fail once proxied, even though the container itself reports
healthy.

**Pipeline secrets (SonarQube token, DockerHub credentials) fetched fresh
from SSM inside each stage, never stored as Jenkins credentials.** Same
reasoning as the IAM/SSM decision above — rotation without redeployment, an
audit trail via CloudTrail, and zero credentials persisted anywhere in
Jenkins's own storage or in the `Jenkinsfile` itself.

**A dedicated `Fix workspace permissions` stage before the image build.**
Earlier stages (Lint, Test) run as `root` inside their sibling containers and
can leave root-owned files in the shared workspace. The build stage later
needs to read that entire directory as the Jenkins user (uid 1000) to
package the Docker build context — a `chown -R 1000:1000 .` step,
positioned deliberately between the scan stages and the build stage, resets
ownership before it becomes a blocker.

---

## Monitoring

**`node_exporter` and the Jenkins Prometheus plugin added as the mechanism
for EC2 and Jenkins metrics, rather than trying to scrape anything from
CloudWatch.** Prometheus's own scrape model is simpler for metrics already
inside the same Docker network, and keeps the whole metrics pipeline
self-contained within the stack rather than depending on a separate AWS
service and its own IAM permissions for this particular data.

**SonarQube given a link-through Grafana panel, not a native chart.**
SonarQube doesn't expose Prometheus-native metrics. Rendering its issue
counts as an actual Grafana time series would require a JSON API-style
plugin install — extra surface area for a metric that SonarQube already
displays well on its own dashboard. A working link is an honest, simpler
choice than a half-built integration.

**Prometheus services published with `ports:`, not just `expose:`, once it
became clear the UI needed to be reachable from outside the Docker
network.** `expose:` only makes a port reachable to *other containers* on
the same network — it does not publish it to the host at all. Every service
that a human needs to reach directly (Jenkins, SonarQube, Grafana, and
eventually Prometheus) needs an explicit `ports:` mapping;
anything only ever reached by other containers (like `sonar-db`) correctly
stays on `expose:` only.
