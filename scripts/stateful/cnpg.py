"""Read-only business-data fingerprints and pinned CNPG artifact checks."""
import json
import re
from common import BUCKET, aws, get, kube, require

DATABASES = ("auth_db", "member_db", "product_db", "order_db", "payment_db", "review_db", "notification_db", "repurchase_db")


def primary():
    pods = get("pods", namespace="database",
               selector="cnpg.io/cluster=petflow-db,cnpg.io/instanceRole=primary")["items"]
    require(len(pods) == 1, "expected one CNPG primary")
    return pods[0]["metadata"]["name"]


def query(database, sql):
    return kube("exec", "-i", "-n", "database", primary(), "-c", "postgres", "--",
                "psql", "-U", "postgres", "-d", database, "-X", "-v", "ON_ERROR_STOP=1",
                "-At", "-f", "-", input_data=sql)


def assert_no_clients():
    # Do not exempt superusers: a direct postgres session can also write data.
    # CNPG's own short-lived management connections are the only named exception.
    count = query("postgres", "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' "
                  "AND pid<>pg_backend_pid() AND application_name NOT IN ('cnpg','cnpg-instance-manager');").strip()
    require(count == "0", "non-maintenance PostgreSQL client connections remain; disconnect them before retry")


def fingerprints():
    result = {}
    for database in DATABASES:
        result[database] = {}
        schemas = ("public", "repurchase") if database == "repurchase_db" else ("public",)
        for schema in schemas:
            names = query(database, "SELECT tablename FROM pg_tables WHERE schemaname='" +
                          schema + "' ORDER BY tablename;").splitlines()
            for name in names:
                # SQL identifiers originate in pg_catalog and are quoted, never shell-interpolated.
                quoted = '"' + name.replace('"', '""') + '"'
                sql = ("SET TIME ZONE 'UTC'; SELECT json_build_object('count',count(*),"
                       "'sha',md5(coalesce(string_agg(h,'' ORDER BY h),''))) FROM "
                       "(SELECT md5(row_to_json(t)::text) AS h FROM " + schema + "." + quoted + " AS t) s;")
                raw = query(database, sql).splitlines()[-1]
                # Keep existing public keys; qualify additional schemas to avoid collisions.
                key = name if schema == "public" else schema + "." + name
                result[database][key] = json.loads(raw)
    return result


def verify(source):
    require(source.get("schemaVersion") == 2 and source.get("serverName") == "petflow-db", "invalid pinned CNPG source")
    require(re.match(r"^\d{8}T\d{6}$", source.get("backupID", "")), "missing Barman backup ID")
    require(re.match(r"^petflow_[a-zA-Z0-9_]{1,48}$", source.get("targetName", "")), "missing named restore point")
    require(source["destinationPath"].startswith("s3://" + BUCKET + "/cnpg/"), "unexpected CNPG bucket")
    prefix = source["destinationPath"].replace("s3://" + BUCKET + "/", "", 1)
    require(prefix.startswith("cnpg/"), "unexpected CNPG source prefix")
    require(source["baseInfoKey"] == prefix + "/petflow-db/base/" + source["backupID"] + "/backup.info", "base backup object mismatch")
    require(source["walKey"].startswith(prefix + "/petflow-db/wals/"), "WAL source mismatch")
    aws("s3api", "head-object", "--bucket", BUCKET, "--key", source["baseInfoKey"])
    aws("s3api", "head-object", "--bucket", BUCKET, "--key", source["walKey"], "--version-id", source["walVersionId"])
