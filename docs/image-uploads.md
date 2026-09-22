# 리뷰/프로필/클레임 이미지 업로드 인프라

DEV의 기존 `petflow-dev-uploads` 버킷에서 `reviews/`, `profiles/`, `claims/` 경로를 사용한다.
버킷은 비공개, SSE-S3 암호화, HTTPS 강제와 삭제 방지 설정을 유지한다.
브라우저는 백엔드가 발급한 presigned PUT URL로 S3에 직접 업로드하고,
이미지 조회는 OAC로 연결한 CloudFront 기본 HTTPS 도메인을 사용한다.
`images.leechs.shop` DNS/ACM은 이번 구성에 포함하지 않는다.

## 배포와 전달할 설정

`terraform/environments/dev`에서 기존 절차대로 plan을 검토하고 apply한다.
이 변경은 파일 수정이며 실제 AWS 적용은 별도 단계다.

```bash
terraform output -json image_upload_config
terraform output -json image_upload_role_arns
terraform output -json image_upload_pod_identity_association_ids
terraform output -raw uploads_cloudfront_distribution_id
```

`image_upload_config`의 `bucket_name`, `region`, `file_base_url`을 백엔드에 전달한다.
애플리케이션 환경변수명은 백엔드와 합의한 뒤 `gitops-value`에 반영한다.
현재 Spring 설정에 없는 임의 변수는 추가하지 않는다.
프론트에는 `file_base_url`의 호스트, `allowed_origins`, 아래 업로드 계약을 전달한다.
`next/image` 조회에는 해당 호스트를 `images.remotePatterns`에 추가해야 한다.

## 백엔드 권한과 구현 계약

| 서비스 | Namespace | ServiceAccount | 객체 경로 |
| --- | --- | --- | --- |
| review-service | review-service | generic-service | reviews/ |
| member-service | member-service | generic-service | profiles/ |
| order-service | order-service | generic-service | claims/ |

기존 Helm 차트의 기본 ServiceAccount 이름은 `generic-service`다.
배포 시 실제 namespace/ServiceAccount와 association의 값이 일치하는지 확인한다.
서비스별 Role은 자기 경로의 PutObject, PutObjectTagging, GetObject,
GetObjectTagging만 허용하며 목록 조회 및 삭제 권한은 부여하지 않는다.
GetObject 권한은 HeadObject를 통한 파일 존재/크기 확인에도 사용한다.

AWS SDK 기본 자격증명 체인을 사용한다. 장기 Access Key/Secret Key와
IRSA용 `eks.amazonaws.com/role-arn` annotation은 추가하지 않는다.
Java SDK v2는 Pod Identity 지원 버전인 2.21.30 이상을 사용한다.
기존 Pod에는 association 생성 이후 재시작이 필요할 수 있다.

- presigned PUT 발급 시 객체 키에 사용자 식별자와 UUID를 포함하고 `status=pending`을 서명에 포함한다.
- Content-Type을 서명에 포함하면 프론트에서 같은 값을 보내도록 API 계약을 정한다. count만 받는 계약은 JPEG 변환 등 형식 정책을 먼저 합의해야 한다.
- 만료 시간, 허용 개수/형식/파일 크기는 백엔드와 프론트가 정한다. 인프라 CORS는 이러한 제한을 대신하지 않는다.
- 저장 요청에서는 자기 사용자에게 발급한 키와 실제 업로드된 객체를 검증한다. 임의 외부 URL이나 다른 사용자의 객체를 확정하지 않는다.
- DB 저장 성공 후 status를 confirmed로 변경한다. 태그 API는 전체 태그 세트를 교체하므로 다른 태그가 있으면 보존한다.
- DB와 S3는 하나의 트랜잭션이 아니므로 confirmed 변경 실패를 재시도한다. 저장된 사진이 pending으로 남으면 만료될 수 있다.

fileUrl은 `file_base_url + '/' + 객체 키`로 생성하고, 만료되는 uploadUrl은 DB에 저장하지 않는다.

## 프론트 업로드 계약

```typescript
const response = await fetch(uploadUrl, {
  method: "PUT",
  headers: {
    "Content-Type": agreedContentType,
    "x-amz-tagging": "status=pending",
  },
  body: file,
});
if (!response.ok) throw new Error("이미지 업로드 실패");
```

S3 요청에는 서비스 JWT를 붙이지 않고 File 원본을 보낸다.
web의 공통 API 래퍼는 백엔드 base URL/JWT/JSON 처리가 있으므로 S3 PUT에 사용하지 않는다.
PUT 성공 후에만 반환받은 fileUrl을 리뷰/프로필/클레임 등록 API에 전달한다.

CORS는 기본적으로 `https://leechs.shop`, `http://localhost:3000`의 PUT과
Content-Type/x-amz-* 헤더를 허용한다. 실제 개발 origin은 tfvars의
`uploads_allowed_origins`에 지정한다. S3가 preflight OPTIONS를 처리하므로
AllowedMethods에 OPTIONS를 추가하지 않는다.

## 보존과 고아 객체 정리

`status=pending` 객체만 생성 후 기본 3일에 만료되며 confirmed 객체는 이 규칙에서 제외된다.
기준은 태그 변경 시점이 아닌 객체 생성 시점이고 삭제는 비동기이므로 정확히 72시간 후를 보장하지 않는다.
uploads 버킷은 Versioning 비활성 구성을 사용한다. 과거에 Versioning을 활성화한
버킷에서는 이 규칙만으로 이전 버전의 영구 삭제를 보장할 수 없으므로 실제 상태도 확인한다.

`tdestroy.sh`는 module.s3를 제외하므로 버킷/객체/CORS/Lifecycle/CloudFront/OAC를 보존한다.
워크로드 Role과 association은 EKS와 함께 삭제되고 재구축 시 다시 생성된다.
전체 terraform destroy는 prevent_destroy에 의해 중단될 수 있으며 자동 건너뛰기가 아니다.
버킷 삭제 방지와 별개로 pending Lifecycle은 EKS를 삭제한 동안에도 동작한다.

CloudFront 조회는 공개 이미지용이다. OAC는 S3 origin을 보호하지만 사용자별 조회 권한을 제공하지 않는다.
CloudFront는 `reviews/*`, `profiles/*`, `claims/*`를 uploads 버킷에서, `products/*`를
product-images 버킷에서 조회한다. 각 버킷 정책은 해당 경로만 조회하도록 허용한다.
상품 이미지는 `petflow-dev-product-images` 버킷의 `products/{productId}/{uuid}.{ext}`에
수동 업로드하고, DB에는 `https://image.leechs.shop/products/{productId}/{uuid}.{ext}`를 저장한다.
객체 삭제 후 이미 캐시된 이미지는 TTL 동안 조회될 수 있다.

## 배포 후 확인

1. 실제 uploads 버킷의 Versioning/CORS/Lifecycle과 퍼블릭 차단 상태를 확인한다.
2. 서비스별 namespace/ServiceAccount 및 Pod Identity 연결과 SDK 자격증명 사용을 확인한다.
3. 허용 origin에서 pending 헤더를 포함한 presigned PUT이 성공하고, 태그 누락/변조는 실패하는지 확인한다.
4. 서비스가 상대 경로에 접근할 수 없고, 자기 객체를 HeadObject 및 confirmed로 변경할 수 있는지 확인한다.
5. 반환된 CloudFront fileUrl로 이미지를 조회하고, S3 직접 비서명 조회는 차단되는지 확인한다.
6. DB 저장 후 태그 실패의 재시도를 검증하고, 만료 대상 pending과 confirmed 보존을 별도로 확인한다.
