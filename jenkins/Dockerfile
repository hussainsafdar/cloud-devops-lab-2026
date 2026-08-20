# Jenkins controller with the two CLIs the pipeline needs.
#
# jenkins/jenkins:lts ships neither, and the pipeline cannot work without them:
#   - docker CLI : runs pytest / sonar-scanner as sibling containers on the
#                  host daemon (client only - no daemon inside this image)
#   - aws CLI    : reads the SonarQube token from SSM Parameter Store at build
#                  time, so no secret is stored in Jenkins or in the Jenkinsfile
FROM jenkins/jenkins:lts

USER root

# Docker CLI from Docker's own apt repo (Debian bookworm base).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg unzip \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2. Credentials are never baked in - the container reaches the EC2
# instance metadata service and assumes the instance role. That works only
# because the instance sets http_put_response_hop_limit = 2; the AWS default of
# 1 stops IMDSv2 responses from ever reaching a container.
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip \
 && unzip -q /tmp/awscli.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscli.zip

# Prometheus metrics plugin, so Prometheus can scrape Jenkins build/queue
# metrics directly rather than needing a separate exporter sidecar.
USER jenkins
RUN jenkins-plugin-cli --plugins prometheus
