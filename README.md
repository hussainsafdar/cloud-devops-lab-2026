# Cloud DevOps Lab — Setup Guide

A complete AWS environment provisioned with Terraform, hardened with Ansible,
and running a full CI/CD stack (Jenkins, SonarQube, Prometheus, Grafana)
behind an Nginx reverse proxy — with a Jenkins pipeline that checks out,
lints, tests, scans, builds, pushes to DockerHub, deploys, and smoke-tests a
Flask application, end to end.

See `architecture-diagram.png` for the full network/service layout,
`decision-log.md` for why each tool and pattern was chosen, and
`operations-guide.md` for day-to-day monitoring and troubleshooting.

---

## Prerequisites

- AWS account with an IAM user that has programmatic access (`aws configure`)
- Terraform >= 1.5.0
- Ansible >= 2.15
- An SSH key pair created in AWS (referenced as `key_pair_name` in
  `terraform.tfvars`)
- Docker Desktop (for local validation of the compose file, optional)
- A DockerHub account (for the image push stage)

---

## 1. Clone and configure

```bash
git clone https://github.com/<your-username>/cloud-devops-lab-2026.git
cd cloud-devops-lab-2026
```

Set your public IP and key pair name in `terraform/terraform.tfvars`:

```hcl
key_pair_name = "your-key-pair-name"
```

The `my_ip_cidr` variable lives in `terraform/variables.tf` as the single
source of truth — do **not** also set it in `.tfvars`, since a `.tfvars`
value silently overrides the variable default with no warning.

Check your current IP and update the default:

```bash
curl -s https://checkip.amazonaws.com
# edit terraform/variables.tf, set my_ip_cidr default to "<your-ip>/32"
```

## 2. Provision the infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

This creates the VPC, subnets, Internet Gateway, NAT Gateway, two EC2
instances (bastion + app server), security groups, the IAM role, and the S3 +
DynamoDB Terraform state backend.

```bash
terraform output
```

Note the `bastion_public_ip` and `app_server_private_ip` — you'll need both
next.

## 3. Configure SSH access

Add to `~/.ssh/config`:

```
Host bastion
    HostName <bastion_public_ip>
    User ubuntu
    IdentityFile ~/.ssh/<your-key>.pem
    IdentitiesOnly yes
    ForwardAgent yes
    ServerAliveInterval 30
    ServerAliveCountMax 10

Host app
    HostName <app_server_private_ip>
    User ubuntu
    IdentityFile ~/.ssh/<your-key>.pem
    IdentitiesOnly yes
    ProxyJump bastion
    ServerAliveInterval 30
    ServerAliveCountMax 10
```

The `ServerAliveInterval`/`ServerAliveCountMax` lines matter — without them,
long-idle SSH tunnels (e.g. while working in a browser UI) can silently drop.

Update `ansible/inventory.ini` with the same two IPs.

Test:
```bash
ssh bastion
ssh app
```

## 4. Harden the instances

```bash
cd ../ansible
ansible all -m ping
```

You'll need the Vault passphrase (`.vault_pass`, gitignored — set this up
yourself, it's never committed) to decrypt secrets. Then:

```bash
ansible-playbook site.yml
```

This installs Docker, Docker Compose, and Python; configures Fail2Ban;
creates the `devops` user with passwordless sudo; disables root SSH login;
and applies the vault-sourced secrets.

## 5. Populate secrets

Some values are intentionally **not** in Terraform or Ansible Vault, to keep
them out of state files and git history entirely. Set these manually via the
AWS CLI, using the app server's IAM role for read access afterward:

```bash
aws ssm put-parameter --name "/devops-lab/jenkins/admin-user" --type String --value "admin"
aws ssm put-parameter --name "/devops-lab/jenkins/admin-password" --type SecureString --value "<password>"
aws ssm put-parameter --name "/devops-lab/sonarqube/token" --type SecureString --value "<token, generated after first SonarQube login>"
aws ssm put-parameter --name "/devops-lab/dockerhub/username" --type String --value "<your dockerhub username>"
aws ssm put-parameter --name "/devops-lab/dockerhub/token" --type SecureString --value "<dockerhub access token, Read & Write scope>"
```

And in Ansible Vault (`ansible-vault edit group_vars/all/vault.yml`):
```yaml
vault_devops_password_hash: "<generate with: openssl passwd -6 'yourpassword'>"
vault_sonar_db_password: "<any strong password>"
vault_grafana_admin_password: "<any strong password>"
```

## 6. Deploy the stack

```bash
ansible-playbook deploy-stack.yml
```

This sets up swap space (required for SonarQube on a 1GB host), tunes kernel
parameters, copies all config files, builds the custom Jenkins/app images,
and starts all six containers.

## 7. Access the services

Open a tunnel:
```bash
ssh -L 8080:localhost:8080 -L 9000:localhost:9000 -L 3000:localhost:3000 -L 9090:localhost:9090 -L 8081:localhost:8081 app
```

Then in a browser:
- Jenkins — `http://localhost:8080/jenkins`
- SonarQube — `http://localhost:9000/sonar`
- Grafana — `http://localhost:3000/grafana`
- Prometheus — `http://localhost:9090`
- Everything via the reverse proxy — `http://localhost:8081/jenkins/`, `/sonar/`, `/grafana/`

Jenkins's initial admin password:
```bash
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

## 8. Set up the Jenkins pipeline

Create a new **Pipeline** job in Jenkins, pointed at:
- Definition: Pipeline script from SCM
- SCM: Git, your repo URL
- Branch: `*/main`
- Script Path: `Jenkinsfile`

Click **Build Now**. The pipeline checks out, lints (ruff), tests (pytest),
scans (SonarQube), builds a Docker image, pushes it to DockerHub, deploys it,
and runs a smoke test.

---

## Repository layout

```
cloud-devops-lab-2026/
├── terraform/              VPC, subnets, EC2, IAM, security groups, state backend
├── ansible/
│   ├── site.yml             base hardening (Docker, Fail2Ban, devops user)
│   ├── deploy-stack.yml     swap setup, config copy, stack deploy
│   └── group_vars/all/
│       ├── vars.yml         secret pointers (plaintext, safe to commit)
│       └── vault.yml        encrypted secrets
├── app/                     Flask application + tests
├── jenkins/                 Custom Jenkins Dockerfile (docker CLI, aws CLI, prometheus plugin)
├── docker-compose/
│   ├── docker-compose.yml   the six-service stack
│   ├── prometheus/          scrape config + alert rules
│   ├── grafana/              datasource provisioning
│   └── nginx/                reverse proxy config
├── Jenkinsfile              the 8-stage CI/CD pipeline
└── docs/                    this file, architecture diagram, ops guide, decision log
```

## Rebuilding after a destroy

If you tear down infrastructure (`terraform destroy`) and rebuild it, IPs
change. Refresh `~/.ssh/config` and `ansible/inventory.ini` from
`terraform output`, then repeat steps 3–6. The Terraform state backend (S3 +
DynamoDB) survives destroys of the rest of the infrastructure, since it's
protected by `lifecycle.prevent_destroy` — a targeted destroy
(`-target=...` for everything except the backend resources) is the safe way
to tear down without losing state tracking.
