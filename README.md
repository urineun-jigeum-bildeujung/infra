# Infra

`골라주개냥` 서비스의 클라우드 인프라를 관리하는 Repository입니다.

## Overview

서비스 운영에 필요한 AWS 인프라를 구성하고,
Terraform을 활용하여 Infrastructure as Code(IaC) 방식으로 관리합니다.

## Tech Stack

* AWS
* Terraform
* Kubernetes / EKS
* Docker

## Repository Role

* 클라우드 네트워크 구성
* Kubernetes 클러스터 구성
* AWS 리소스 관리
* 인프라 코드 및 환경 설정 관리

> Kubernetes 배포 설정 및 GitOps 관련 구성은 별도의 `gitops` Repository에서 관리합니다.
