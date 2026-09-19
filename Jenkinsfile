pipeline {
    agent any 
    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 30, unit: 'MINUTES')
    }

    environment {
        MY_CREDS = credentials('container-registry')
        APP_NAME = 'django-app'
        APP_IMAGE = 'docker.io/subbu098/django'
        REGISTRY_HOST = 'docker.io'
        DEPLOY_HOST = '13.221.253.21'
        DEPLOY_USER = 'deploy'
    }

    stages {
        stage('Pre-Clean Workspace') {
            steps {
                // Wipes workspace before pulling new code
                cleanWs()
            }
        }
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.IMAGE_TAG = sh(
                        script: 'git rev-parse --short=12 HEAD',
                        returnStdout: true
                    ).trim()
                }
            }
        }

        stage('Build test image') {
            steps {
                sh '''
                    set -eux
                    docker build \
                        --target test \
                        --tag "${APP_NAME}-test:${IMAGE_TAG}" \
                        .
                '''
            }
        }

        stage('Test and validate') {
            steps {
                sh '''
                    set -eux
                    docker run --rm "${APP_NAME}-test:${IMAGE_TAG}" \
                        python manage.py test
                    docker run --rm "${APP_NAME}-test:${IMAGE_TAG}" \
                        python manage.py check
                    docker run --rm "${APP_NAME}-test:${IMAGE_TAG}" \
                        python manage.py makemigrations --check --dry-run
                '''
            }
        }

        stage('Build production image') {
            steps {
                sh '''
                    set -eux
                    docker build \
                        --target runtime \
                        --tag "${APP_IMAGE}:${IMAGE_TAG}" \
                        .
                '''
            }
        }

        stage('Push image') {
            steps {
                    sh '''
                        set +x
                        printf '%s' "$REGISTRY_TOKEN" | \
                            docker login "$REGISTRY_HOST" \
                                --username "$MY_CREDS_USR" \
                                --password "$MY_CREDS_PSW" \
                        set -x
                        docker push "${APP_IMAGE}:${IMAGE_TAG}"
                        docker logout "$REGISTRY_HOST"
                    '''
            }
        }

        stage('Deploy production') {
            when {
                branch 'main'
            }
            steps {
                sshagent(credentials: ['django-app-ssh']) {
                    sh '''
                        set -eux
                        scp deploy/compose.yaml \
                            "${DEPLOY_USER}@${DEPLOY_HOST}:/tmp/django-compose-${BUILD_NUMBER}.yaml"

                        ssh "${DEPLOY_USER}@${DEPLOY_HOST}" \
                            "sudo /usr/local/bin/deploy-django \
                                '${APP_IMAGE}' \
                                '${IMAGE_TAG}' \
                                '/tmp/django-compose-${BUILD_NUMBER}.yaml'"
                    '''
                }
            }
        }
    }

    post {
        always {
            sh '''
                docker image rm "${APP_NAME}-test:${IMAGE_TAG}" 2>/dev/null || true
                docker image rm "${APP_IMAGE}:${IMAGE_TAG}" 2>/dev/null || true
            '''
            cleanWs()
        }
        success {
            echo "Successfully deployed ${APP_IMAGE}:${IMAGE_TAG}"
        }
        failure {
            echo 'Pipeline failed. Review the stage logs before retrying.'
        }
    }
}

