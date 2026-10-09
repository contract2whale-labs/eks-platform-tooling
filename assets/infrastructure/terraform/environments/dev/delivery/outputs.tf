# outputs.tf — delivery 루트 모듈 (dev · prod 공통 코드)
# 루트 모듈과 적용: 모듈 출력을 같은 이름으로 루트 모듈 밖에 전달합니다. 뒤 루트 모듈(애플리케이션 데이터 identity · 운영 환경 prod/delivery)은 delivery_contract 를 terraform_remote_state 로 읽고,

output "delivery_contract" {
  description = "Account, region, environment, cluster, registry, the two repositories, signing key, CI role, the two application workloads, Argo CD and Kyverno settings (14 keys)."
  value       = module.component.delivery_contract # 예: 14개 키를 담은 object
}

output "signing_public_key_pem" {
  description = "PEM public key of the cosign signing key; input of local cosign verify --key (evidence, not secret)."
  value       = module.component.signing_public_key_pem # 예: "-----BEGIN PUBLIC KEY-----\n…"
}




output "platform_input_values" {
  description = "Noncredential fields for the environment-specific GitOps consumers."
  value = {
    ecr_image_pattern = "${module.component.delivery_contract.ecr_registry}/*"
  }
}
