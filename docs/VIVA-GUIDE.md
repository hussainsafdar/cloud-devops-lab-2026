# Viva Guide — Cloud DevOps Lab 2026

Everything built, in the order it was built, with the reasoning behind each
decision and the evidence that it works.

**Account:** `094842496346` · **Region:** `us-east-1` · **Repo:** `hussainsafdar/cloud-devops-lab-2026`

---

## 1. The 30-second answer

> "I built a two-tier AWS environment with Terraform — a bastion in a public
> subnet and an application server in a private subnet with no public IP. I
> configured both with Ansible: Docker, a hardened SSH setup, a non-root admin
> user and Fail2Ban. On the app server I run a CI/CD stack in Docker Compose —
> Jenkins, SonarQube and Postgres, plus a Flask app. The Jenkins pipeline tests
> the app, runs static analysis, builds an image and deploys it. Secrets are
> split by lifetime: Ansible Vault for things needed at configuration time, SSM
> Parameter Store for things needed at runtime. Nothing anywhere holds a static
> AWS credential — the instances authenticate with an IAM role."

That paragraph contains almost every marking point. Everything below is depth
behind it.

---

## 2. Architecture

```
                              Internet
                                  │
                        ┌─────────┴─────────┐
                        │ Internet Gateway  │
                        └─────────┬─────────┘
  VPC 10.0.0.0/16                 │
  ┌────────────────────────────────────────────────────────────┐
  │  PUBLIC subnet 10.0.1.0/24                                 │
  │  ┌──────────────────┐        ┌──────────────┐              │
  │  │ bastion          │        │ NAT Gateway  │              │
  │  │ t3.micro         │        │ + Elastic IP │              │
  │  │ Elastic IP       │        └──────┬───────┘              │
  │  └────────┬─────────┘               │                      │
  │           │ SSH 22                  │ outbound only        │
  │  ┌────────▼─────────────────────────▼──────────────────┐   │
  │  │  PRIVATE subnet 10.0.2.0/24                         │   │
  │  │  ┌───────────────────────────────────────────────┐  │   │
  │  │  │ app server · t3.micro · no public IP          │  │   │
  │  │  │ ┌─────────┐ ┌──────────┐ ┌────┐ ┌──────────┐  │  │   │
  │  │  │ │ Jenkins │ │SonarQube │ │ PG │ │ Flask app│  │  │   │
  │  │  │ │  :8080  │ │  :9000   │ │    │ │  :5000   │  │  │   │
  │  │  │ └─────────┘ └──────────┘ └────┘ └──────────┘  │  │   │
  │  │  │        all bound to 127.0.0.1 only            │  │   │
  │  │  └───────────────────────────────────────────────┘  │   │
  │  └─────────────────────────────────────────────────────┘   │
  └────────────────────────────────────────────────────────────┘
```

**Traffic rules in one line each:**

- You reach the bastion because `bastion-sg` allows port 22 from your IP only.
- You reach the app server *only* through the bastion — `app-sg` allows 22 from
  `bastion-sg` as a source, not from any IP range.
- The app server reaches the internet outbound through the NAT Gateway, but
  nothing on the internet can reach it inbound.
- Web UIs are bound to `127.0.0.1` inside the app server, so even inside the
  VPC nothing can reach them. You use an SSH tunnel.

---

## 3. Phase 1 — Infrastructure (Terraform)

### What and why, file by file

**[`providers.tf`](../terraform/providers.tf)** — pins the AWS provider to `~> 5.0`
and Terraform to `>= 1.5.0`. Version pinning means a provider release six months
from now cannot silently change what `apply` does.

**[`vpc.tf`](../terraform/vpc.tf)** — VPC, two subnets, IGW, NAT Gateway, two route
tables and their associations.

The subtle point worth stating aloud in a viva:

> A subnet is not private because of a checkbox. It is private because its route
> table has no route to an Internet Gateway. The private route table sends
> `0.0.0.0/0` to the NAT Gateway instead — outbound works, inbound is impossible.

`enable_dns_hostnames` is on because the SSM agent and AWS service endpoints
need DNS resolution; without it you get failures that are hard to trace.

