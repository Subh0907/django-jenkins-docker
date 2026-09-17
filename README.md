# Django + PostgreSQL + Docker + Jenkins deployment kit

This repository is a complete small Django application and a production-oriented
deployment example. Jenkins builds and tests an immutable container image, pushes
it to a registry, and deploys it over SSH to a second server. The application
server runs Django and PostgreSQL as separate Docker Compose services. Host Nginx
terminates HTTPS and proxies only to Django's loopback-bound port.

## Architecture

```text
GitHub -> Jenkins -> container registry -> application server
                                             |-- Nginx :80/:443
                                             |-- Django/Gunicorn container :8000
                                             `-- PostgreSQL container :5432 (internal only)
```

The database is never packaged in the application image. PostgreSQL stores its
data in the named `postgres_data` volume, so replacing the Django or PostgreSQL
container does not delete the database.

## Assumptions

- Jenkins server: Ubuntu 24.04, Jenkins already installed, a trusted Jenkins
  agent labeled `docker`, and Docker available to that agent.
- Application server: Ubuntu 24.04 with a public IP and at least 2 GB RAM.
- Source: GitHub repository with `main` as the production branch.
- Registry: GHCR in the examples. Docker Hub or another OCI registry also works.
- DNS: `app.example.com` points to the application server.
- Only trusted repository maintainers can modify the Jenkinsfile. Docker socket
  access is effectively root-level access to the Jenkins host.

Replace every value beginning with `REPLACE_` and every occurrence of
`app.example.com` before production use.

## Included files

```text
.
├── Dockerfile
├── Jenkinsfile
├── compose.yaml                 # local/manual equivalent
├── .dockerignore
├── .env.example
├── requirements.txt
├── manage.py
├── config/                      # Django project
├── core/                        # sample database-backed Django app
└── deploy/
    ├── compose.yaml             # production Compose definition
    ├── nginx/django-app.conf
    ├── scripts/
    │   ├── bootstrap-app-server.sh
    │   ├── deploy-django
    │   └── backup-django-db
    └── systemd/
        ├── django-db-backup.service
        └── django-db-backup.timer
```

## 1. Test the project locally

Create a Python environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python manage.py migrate
python manage.py test
python manage.py runserver
```

Open `http://127.0.0.1:8000`. Local development uses SQLite when the PostgreSQL
environment variables are absent. Production uses PostgreSQL.

Test the container build:

```bash
docker build --target test --tag django-app:test .
docker run --rm django-app:test python manage.py test
docker build --target runtime --tag django-app:local .
```

## 2. Create and push the GitHub repository

Create an empty GitHub repository, then from this directory run:

```bash
git init
git add .
git commit -m "Initial Django application and deployment pipeline"
git branch -M main
git remote add origin git@github.com:YOUR_ORGANIZATION/YOUR_REPOSITORY.git
git push -u origin main
```

Confirm `.env` is ignored and was not committed:

```bash
git status --ignored
git ls-files .env
```

The second command must return no output.

## 3. Create the container registry repository

For GHCR, the image name has this form:

```text
ghcr.io/YOUR_ORGANIZATION/django-app
```

Create two credentials:

1. A Jenkins credential allowed to push images.
2. A separate application-server credential allowed only to pull images.

Do not reuse a personal administrator token when a restricted machine or app
credential is available. For private GHCR packages, ensure the token and package
permissions allow the necessary repository and package access.

## 4. Prepare the application server

Copy or clone this repository onto the application server once, then run:

```bash
sudo bash deploy/scripts/bootstrap-app-server.sh
```

The script:

- installs Docker Engine, Compose, Nginx, and Certbot;
- creates a non-root `deploy` account;
- creates `/opt/django-app` and `/var/backups/django-app`;
- installs the root-owned deployment and backup scripts;
- installs a restricted sudo rule for the deployment script; and
- enables the daily database backup timer.

