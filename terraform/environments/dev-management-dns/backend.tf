# 기존 Grafana/Prometheus DNS State를 보존하며 공개 Grafana 전환과 Prometheus Alias 제거를
# 관리한다. 코어 DEV 인프라와 별도 State를 유지한다.
terraform {
  backend "s3" {}
}
