# outputs.tf — data 루트 모듈 (dev · prod 공통 코드)

output "data_contract" {
  description = "Account, region, environment, cluster, namespace, service accounts, database coordinates, cache endpoint, secret ARNs, media location, KMS key and operator repository (12 keys)."
  value       = module.component.data_contract # 예: 12개 키를 담은 object
}

output "application_input_values" {
  description = "Noncredential application configuration derived from the data and delivery contracts."
  value = {
    region               = var.region
    media_bucket         = module.component.data_contract.export.bucket_name
    media_prefix         = module.component.data_contract.export.prefix
    media_url            = "https://${module.component.data_contract.export.bucket_name}.s3.${var.region}.amazonaws.com"
    frontend_backend_url = "http://${local.application.deployment}.${local.application.namespace}.svc.cluster.local:9000"
    resource_attributes  = "service.instance.id=$(POD_NAME),deployment.environment=${var.environment},service.namespace=${local.application.namespace}"
    region_literal       = "AWS_REGION=${var.region}"
    media_bucket_literal = "S3_BUCKET=${module.component.data_contract.export.bucket_name}"
    media_prefix_literal = "S3_PREFIX=${module.component.data_contract.export.prefix}"
    media_url_literal    = "S3_FILE_URL=https://${module.component.data_contract.export.bucket_name}.s3.${var.region}.amazonaws.com"
  }
}