**[`ec2.tf`](../terraform/ec2.tf)** — the AMI lookup, both instances, the bastion's
Elastic IP.

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical
  ...
}
```

Two decisions to defend:
- **`owners` is pinned.** Without it, any AWS account could publish an AMI whose
  name matches the filter and it could be selected. That is a supply-chain risk.
- **`most_recent = true`** trades reproducibility for patching. A new AMI means
  instance replacement. For production you would pin an AMI ID and update it
  deliberately.

The **Elastic IP on the bastion** was added after being bitten: every instance
replacement changed the public IP, silently breaking the Ansible inventory. An
EIP attached to a running instance is free.

`user_data` installs `ec2-instance-connect` and enables the SSM agent, so
console access and break-glass access are guaranteed rather than assumed.

The app server gets a **30 GB gp3 root volume** — Ubuntu's default 8 GB cannot
hold three JVM images plus a 4 GB swap file.

**[`security_groups.tf`](../terraform/security_groups.tf)** — covered in §4.

**[`iam.tf`](../terraform/iam.tf)** — role `devops-lab-ec2-role` with an assume-role
policy for `ec2.amazonaws.com`, three managed policies, and an instance profile.

The instance profile is the mechanism that makes everything else credential-free:
the instance receives **temporary, auto-rotating credentials** from the metadata
service. No access key is ever stored on a box.

**[`backend.tf`](../terraform/backend.tf) + [`dynamodb.tf`](../terraform/dynamodb.tf)** —
remote state in S3 with a DynamoDB lock table.

| Concern | Solution |
|---|---|
| Team members overwriting each other's state | S3 as single source of truth |
| Two applies at once corrupting state | DynamoDB lock on `LockID` |
| State containing secrets, sitting in plaintext | `encrypt = true`, plus bucket SSE |
| Bad apply needing rollback | Bucket versioning |
| Accidental deletion | `prevent_destroy` on the bucket |

**[`variables.tf`](../terraform/variables.tf)** — all inputs, with `my_ip_cidr`
carrying a `validation` block that rejects a bare IP without a mask.

**[`outputs.tf`](../terraform/outputs.tf)** — IPs, instance IDs, and a
ready-to-paste SSH command.

**[`ssm.tf`](../terraform/ssm.tf)** — covered in §6.

### How to prove it works

```bash
terraform plan          # "No changes" = reality matches code
terraform output
```

---

## 4. Phase 2 — Security groups

**bastion-sg**

| Port | Source | Reason |
|---|---|---|
| 22 | your IP `/32` | only your workstation |
| 22 | managed prefix list `com.amazonaws.us-east-1.ec2-instance-connect` | the browser "Connect" button |

**app-sg**

| Port | Source | Reason |
|---|---|---|
| 22 | **`bastion-sg`** (a security group, not a CIDR) | only the bastion may SSH in |
| 80, 443 | your IP `/32` | app traffic |

Two points that earn marks:

**Source = security group, not IP range.** The rule stays correct when instance
IPs change, and it cannot be satisfied by anything that is not actually running
in `bastion-sg`. This is the idiomatic AWS way to express "only the bastion".

**Managed prefix list, not a hardcoded CIDR.** EC2 Instance Connect connects
*from AWS*, not from your browser, so its service range must be allowed. Using
the AWS-maintained prefix list means the rule survives AWS changing that range.

> **Likely question — "why is your egress `0.0.0.0/0`?"**
> Honest answer: convenience, and it is the weakest part of the design. The
> instances need outbound for `apt`, Docker Hub and the AWS APIs. Tightening it
> properly means VPC endpoints for SSM/S3 and an allowlist for package
> mirrors — correct for production, disproportionate for a lab.

---

## 5. Phase 3 — Configuration (Ansible)

### Why Ansible and not more user_data

`user_data` runs **once**, at first boot, and is not idempotent. Ansible is
declarative and repeatable: run it a hundred times and the box converges to the
same state. That is the difference between provisioning and configuration
management.

### How Ansible reaches a private server

From [`inventory.ini`](../ansible/inventory.ini):

```ini
[app:vars]
ansible_ssh_common_args='-o ProxyCommand="ssh -W %h:%p -i ~/.ssh/my-devops-key.pem ubuntu@<bastion>"'
```

Explain the mechanism, not just the config:

- `%h` / `%p` are substituted by SSH with the target host and port.
- `-W %h:%p` tells the bastion: *do not give me a shell, just open a TCP
  connection to the app server and forward bytes.* The bastion becomes a pipe.
- There are **two** SSH sessions: laptop→bastion (builds the pipe), and
  laptop→app running *inside* it. The second is encrypted end-to-end, so the
  bastion sees only ciphertext and never handles your key.

### [`site.yml`](../ansible/site.yml) — base configuration

| Task | Why it is written that way |
|---|---|
| `cloud-init status --wait` | First boot still runs apt; racing it causes `dpkg lock` failures |
| `apt` upgrade, python3, `docker.io`, Compose plugin | Checklist items 9 |
| devops user, `sudo` group, sudoers drop-in | Checklist item 11 |
| sshd hardening via `sshd_config.d/01-…` | See below |
| Fail2Ban with `backend = systemd` | See below |

**The sshd drop-in is the best single detail to bring up unprompted:**

> Ubuntu's `sshd_config` includes `sshd_config.d/*.conf` at the very top, and
> sshd keeps the **first** value it finds for each keyword. Editing the main
> file with `lineinfile` gets silently overridden by cloud-init's
> `50-cloud-init.conf`. So the hardening lives in `01-devops-hardening.conf` —
> the `01-` prefix sorts ahead of it, so our values win. Verified with `sshd -T`.

**Fail2Ban** uses the systemd journal because Ubuntu has no `/var/log/secure`
(that is RHEL) and minimal images may not ship rsyslog at all.

### [`deploy-stack.yml`](../ansible/deploy-stack.yml) — the CI/CD stack

Beyond copying files and running Compose, it does the work that makes a 1 GB
instance survive three JVMs:

| Step | Reason |
|---|---|
| 4 GB swap file | SonarQube's Elasticsearch is OOM-killed mid-startup without it. Swap does not make it fast — it stops it dying |
| `vm.max_map_count = 262144` | Elasticsearch refuses to start below this |
| `vm.swappiness`, `fs.file-max` | Tuning for the above |
| Assert on total memory | Fails early with a clear message instead of a confusing container crash |
| Render `.env` from Vault, `no_log: true` | The DB password reaches the host only in a `0600` file |
| `docker compose pull --ignore-buildable` | Without it, Compose tries to *pull* the locally built images and fails with "pull access denied" |
| Assert host docker GID matches `group_add` | GIDs differ per machine; a mismatch gives Jenkins permission-denied on the socket. The assert turns that into a clear failure |

---

## 6. Phase 4 — Secrets

This is where most marks are, and where the two mechanisms are easily confused.

|  | Ansible Vault | SSM Parameter Store |
|---|---|---|
| Secret needed | at **config time**, by the playbook | at **runtime**, by the running app |
| Decrypted by | your laptop during `ansible-playbook` | the EC2 instance, via its IAM role |
| Stored in | the git repo, encrypted | AWS, never in git |
| Unlocked by | your passphrase | the instance profile |
| Example here | `devops` user password hash, Postgres password | SonarQube token, Jenkins credentials |

### Ansible Vault

```
ansible/group_vars/all/
├── vars.yml     # plaintext, committed — pointers only
└── vault.yml    # encrypted, committed — real values
```

`vars.yml` contains only indirection:
```yaml
devops_password_hash: "{{ vault_devops_password_hash }}"
sonar_db_password:    "{{ vault_sonar_db_password }}"
```

Why the split: you can see **which** secrets exist without decrypting, and
playbooks reference the friendly name so rotating a secret never touches task
code.

Every consuming task carries **`no_log: true`** — without it Ansible prints the
value in `-v` and `--diff` output, defeating the encryption entirely.

> **Critical gotcha worth volunteering:** the file must be at
> `group_vars/all/vault.yml`. A file at `group_vars/vault.yml` is matched
> against a *group named `vault`*, which does not exist — so Ansible loads
> nothing and reports **no error at all**. It fails completely silently.

Encryption: AES-256, key derived by PBKDF2 (10,000 rounds, 32-byte salt), HMAC
for tamper detection. The passphrase lives in `ansible/.vault_pass`, gitignored.

### SSM Parameter Store

Parameters (`SecureString`, encrypted with the `aws/ssm` KMS key):
```
/devops-lab/jenkins/admin-user       (String)
/devops-lab/jenkins/admin-password   (SecureString)
/devops-lab/jenkins/api-token        (SecureString)
/devops-lab/sonarqube/token          (SecureString)
```

**Values are created with the AWS CLI, not Terraform — deliberately.** An
`aws_ssm_parameter` resource writes the secret into Terraform state, which is
exactly what "not hardcoded" is meant to prevent. Terraform manages only the
IAM permission, which is infrastructure rather than a secret.

The policy in [`ssm.tf`](../terraform/ssm.tf) has two statements, both non-obvious:

1. **Two resource ARNs.** `GetParameter` acts on the individual parameter
   (matched by `…/jenkins/*`), while `GetParametersByPath` acts on **the path
   itself** (`…/jenkins`, no trailing `/*`). Granting only the wildcard form
   makes `GetParametersByPath` fail with `AccessDenied`.

2. **`kms:Decrypt` with a `ViaService` condition.** SecureString values come
   back still encrypted unless the caller can use the KMS key. The resource must
   be `*` because IAM does not accept KMS *alias* ARNs — the
   `kms:ViaService = ssm.us-east-1.amazonaws.com` condition is what keeps it
   tight: the role may use that key only through SSM, never for direct KMS calls.

**Proof it works, and the single best thing to demo:**

```bash
sudo docker exec jenkins aws sts get-caller-identity --query Arn --output text
# arn:aws:sts::094842496346:assumed-role/devops-lab-ec2-role/i-093c18367c8abae8b

sudo docker exec jenkins aws ssm get-parameter \
  --name /devops-lab/sonarqube/token --with-decryption \
  --query Parameter.Value --output text
```

A container read a secret with **zero stored credentials**. That assumed-role
ARN is the evidence.

> **Why this works at all:** containers can only reach IMDSv2 if the instance
> sets `http_put_response_hop_limit = 2`. The AWS default is 1, which stops
> metadata responses at the host and silently breaks every container that tries
> to use the instance role.

---

## 7. Phase 5 — CI/CD

### The stack

[`docker-compose/docker-compose.yml`](../docker-compose/docker-compose.yml) — four
services: Jenkins, SonarQube, Postgres, and the Flask app.

Every port is bound to `127.0.0.1`, so nothing is reachable even from inside the
VPC. Access is via SSH tunnel:

```bash
ssh -L 18080:127.0.0.1:8080 -L 19000:127.0.0.1:9000 app
```

Every JVM heap is capped (`-Xmx320m` for Jenkins, etc.) because three JVMs on
1 GB of RAM will otherwise each claim a quarter of physical memory.

### [`jenkins/Dockerfile`](../jenkins/Dockerfile) — why a custom image

Stock `jenkins/jenkins:lts` ships **neither** the docker CLI nor the AWS CLI,
and the pipeline needs both — docker to run build steps, aws to read the token
from SSM. The docker socket is mounted so build steps run as *sibling*
containers on the host daemon.

> **Be ready for the security question.** Mounting `/var/run/docker.sock` gives
> the Jenkins container effective root on the host — anyone who can run a job
> can mount `/` and escape. It is acceptable for a single-user lab; production
> would use remote agents or a rootless daemon. Saying this before you are asked
> is much stronger than being caught by it.

### [`Jenkinsfile`](../Jenkinsfile) — six stages

| Stage | What it does |
|---|---|
| Checkout | pulls the repo |
| Test | pytest + coverage inside a `python:3.12-slim` container |
| SonarQube analysis | fetches the token from SSM, runs `sonar-scanner-cli` |
| Build image | `docker build` of the Flask app |
| Deploy | `docker compose up -d --no-deps app` |
| Smoke test | polls `/health` until it answers |

Two implementation details that are pure viva gold:

**`--volumes-from jenkins` on every sibling container.** The workspace lives in
the `jenkins_home` **named volume**, so its path *on the host* is not
`$WORKSPACE`. A plain `-v $WORKSPACE:/src` would mount an **empty directory** —
silently, with no error, and the scan would analyse nothing.
`--volumes-from` gives the sibling the identical mount so the path resolves the
same in both.

**`--no-deps` on deploy.** Without it, redeploying the app would restart
Jenkins, SonarQube and Postgres — including the very Jenkins container running
the build, which would kill itself mid-pipeline.

---

## 8. Problems hit and how they were solved

This section is often worth more than the happy path. It shows diagnosis, not
just following a tutorial.

| Symptom | Root cause | Fix |
|---|---|---|
| Console "Connect" failed | EC2 Instance Connect connects *from AWS*, and its service range was not in the SG | Added the managed prefix list |
| SSH suddenly times out | ISP reassigned the public IP; SG still allowed the old one | Single-source `my_ip_cidr` variable + `terraform apply` |
| `Permission denied (publickey)` | Wrong username (`ubuntu` vs `ec2-user`) and wrong key file | Matched user to AMI, used the right key pair |
| Vault variables silently ignored | File at `group_vars/vault.yml` matches a *group* named `vault` | Moved to `group_vars/all/` |
| Root SSH still enabled after hardening | `50-cloud-init.conf` is read first and wins | Drop-in named `01-…` |
| Fail2Ban would not start | Ubuntu has no `/var/log/secure` | `backend = systemd` |
| SG change forced instance downtime | SG **descriptions are immutable**; changing one replaces the whole SG | Left the description alone |
| SonarQube reported "unhealthy" while working fine | Healthcheck used `curl`; the image does not ship curl | Switched to `wget` |
| Scanner: `Not authorized` | Scanner CLI 8 sends `sonar.token`; SonarQube **9.9** expects `sonar.login` | Used `sonar.login` |
| `terraform destroy` refused to run | The state bucket is managed by the config that stores state in it, and has `prevent_destroy` | Targeted destroy excluding backend resources |
| Browser showed nothing on `localhost:8080` | **nginx** was already bound to 8080 on the laptop, so `ssh -L` could not bind | Used port 18080 + `ExitOnForwardFailure=yes` |
| GitHub PR showed conflicts | Stale mergeability cache — the merge was clean locally in both directions | Merged main into develop and pushed |

**The single most useful diagnostic to state:**

> A **timeout** means packets are being dropped — network, security group,
> routing. **`Permission denied`** means the network is fine and the problem is
> authentication. Knowing which of the two you are looking at eliminates half
> the search space immediately.

---

## 9. Live demo script

Roughly seven minutes, in this order.

```bash
# 1. Infrastructure matches code
cd terraform && terraform plan            # "No changes"
terraform output

# 2. Access path — no direct route to the private host
ssh bastion 'hostname'
ssh app 'hostname'                        # ProxyJump through the bastion

# 3. Configuration is in place
ssh app 'sudo sshd -T | grep -E "permitrootlogin|passwordauthentication"'
ssh app 'id devops; systemctl is-active fail2ban docker'

# 4. Secrets — Vault
cd ../ansible && ansible-vault view group_vars/all/vault.yml

# 5. Secrets — SSM, with no stored credentials  ← the strongest moment
ssh app 'sudo docker exec jenkins aws sts get-caller-identity --query Arn --output text'
ssh app 'sudo docker exec jenkins aws ssm get-parameter \
  --name /devops-lab/sonarqube/token --with-decryption \
  --query Parameter.Value --output text'

# 6. The stack
ssh app 'cd /opt/devops-stack && sudo docker compose ps'

# 7. The UIs
ssh -L 18080:127.0.0.1:8080 -L 19000:127.0.0.1:9000 app
#   Jenkins   http://localhost:18080  → run the pipeline
#   SonarQube http://localhost:19000/dashboard?id=devops-lab-app
```

---

## 10. Rapid-fire answers

**Why a bastion instead of giving the app server a public IP?**
It reduces the attack surface to one hardened host with one open port from one
IP. The app server has no route from the internet at all, so there is nothing to
scan or brute-force.

**Why is Terraform state in S3 and not local?**
Local state cannot be shared, has no locking, and is lost with the laptop. S3
gives durability and versioning; DynamoDB gives a lock so two applies cannot
corrupt it.

**What does the DynamoDB table actually store?**
One item with a `LockID` key while an operation runs. Terraform writes it
conditionally — if it already exists, the second apply blocks. It is a mutex.

**Terraform vs Ansible — why both?**
Terraform is declarative provisioning of cloud resources with state tracking.
Ansible is configuration management inside the OS. Terraform knows nothing about
apt packages; Ansible cannot create a VPC.

**Is Ansible idempotent here?**
Yes. Re-running `site.yml` reports mostly `ok` and few `changed`. The tasks that
use `command` are guarded with `when:` or `changed_when:` so they do not report
false changes.

**How do you rotate the SonarQube token?**
Revoke it in SonarQube, generate a new one, `aws ssm put-parameter --overwrite`.
No redeploy, no code change — the pipeline reads it fresh on every build.

**What happens if the app server is replaced?**
Terraform recreates it, `site.yml` reconfigures it, `deploy-stack.yml`
redeploys the stack. The bastion keeps its IP via the Elastic IP. Only the app's
private IP changes, which is why dynamic inventory would be the next
improvement.

**What is not production-ready?**
Single AZ, no load balancer, no HTTPS, egress open to `0.0.0.0/0`,
`AmazonS3FullAccess` is broader than needed, the docker socket mount, and the
state backend living in the same config it serves. Each has a known fix; each
was a deliberate scope decision for a free-tier lab.

**Why t3.micro if SonarQube needs 2 GB?**
Free tier. It is under spec, which is why there is a 4 GB swap file and capped
heaps. The correct size is `t3.medium`, and `app_instance_type` exists as a
variable so it is a one-line change.
