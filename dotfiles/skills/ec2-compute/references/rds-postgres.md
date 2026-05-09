# AWS RDS PostgreSQL

Use this reference when a user wants to programmatically create an AWS RDS PostgreSQL instance, wire it to 1Password, create app/admin database users, or debug `psql` connectivity.

## Safety Rules

- Do not run mutating AWS commands without explicit user confirmation in the current turn. Mutating commands include `aws rds create-db-instance`, `modify-db-instance`, `delete-db-instance`, `start-db-instance`, `stop-db-instance`, and `aws ec2 authorize-security-group-ingress`.
- Before any mutation, show `aws sts get-caller-identity`, the AWS region, the DB identifier, public/private access choice, and the exact command to be run.
- Never print database passwords in the final answer. Prefer passing passwords via environment variables or 1Password.
- For laptop access, restrict security group ingress to the current public IP `/32`; never use `0.0.0.0/0` for Postgres unless the user explicitly asks and understands the risk.
- For prod, prefer private RDS access through app infrastructure, VPN, bastion, or Tailscale subnet routing. Public RDS plus IP allowlist is acceptable for quick dev setup only.

## Inputs To Establish

- AWS account and region: `aws sts get-caller-identity`; `aws configure get region`
- DB identifier, for example `ai-agent-autoimprove-pg` or `ai-agent-learning-dev-pg`
- Logical database name, for example `autoimprove` or `learning`
- Admin username, for example `autoimprove_admin` or `learning_admin`
- App username, for example `autoimprove_app` or `learning_app`
- Instance class: start with `db.t4g.small` unless the user has a stronger size/cost preference
- Storage: start with `20` GiB `gp3`
- Backup retention: `1` day for disposable/dev, `7` or more for prod
- Connectivity: public IP allowlist for quick local dev, private network for prod

## Create RDS With AWS CLI

Generate strong passwords locally and store them in 1Password after creation:

```bash
ADMIN_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9!#$%^*+=_.-' < /dev/urandom | head -c 32)"
APP_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9!#$%^*+=_.-' < /dev/urandom | head -c 32)"
```

Set variables:

```bash
export AWS_REGION="us-east-1"
export PROJECT="ai-agent-learning"
export DB_IDENTIFIER="ai-agent-learning-dev-pg"
export DB_NAME="learning"
export ADMIN_USERNAME="learning_admin"
export APP_USERNAME="learning_app"
```

Create the instance:

```bash
aws rds create-db-instance \
  --region "$AWS_REGION" \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --engine postgres \
  --db-instance-class db.t4g.small \
  --allocated-storage 20 \
  --storage-type gp3 \
  --master-username "$ADMIN_USERNAME" \
  --master-user-password "$ADMIN_PASSWORD" \
  --db-name "$DB_NAME" \
  --backup-retention-period 1 \
  --no-multi-az \
  --publicly-accessible \
  --tags Key=Project,Value="$PROJECT"
```

Wait and get the endpoint:

```bash
aws rds wait db-instance-available \
  --region "$AWS_REGION" \
  --db-instance-identifier "$DB_IDENTIFIER"

ENDPOINT="$(aws rds describe-db-instances \
  --region "$AWS_REGION" \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)"

aws rds describe-db-instances \
  --region "$AWS_REGION" \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address,Port:Endpoint.Port,Public:PubliclyAccessible,Engine:Engine,Version:EngineVersion,DBName:DBName,MasterUsername:MasterUsername,SG:VpcSecurityGroups[0].VpcSecurityGroupId}' \
  --output table
```

## Allow Local `psql` Access

Only do this for local/dev workflows after confirmation:

```bash
SG_ID="$(aws rds describe-db-instances \
  --region "$AWS_REGION" \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
  --output text)"

MYIP="$(curl -s https://checkip.amazonaws.com)/32"

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=${MYIP},Description='local psql access'}]"
```

Test network reachability before debugging credentials:

```bash
nc -vz "$ENDPOINT" 5432
```

If `psql` times out, the problem is usually networking: public accessibility, subnet routing, or security-group ingress. If credentials are wrong, Postgres usually returns an authentication error instead of timing out.

## Create The App User

Use `PGPASSWORD` instead of embedding passwords in a URL:

```bash
export PGPASSWORD="$ADMIN_PASSWORD"
psql \
  -h "$ENDPOINT" \
  -p 5432 \
  -U "$ADMIN_USERNAME" \
  -d "$DB_NAME" \
  "sslmode=require"
```

Then create the app role and grants:

```sql
CREATE ROLE learning_app LOGIN PASSWORD '<app-password>';
GRANT CONNECT ON DATABASE learning TO learning_app;
GRANT USAGE, CREATE ON SCHEMA public TO learning_app;
```

Use project-specific names in place of `learning_app` and `learning`.

## 1Password Items

Store app and admin credentials as separate 1Password items. The app item is for normal runtime and migrations; the admin item is for bootstrapping and reset workflows only.

Required fields for each item:

- `host`
- `port`
- `database`
- `username`
- `password`
- `sslmode`

Use `sslmode=require`.

For app credentials, `database` should be the application database, such as `learning` or `autoimprove`.
For admin credentials, use the database the admin connects to for bootstrapping. In prior RDS setup, `autoimprove-postgres-admin.database` was corrected to `postgres` for admin access while the app item used `autoimprove`.

## Repo Follow-Up

After the RDS instance is reachable and 1Password items exist:

```bash
just check-env dev
just db-bootstrap dev
just db-migrate-dev
```

For prod migrations, require an explicit guard such as:

```bash
CONFIRM_PROD_MIGRATE=1 just db-migrate-prod
```
