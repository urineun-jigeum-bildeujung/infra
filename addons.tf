
provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name, "--region", local.region]
    }
  }
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.1"

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  set {
    name  = "nodeSelector.node-role"
    value = "core"
  }

  depends_on = [aws_eks_node_group.core]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "62.7.0"

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        retention = "15d"
        nodeSelector = { "node-role" = "core" }
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "gp3"
              accessModes      = ["ReadWriteOnce"]
              resources = {
                requests = { storage = "50Gi" }
              }
            }
          }
        }
      }
    }
    grafana = {
      nodeSelector = { "node-role" = "core" }
    }
    alertmanager = {
      alertmanagerSpec = {
        nodeSelector = { "node-role" = "core" }
      }
    }
  })]

  depends_on = [helm_release.metrics_server]
}

resource "helm_release" "prometheus_adapter" {
  name       = "prometheus-adapter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-adapter"
  namespace  = "monitoring"
  version    = "4.11.0"

  values = [yamlencode({
    prometheus = {
      url  = "http://kube-prometheus-stack-prometheus.monitoring.svc"
      port = 9090
    }
    nodeSelector = { "node-role" = "core" }
    rules = {
      default = true
      custom = [
        {
          seriesQuery = "http_requests_total{namespace!=\"\",pod!=\"\"}"
          resources = {
            overrides = {
              namespace = { resource = "namespace" }
              pod       = { resource = "pod" }
            }
          }
          name = {
            matches = "^(.*)_total$"
            as      = "$${1}_per_second"
          }
          metricsQuery = "sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)"
        }
      ]
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = "2.15.1"

  values = [yamlencode({
    nodeSelector = { "node-role" = "core" }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}