Review the script before running it. It is intentionally limited to Ubuntu.

### Configure production secrets

Generate secrets on the application server:

```bash
openssl rand -base64 48
openssl rand -base64 36
```

Edit the protected environment file:

```bash
sudoedit /opt/django-app/.env
```

Example:

```dotenv
APP_IMAGE=ghcr.io/YOUR_ORGANIZATION/django-app
APP_VERSION=initial

POSTGRES_DB=django_app
POSTGRES_USER=django_app
POSTGRES_PASSWORD=GENERATED_DATABASE_PASSWORD
DB_HOST=db
DB_PORT=5432
DB_CONN_MAX_AGE=60

DJANGO_SECRET_KEY=GENERATED_DJANGO_SECRET
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=app.example.com,127.0.0.1,localhost
DJANGO_CSRF_TRUSTED_ORIGINS=https://app.example.com
DJANGO_TIME_ZONE=UTC
```

Keep values on one line. If a value contains shell metacharacters, use a
shell-compatible quoted value because the backup script reads this protected
file. Keep its permissions at `0640`, owned by `root:docker`:

```bash
sudo chown root:docker /opt/django-app/.env
sudo chmod 640 /opt/django-app/.env
```

PostgreSQL consumes its initialization variables only when the data volume is
empty. Changing `POSTGRES_USER`, `POSTGRES_PASSWORD`, or `POSTGRES_DB` later does
not modify an already-initialized database automatically.

### Authenticate the application server to the registry

The deployment script runs as root, so save the read-only registry login for
root's Docker client:

```bash
printf '%s' 'READ_ONLY_REGISTRY_TOKEN' | \
  sudo docker login ghcr.io --username YOUR_REGISTRY_USER --password-stdin
```

### Configure SSH for Jenkins

Generate a dedicated keypair in a secure administrative environment:

```bash
ssh-keygen -t ed25519 -f jenkins-django-deploy -C jenkins-django-deploy
```

Install only the public key on the application server:

```bash
sudo install -d -o deploy -g deploy -m 0700 /home/deploy/.ssh
sudo sh -c 'cat jenkins-django-deploy.pub >> /home/deploy/.ssh/authorized_keys'
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
```

Store the private key in Jenkins credentials; do not copy it into the repository.
Test the login before configuring the pipeline:

```bash
ssh -i jenkins-django-deploy deploy@APP_SERVER_IP true
```

### Configure Nginx

Change `app.example.com` in `deploy/nginx/django-app.conf`, then install it:

```bash
sudo install -o root -g root -m 0644 \
  deploy/nginx/django-app.conf \
  /etc/nginx/sites-available/django-app

sudo ln -sfn \
  /etc/nginx/sites-available/django-app \
  /etc/nginx/sites-enabled/django-app

sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```

Do this before requesting a certificate, and make sure DNS already points to the
application server:

```bash
sudo certbot --nginx -d app.example.com
sudo certbot renew --dry-run
```

### Configure the firewall

If UFW is your firewall and SSH uses the default OpenSSH profile:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw enable
sudo ufw status
```

Confirm SSH access in a second terminal before closing the first session. Do not
open ports `5432`, `8000`, or Jenkins to the public internet. Docker publishes
the application only on `127.0.0.1:8000`; PostgreSQL is not published at all.

## 5. Configure Jenkins

### Required capabilities

The agent labeled `docker` must be able to run:

```bash
docker version
docker build --help
git --version
ssh -V
command -v scp
```

The pipeline uses Jenkins Pipeline, Git, Credentials Binding, SSH Agent,
Timestamper, and Workspace Cleanup functionality. Install the corresponding
plugins if they are not already present, then restart Jenkins safely if required.

If Jenkins itself runs in a container, use a dedicated, trusted build agent with
Docker access. Mounting `/var/run/docker.sock` into a container grants that
container root-equivalent control of the Docker host; do not allow untrusted pull
requests to execute this pipeline.

### Add Jenkins credentials

In **Manage Jenkins -> Credentials**, add:

| Credential ID | Type | Purpose |
|---|---|---|
| `container-registry` | Username with password/token | Push the built image |
| `django-app-ssh` | SSH username with private key | Connect as `deploy` |
| Optional Git credential | SSH key or token | Clone a private repository |

Use the exact IDs above or update the Jenkinsfile.

### Configure SSH host verification

Add the application server's verified SSH host key to the Jenkins agent user's
`known_hosts`. Obtain and verify its fingerprint through a trusted channel:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keyscan -H APP_SERVER_IP >> ~/.ssh/known_hosts
chmod 600 ~/.ssh/known_hosts
```

