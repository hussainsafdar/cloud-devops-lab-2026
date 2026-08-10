# Cloud DevOps Lab 2026 — Project Overview

Reference for the Terraform + Ansible AWS lab: what exists, why it was built that way,
and how to operate it.

**Last updated:** 2026-08-11 · **AWS account:** `094842496346` · **Region:** `us-east-1`

---

## Status at a glance

| # | Requirement | Status |
|---|---|---|
| **Section 2 — Infrastructure as Code** | | |
| 1 | VPC with a CIDR block | ✅ |
| 2 | Public subnet (bastion) | ✅ |
| 3 | Private subnet (app server) | ✅ |
| 4 | Internet Gateway + NAT Gateway | ✅ |
| 5 | Two EC2 instances | ✅ |
| 6 | Terraform state in S3 + DynamoDB locking | ✅ |
| **Section 3 — Security & Automation** | | |
| 7 | Security Groups, ports restricted | ✅ |
| 8 | IAM role for EC2 (S3 + CloudWatch) | ✅ |
| 9 | Ansible installs Docker, Compose, Python | ✅ |
| 10 | Fail2Ban or UFW | ✅ |
| 11 | devops user + root SSH disabled | ✅ |
| 12 | Ansible Vault for secrets | ✅ |
| 13 | Jenkins credentials in SSM Parameter Store | ⚠️ **partial** |

