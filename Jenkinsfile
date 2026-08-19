pipeline {
    agent any

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 30, unit: 'MINUTES')
    }

    environment {
        AWS_DEFAULT_REGION = 'us-east-1'
        SONAR_HOST         = 'http://sonarqube:9000/sonar'
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

        stage('Lint') {
            steps {
                sh '''
                    set -eu
                    docker run --rm \
                      --volumes-from jenkins \
                      -w "$WORKSPACE/app" \
                      python:3.12-slim \
                      sh -c "pip install --quiet --no-cache-dir ruff==0.8.4 \
                             && ruff check ."
                '''
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

        stage('Push image') {
            steps {
                sh '''
                    set -eu
                    set +x
                    DOCKERHUB_USER=$(aws ssm get-parameter \
                        --name "/devops-lab/dockerhub/username" \
                        --query Parameter.Value \
                        --output text)
                    DOCKERHUB_TOKEN=$(aws ssm get-parameter \
                        --name "/devops-lab/dockerhub/token" \
                        --with-decryption \
                        --query Parameter.Value \
                        --output text)

                    echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USER" --password-stdin

                    docker tag "$IMAGE_NAME:$BUILD_NUMBER" "$DOCKERHUB_USER/$IMAGE_NAME:$BUILD_NUMBER"
                    docker tag "$IMAGE_NAME:$BUILD_NUMBER" "$DOCKERHUB_USER/$IMAGE_NAME:latest"

                    docker push "$DOCKERHUB_USER/$IMAGE_NAME:$BUILD_NUMBER"
                    docker push "$DOCKERHUB_USER/$IMAGE_NAME:latest"

                    docker logout
                '''
            }
        }

        stage('Deploy') {
            steps {
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
            sh 'docker image prune -f --filter "until=168h" || true'
        }
        success {
            echo "Build ${env.BUILD_NUMBER} deployed. Sonar: ${env.SONAR_HOST}/dashboard?id=devops-lab-app"
        }
    }
}