Do not add `StrictHostKeyChecking=no` to the pipeline.

### Update the Jenkinsfile

Replace these values:

```groovy
APP_IMAGE = 'ghcr.io/YOUR_ORGANIZATION/django-app'
DEPLOY_HOST = 'APP_SERVER_IP'
```

Change `REGISTRY_HOST` if you are not using GHCR. Keep immutable Git commit tags;
do not deploy only `latest`.

### Create the Jenkins job

Use a Multibranch Pipeline so Jenkins exposes the current branch name to the
`when { branch 'main' }` rules.

1. Select **New Item -> Multibranch Pipeline**.
2. Add the GitHub repository as the branch source.
3. Select the repository credential if it is private.
4. Set the script path to `Jenkinsfile`.
5. Save and run **Scan Multibranch Pipeline Now**.

Configure a GitHub webhook to the Jenkins GitHub webhook endpoint if you want
push-triggered builds. Restrict the webhook endpoint appropriately and use a
webhook secret where the installed integration supports it.

## 6. Run the first deployment

Push a commit to `main`, or select **Build Now** for the `main` branch job.

The pipeline performs these steps:

1. checks out the exact Git commit;
2. builds the Docker test target;
3. runs tests, Django checks, and migration drift checks;
4. builds the non-root production image;
5. pushes a Git-commit-tagged image;
6. copies the production Compose file to the application server;
7. instructs the root-owned deployment script to pull that image;
8. starts PostgreSQL and creates a pre-migration database backup;
9. runs Django migrations in a temporary container;
10. replaces the web container and verifies `/health/`; and
11. restores the previous image configuration if the health check fails.

Migration rollback is not automatic. Every production migration should remain
compatible with the previous application version until the deployment is known
to be healthy.

## 7. Verify production

On the application server:

```bash
cd /opt/django-app
sudo docker compose --env-file .env ps
sudo docker compose --env-file .env logs --tail=100 web
sudo docker compose --env-file .env logs --tail=100 db
curl --fail http://127.0.0.1:8000/health/
curl --fail https://app.example.com/health/
```

Expected health response:

```json
{"status": "ok"}
```

Create the first Django administrator interactively:

```bash
cd /opt/django-app
sudo docker compose --env-file .env run --rm web \
  python manage.py createsuperuser
```

Then visit `https://app.example.com/admin/`.

## 8. Database backups and restore testing

The bootstrap enables a systemd timer that creates a compressed custom-format
`pg_dump` every day at approximately 02:15 UTC:

```bash
systemctl list-timers django-db-backup.timer
sudo systemctl start django-db-backup.service
sudo journalctl -u django-db-backup.service
sudo ls -lh /var/backups/django-app
```

Local backups older than 14 days are deleted. A backup on the same server is not
enough for disaster recovery. Copy backups to encrypted off-server storage and
regularly test restoration into a separate database.

Perform production restoration through a reviewed maintenance procedure with
the application stopped, a verified backup, and credentials loaded without
printing them. The basic PostgreSQL restoration operation is:

```bash
pg_restore --clean --if-exists --no-owner --dbname=DATABASE BACKUP.dump
```

Always rehearse the exact restore procedure outside production first.

## 9. Manual rollback

