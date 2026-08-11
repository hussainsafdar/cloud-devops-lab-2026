// CI/CD pipeline for the Flask app: test -> analyse -> build -> deploy.
//
// Design notes that matter if you change anything here:
//
//  * Build steps run as SIBLING containers on the host daemon, via the mounted
//    docker socket. There is no docker daemon inside Jenkins.
//
//  * Every sibling container uses `--volumes-from jenkins`. The workspace lives
//    in the jenkins_home named volume, so its path on the HOST is not
//    $WORKSPACE. A plain `-v $WORKSPACE:/src` would mount an empty directory -
//    silently, with no error. --volumes-from gives the sibling the identical
//    mount, so $WORKSPACE resolves the same in both.
//
//  * The SonarQube token is read from SSM Parameter Store at build time using
//    the EC2 instance role. It is never stored in Jenkins credentials, in this
//    file, or in the image.

pipeline {
    agent any

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        // This host has 1 GB of RAM; a wedged build must not hold it forever.
        timeout(time: 30, unit: 'MINUTES')
    }

    environment {
        AWS_DEFAULT_REGION = 'us-east-1'
        SONAR_HOST         = 'http://sonarqube:9000'
        STACK_NETWORK      = 'devops-stack_default'
        IMAGE_NAME         = 'devops-lab-app'
        SSM_SONAR_TOKEN    = '/devops-lab/sonarqube/token'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
                sh 'git --no-pager log -1 --oneline'
            }
        }

        stage('Test') {
            steps {
                sh '''
                    set -eu
                    docker run --rm \
                      --volumes-from jenkins \
                      -w "$WORKSPACE/app" \
                      python:3.12-slim \
                      sh -c "pip install --quiet --no-cache-dir -r requirements.txt -r requirements-dev.txt \
                             && python -m pytest --cov=. --cov-report=xml --junitxml=junit.xml"
                '''
            }
            post {
                always {
                    junit testResults: 'app/junit.xml', allowEmptyResults: true
                }
            }
        }

        stage('SonarQube analysis') {
            steps {
                // The token is fetched, used, and discarded inside one shell.
                // set +x around it keeps it out of the console log even when
                // the shell is tracing.
                sh '''
                    set -eu
                    set +x
                    SONAR_TOKEN=$(aws ssm get-parameter \
                        --name "$SSM_SONAR_TOKEN" \
                        --with-decryption \
                        --query Parameter.Value \
                        --output text)

                    docker run --rm \
                      --volumes-from jenkins \
                      --network "$STACK_NETWORK" \
                      -w "$WORKSPACE/app" \
                      sonarsource/sonar-scanner-cli \
                      -Dsonar.host.url="$SONAR_HOST" \
                      -Dsonar.login="$SONAR_TOKEN"
                '''
            }
        }

        stage('Build image') {
            steps {
                sh '''
                    set -eu
                    docker build \
                      -t "$IMAGE_NAME:$BUILD_NUMBER" \
                      -t "$IMAGE_NAME:local" \
                      "$WORKSPACE/app"
                '''
            }
        }

        stage('Deploy') {
            steps {
                // --no-deps so a redeploy of the app never restarts Jenkins,
                // SonarQube or the database underneath itself.
                sh '''
                    set -eu
                    docker compose -f /opt/devops-stack/docker-compose.yml up -d --no-deps app
                    docker compose -f /opt/devops-stack/docker-compose.yml ps app
                '''
            }
        }

        stage('Smoke test') {
            steps {
                sh '''
                    set -eu
                    for i in $(seq 1 20); do
                      if docker run --rm --network "$STACK_NETWORK" curlimages/curl:latest \
                           -fsS http://app:5000/health >/dev/null 2>&1; then
                        echo "health check passed"
                        exit 0
                      fi
                      sleep 3
                    done
                    echo "app did not become healthy in 60s"
                    exit 1
                '''
            }
        }
    }

    post {
        always {
            // Old images accumulate fast on a 30 GB disk with three JVM images
            // already present.
            sh 'docker image prune -f --filter "until=168h" || true'
        }
        success {
            echo "Build ${env.BUILD_NUMBER} deployed. Sonar: ${env.SONAR_HOST}/dashboard?id=devops-lab-app"
        }
    }
}