**12 of 13 complete.** See [Remaining work](#remaining-work) for what's left on #13.

---

## Architecture

```
                          Internet
                              │
                    ┌─────────┴─────────┐
                    │ Internet Gateway  │
                    └─────────┬─────────┘
   VPC 10.0.0.0/16            │
   ┌───────────────────────────────────────────────────┐
   │  Public subnet 10.0.1.0/24                        │
   │  ┌─────────────────┐      ┌──────────────┐        │
   │  │ bastion         │      │ NAT Gateway  │        │
   │  │ Elastic IP      │      │ + Elastic IP │        │
   │  │ Ubuntu 24.04    │      └──────┬───────┘        │
   │  └────────┬────────┘             │                │
   │           │ SSH (22)             │ outbound only  │
   │  ┌────────▼─────────────────────▼────────────┐    │
   │  │  Private subnet 10.0.2.0/24               │    │
   │  │  ┌─────────────────┐                      │    │
   │  │  │ app server      │  no public IP        │    │
   │  │  │ Ubuntu 24.04    │  Docker + Compose    │    │
   │  │  └─────────────────┘                      │    │
   │  └───────────────────────────────────────────┘    │
   └───────────────────────────────────────────────────┘
```

The app server can reach the internet (for `apt`) through the NAT Gateway, but nothing
on the internet can reach it. All administrative access goes through the bastion.

---

## Section 2 — Infrastructure as Code

### 1. VPC — [`terraform/vpc.tf`](../terraform/vpc.tf)

CIDR `10.0.0.0/16`, with `enable_dns_support` and `enable_dns_hostnames` both on.
DNS hostnames are what let instances resolve `*.ec2.internal` names and reach AWS
service endpoints — without them, the SSM agent and NAT-bound traffic misbehave in
ways that are hard to diagnose.

### 2 & 3. Subnets

| Subnet | CIDR | Purpose | Public IPs |
|---|---|---|---|
| public | `10.0.1.0/24` | bastion | `map_public_ip_on_launch = true` |
| private | `10.0.2.0/24` | app server | none |

Both in `us-east-1a`. A second AZ would be needed for real high availability; a single
AZ is fine for a lab and keeps the NAT Gateway cost to one.

### 4. Internet Gateway + NAT Gateway

Two route tables, which is the part that actually creates the public/private split:

- **Public RT** → `0.0.0.0/0` via the Internet Gateway. Attached to the public subnet.
- **Private RT** → `0.0.0.0/0` via the NAT Gateway. Attached to the private subnet.

The NAT Gateway lives *in the public subnet* and holds its own Elastic IP. This gives
the app server outbound internet (package installs) with no inbound path — the
defining property of a private subnet.

> A subnet is not "private" because of a setting. It's private because its route table
> has no path to an Internet Gateway.

### 5. EC2 instances — [`terraform/ec2.tf`](../terraform/ec2.tf)

Both run **Ubuntu 24.04 LTS**, from Canonical's official AMI:

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical — always pin the owner
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}
```

Pinning `owners` matters: without it, a lookalike AMI name published by any account
could be selected. That is a real supply-chain risk, not a theoretical one.

**`user_data` bootstrap** installs `ec2-instance-connect` and enables the SSM agent.
Canonical's images generally ship both, but console access and break-glass access
depend on them — worth guaranteeing rather than assuming.

**The bastion has an Elastic IP.** Without it, every stop/start or instance replacement
changed the public IP and silently broke the Ansible inventory. An EIP attached to a
running instance is free.

### 6. Remote state — [`terraform/backend.tf`](../terraform/backend.tf)

| Setting | Value |
|---|---|
| bucket | `cloud-devops-lab-2026-tfstate-hussain` |
| DynamoDB table | `terraform-state-lock` |
| encryption | enabled |

S3 holds the state; DynamoDB provides a lock so two people can't apply at once and
corrupt it. The bucket also has versioning and public-access-block enabled
([`terraform/dynamodb.tf`](../terraform/dynamodb.tf)).

> **Deprecation note:** Terraform now warns that `dynamodb_table` is deprecated in
> favour of `use_lockfile`. It still works. Migrating is optional cleanup.

---

## Section 3 — Security & Automation

### 7. Security Groups — [`terraform/security_groups.tf`](../terraform/security_groups.tf)

**bastion-sg**

| Port | Source | Why |
|---|---|---|
| 22 | your IP `/32` | SSH from your workstation only |
| 22 | prefix list `com.amazonaws.us-east-1.ec2-instance-connect` | the console "Connect" button |

**app-sg**

| Port | Source | Why |
|---|---|---|
| 22 | **`bastion-sg`** | only the bastion may SSH in |
| 80, 443 | your IP `/32` | app traffic |

The SSH rule on `app-sg` references a **security group, not a CIDR**. This is the
important pattern: it stays correct when instance IPs change, and it cannot be
satisfied by anything other than an instance actually in `bastion-sg`.

The EC2 Instance Connect rule uses a **managed prefix list** rather than a hardcoded
`18.206.107.24/29`, so it keeps working if AWS changes the service range.

### 8. IAM role — [`terraform/iam.tf`](../terraform/iam.tf)

Role `devops-lab-ec2-role`, exposed to instances via instance profile
`devops-lab-ec2-profile`:

| Policy | Purpose |
|---|---|
| `AmazonS3FullAccess` | S3 access (checklist requirement) |
| `CloudWatchAgentServerPolicy` | CloudWatch metrics/logs |
| `AmazonSSMManagedInstanceCore` | Session Manager access |

The instance profile is what makes credential-free AWS access possible: the instance
gets **auto-rotating temporary credentials** from the metadata service, so no access
keys are ever stored on disk.

> ⚠️ `AmazonS3FullAccess` grants read/write/**delete** on every bucket in the account,
> including the Terraform state bucket. It satisfies the checklist, but an inline
> policy scoped to specific buckets would be the least-privilege version.

### 9–11. Ansible configuration — [`ansible/site.yml`](../ansible/site.yml)

Verified installed on both hosts:

| Component | Version |
|---|---|
| Docker | 29.1.3 |
| Docker Compose | v5.4.0 |
| Python | 3.12 |
| Fail2Ban | active, `sshd` jail running |

**Fail2Ban uses `backend = systemd`.** Ubuntu has no `/var/log/secure`, and minimal
images may not ship rsyslog at all, so the jail reads the journal directly.

**devops user:** `uid=1001`, in groups `sudo` and `docker`, passwordless sudo via
`/etc/sudoers.d/devops`, SSH key installed, password hash sourced from the vault.

**Root SSH disabled** via a drop-in at `/etc/ssh/sshd_config.d/01-devops-hardening.conf`:

```
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
```

> **Why a drop-in and not `lineinfile` on `sshd_config`:** Ubuntu's main config
> `Include`s `sshd_config.d/*.conf` at the very top, and sshd keeps the **first**
> value it sees for each keyword. Editing the main file is silently overridden by
> cloud-init's `50-cloud-init.conf`. The `01-` prefix sorts ahead of it, so these
> settings win. Confirmed with `sshd -T`.

### 12. Ansible Vault

Layout:

```
ansible/group_vars/all/
├── vars.yml     # plaintext, committed — pointers only
└── vault.yml    # encrypted, committed — real values
```

`vars.yml` holds only indirection:

```yaml
devops_password_hash: "{{ vault_devops_password_hash }}"
```

The real value lives in `vault.yml` under the `vault_`-prefixed name. Two reasons for
the split: you can see *which* secrets exist without decrypting, and playbooks
reference the friendly name so rotating a secret never touches task code.

The consuming task carries `no_log: true` — without it Ansible prints the hash in
`-v` and `--diff` output, defeating the encryption.

> **Critical gotcha:** the vault file *must* be at `group_vars/all/vault.yml`.
> A file at `group_vars/vault.yml` is matched against a **group named `vault`**,
> which doesn't exist — so Ansible loads nothing and reports no error. It fails
> completely silently. The directory form (`group_vars/all/`) loads every file
> inside it for all hosts.

Encryption: AES-256, key derived from your passphrase with PBKDF2 (10,000 rounds,
32-byte salt), HMAC for tamper detection. Decrypted in memory at runtime only.
The passphrase lives in `ansible/.vault_pass`, which is gitignored.

### 13. SSM Parameter Store — ⚠️ partial

**Done:** `/devops-lab/jenkins/admin-password` exists as a `SecureString`, encrypted
at rest with the account's `aws/ssm` KMS key. Nothing is hardcoded anywhere.

**Not done:** the EC2 role has no SSM read permission, so the instance **cannot
retrieve it**. See [Remaining work](#remaining-work).

#### Why credentials belong in SSM rather than a Jenkinsfile

```groovy
// The anti-pattern this exercise targets:
sh 'docker login -u hassan -p MyPassword123'   // now in git history forever
```

SSM gives rotation without redeployment, CloudTrail audit logs of every read, and —
combined with the instance profile — retrieval with **zero stored credentials**.

#### Vault vs SSM — they solve different problems

| | Ansible Vault | SSM Parameter Store |
|---|---|---|
| Secret needed | at **config time**, by the playbook | at **runtime**, by the running app |
| Decrypted by | your laptop during `ansible-playbook` | the EC2 instance, via its IAM role |
| Stored in | your git repo (encrypted) | AWS, never in git |
| Unlocked by | your passphrase | the instance profile |

---

## Operating the lab

### Connect

```bash
ssh bastion          # via ~/.ssh/config
ssh app              # ProxyJump through bastion — key never leaves your laptop

aws ssm start-session --target <instance-id>    # break-glass, no SSH or SG needed
```

### Run Ansible

```bash
cd ansible
ansible all -m ping                       # test connectivity first
ansible-playbook site.yml                 # both hosts
ansible-playbook site.yml --limit app     # app only
ansible-playbook site.yml --check --diff  # dry run
```

### Terraform

```bash
cd terraform
terraform plan
terraform apply
terraform output
```

### Vault

```bash
ansible-vault view group_vars/all/vault.yml
ansible-vault edit group_vars/all/vault.yml
```

### Reach a service on the private app server

```bash
ssh -L 8080:localhost:8080 app     # then browse http://localhost:8080
```

An SSH tunnel is the right way to reach admin UIs on a private instance — no public
listener, no extra security group rule, already encrypted.

---

## Gotchas worth remembering

**Your ISP IP changes.** The single most frequent breakage in this lab. Symptom: SSH
**times out** (rather than being refused). Fix:

```bash
curl -s https://checkip.amazonaws.com          # get current IP
# update my_ip_cidr in terraform/terraform.tfvars, then:
terraform apply
```

A timeout means the packets are being dropped at the security group. `Permission
denied (publickey)` means the opposite — the network is fine and the problem is
authentication (wrong user or wrong key).

**Login user follows the AMI.** Ubuntu → `ubuntu`. Amazon Linux → `ec2-user`. A wrong
username produces `Permission denied (publickey)` with no hint that the user is the
problem, because sshd deliberately doesn't reveal which part failed.

**Instance replacement changes the app's private IP.** The bastion is protected by its
Elastic IP, but the app server is not. After any replacement, refresh
`ansible/inventory.ini` from `terraform output app_server_private_ip`. Dynamic
inventory (`amazon.aws.aws_ec2` plugin) would eliminate this entirely.

**Security group descriptions are immutable.** Changing one forces a *replacement* of
the SG, which fails while live instances depend on it. Leave descriptions alone.

**zsh doesn't treat `#` as a comment** in interactive shells (bash does). Pasting a
command with a trailing comment passes it as arguments. Run `setopt
interactivecomments` if you want bash behaviour.

**The AWS CLI is not preinstalled on Ubuntu AMIs** (it is on Amazon Linux):

```bash
sudo snap install aws-cli --classic
```

---

## Remaining work

### Finish #13 — grant the role SSM read access

Console: **IAM → Roles → `devops-lab-ec2-role` → Add permissions → Create inline
policy → JSON**, named `jenkins-ssm-read`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadJenkinsParameters",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"],
      "Resource": "arn:aws:ssm:us-east-1:094842496346:parameter/devops-lab/jenkins/*"
    },
    {
      "Sid": "DecryptSecureStrings",
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "*",
      "Condition": {
        "StringEquals": { "kms:ViaService": "ssm.us-east-1.amazonaws.com" }
      }
    }
  ]
}
```

The second statement is **not optional**. SecureString values are returned still
encrypted unless the caller can use the KMS key, so `--with-decryption` fails with
`AccessDenied` without it. Note that IAM does not accept KMS *alias* ARNs in
`Resource` — the `kms:ViaService` condition is the correct way to scope it, and it
restricts this key's use to requests arriving through SSM.

Verify from the app server — this is the proof the exercise is really asking for,
since it authenticates with no stored credentials:

```bash
ssh app
sudo snap install aws-cli --classic
aws ssm get-parameter --name /devops-lab/jenkins/admin-password \
  --with-decryption --region us-east-1 --query Parameter.Value --output text
```

### Optional improvements

| Item | Why |
|---|---|
| Scope down `AmazonS3FullAccess` | Currently allows deleting the Terraform state bucket |
| Dynamic inventory (`aws_ec2` plugin) | Ends the stale-IP problem permanently |
| Migrate `dynamodb_table` → `use_lockfile` | Silences the deprecation warning |
| Second AZ | Real high availability |
| Add the remaining SSM parameters | `admin-user`, `api-token` — only `admin-password` exists |

---

## Repository layout

```
cloud-devops-lab-2026/
├── terraform/
│   ├── vpc.tf                  VPC, subnets, IGW, NAT, route tables
│   ├── ec2.tf                  Ubuntu AMI lookup, both instances, bastion EIP
│   ├── security_groups.tf      bastion-sg, app-sg
│   ├── iam.tf                  EC2 role, policy attachments, instance profile
│   ├── backend.tf              S3 + DynamoDB state
│   ├── dynamodb.tf             state bucket and lock table resources
│   ├── variables.tf            inputs (no secrets)
│   ├── outputs.tf              IPs, instance IDs, ready-made SSH command
│   └── terraform.tfvars        your IP + key pair name (gitignored)
├── ansible/
│   ├── ansible.cfg             inventory path, remote_user, vault password file
│   ├── inventory.ini           hosts + ProxyCommand for the private host
│   ├── site.yml                the full configuration playbook
│   ├── .vault_pass             vault passphrase (gitignored)
│   └── group_vars/all/
│       ├── vars.yml            plaintext vars + secret pointers
│       └── vault.yml           encrypted secrets
└── docs/
    └── PROJECT-OVERVIEW.md     this file
```