Find a previously successful image tag in Jenkins or the registry, then on the
application server update only `APP_VERSION`:

```bash
sudoedit /opt/django-app/.env
cd /opt/django-app
sudo docker compose --env-file .env pull web
sudo docker compose --env-file .env up -d web
curl --fail https://app.example.com/health/
```

Rolling back an image does not reverse a database migration. Prefer expand-and-
contract migrations: add backward-compatible schema first, deploy code that can
use both forms, migrate data, and remove old schema in a later release.

## 10. Routine operations

View services and logs:

```bash
cd /opt/django-app
sudo docker compose --env-file .env ps
sudo docker compose --env-file .env logs -f --tail=200 web
```

Open a Django shell:

```bash
sudo docker compose --env-file .env run --rm web python manage.py shell
```

Run Django's deployment checks:

```bash
sudo docker compose --env-file .env run --rm web python manage.py check --deploy
```

Inspect disk usage:

```bash
df -h
sudo docker system df
sudo du -sh /var/backups/django-app
```

Do not run broad Docker prune commands without reviewing what they will remove.

## 11. Adapt the kit to an existing Django project

Copy these files and directories into the existing repository:

```text
Dockerfile
Jenkinsfile
.dockerignore
.env.example
deploy/
```

Then make these project-specific changes:

1. Replace `config.wsgi:application` in the Dockerfile with the actual WSGI
   module, such as `locallibrary.wsgi:application`.
2. Merge the PostgreSQL configuration from `config/settings.py` into the real
   settings module.
3. Add WhiteNoise after `SecurityMiddleware`, or configure Nginx/object storage
   to serve static files instead.
4. Define `STATIC_ROOT` and ensure `collectstatic` succeeds during image build.
5. Add a lightweight `/health/` endpoint that does not expose secrets.
6. Add `gunicorn` and `psycopg[binary]` to the project's dependency lock or
   requirements file.
7. Confirm media uploads use durable storage. This kit does not define media
   storage; container filesystems are ephemeral.
8. Update the pipeline's tests and image name.
9. Run `python manage.py check --deploy` and review every warning.

For the MDN Local Library example, use:

```text
locallibrary.wsgi:application
```

## 12. Security and reliability checklist

- [ ] `.env` and registry tokens are absent from Git history.
- [ ] Jenkins uses credential IDs, not plaintext secrets in the Jenkinsfile.
- [ ] The Jenkins agent is dedicated to trusted builds.
- [ ] The application server uses a read-only registry credential.
- [ ] SSH host verification is enabled.
- [ ] Root SSH login and password authentication are disabled after key access is tested.
- [ ] Only ports 22, 80, and 443 are allowed by the firewall.
- [ ] PostgreSQL is not published to the host.
- [ ] HTTPS renewal has been tested.
- [ ] Backups are copied off-server and restore tests are scheduled.
- [ ] Disk, memory, certificate expiry, container health, and HTTP health are monitored.
- [ ] OS, Docker, PostgreSQL, Python base image, Django, and dependencies receive updates.
- [ ] Deployments use immutable image tags.
- [ ] Database migrations are backward compatible with the previous release.
- [ ] User-uploaded media is stored in a persistent volume or object storage.

## Authoritative references

- Jenkins credentials: <https://www.jenkins.io/doc/book/using/using-credentials/>
- Docker Compose startup ordering and health checks:
  <https://docs.docker.com/compose/how-tos/startup-order/>
- Docker Compose volumes:
  <https://docs.docker.com/reference/compose-file/volumes/>
- Docker's Python guide: <https://docs.docker.com/guides/python/>
- PostgreSQL official image: <https://hub.docker.com/_/postgres/>
- Django deployment checklist:
  <https://docs.djangoproject.com/en/5.2/howto/deployment/checklist/>
- Django static-file deployment:
  <https://docs.djangoproject.com/en/5.2/howto/static-files/deployment/>
