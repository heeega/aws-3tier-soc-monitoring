# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ⑩ VPC Flow Log 유실 발견 및 복구

**TL;DR**
- ELK 통합을 준비하며 로그 소스를 점검하던 중, VPC Flow Log가 Terraform 코드로 관리되지 않고 있었으며, destroy/재구축 과정에서 이미 사라진 VPC를 가리키는 고아 리소스로 남아있던 것을 발견했다.
- 현재 VPC에는 Flow Log가 전혀 연결되어 있지 않아, 최근 실행한 공격 재현·SOAR 검증의 네트워크 로그가 수집되지 않고 있었다.
- Flow Log를 Terraform 코드로 편입하고, 이전에 계획했던 CloudWatch Logs + S3 이중 저장 구조까지 함께 구현했다.

---

## 1. 발견 경위

ELK SIEM 통합을 시작하기 전, 어떤 로그 소스를 가져올지 점검하는 과정에서 VPC Flow Log 관련 Terraform 코드를 검색했다.

```
grep -rn "aws_flow_log" terraform/
```

검색 결과 `.tf` 파일 어디에도 Flow Log 리소스가 정의되어 있지 않았다. 프로젝트 초기(2일 차)에 AWS 콘솔에서 직접 생성했던 기록만 있을 뿐, 코드로 관리되지 않고 있었던 것이다.

## 2. 원인 확인

기존 Flow Log의 상태를 확인한 결과, 다음과 같이 나타났다.

```json
{
  "ID": "fl-05b9ab77b596454bf",
  "LogGroup": "soc-3tier-flowlogs",
  "ResourceId": "vpc-063e13cc6eedb8b23"
}
```

> 📸 `72_flowlog_orphaned_old_vpc.png` — 옛 VPC를 가리키는 Flow Log 확인

`ResourceId`가 가리키는 VPC ID는 이전(8일 차)에 `terraform destroy`로 이미 삭제된 VPC였다. 콘솔에서 수동으로 생성한 리소스였기 때문에 `destroy` 대상에 포함되지 않아 그대로 남아있었고, 재구축된 현재 VPC와는 연결되어 있지 않았다.

현재 VPC를 대상으로 다시 조회한 결과를 통해 이를 명확히 확인했다.

```
aws ec2 describe-flow-logs --filter "Name=resource-id,Values=<현재 VPC ID>"
→ { "FlowLogs": [] }
```

> 📸 `73_flowlog_missing_current_vpc.png` — 현재 VPC에 연결된 Flow Log 없음 확인

즉 8일 차 재구축 이후 실행한 모든 네트워크 트래픽(공격 재현, SOAR 파이프라인 재검증 등)이 VPC Flow Logs로 수집되지 않고 있었다.

## 3. 복구 — Terraform 코드로 편입 및 이중 저장 구현

Flow Log를 Terraform 코드로 정의하면서, 2일 차에 계획했던 대로 CloudWatch Logs와 S3 양쪽에 동시 저장되도록 구성했다. CloudWatch Logs는 실시간 모니터링과 Lambda 자동 대응 트리거용으로, S3는 장기 보관 및 감사 대응용으로 역할을 분리했다.

```hcl
resource "aws_flow_log" "to_cloudwatch" {
  vpc_id               = aws_vpc.main.id
  traffic_type          = "ALL"
  log_destination_type  = "cloud-watch-logs"
  log_destination       = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn           = aws_iam_role.flow_logs.arn
}

resource "aws_flow_log" "to_s3" {
  vpc_id                = aws_vpc.main.id
  traffic_type           = "ALL"
  log_destination_type   = "s3"
  log_destination        = aws_s3_bucket.flow_logs.arn
}
```

### 트러블슈팅 — 기존 로그 그룹 충돌

`terraform apply` 실행 시, 기존에 콘솔에서 생성된 Flow Log가 이미 만들어둔 로그 그룹(`soc-3tier-flowlogs`)과 이름이 충돌해 오류가 발생했다.

```
Error: ResourceAlreadyExistsException: The specified log group already exists
```

> 📸 `74_terraform_apply_error_loggroup_exists.png` — 로그 그룹 충돌 오류

새로 생성하는 대신, 기존 로그 그룹을 그대로 Terraform state로 가져와 코드 관리 대상에 포함시켰다. 이 방식으로 기존에 쌓여 있던 로그 데이터도 그대로 유지할 수 있었다.

```
terraform import aws_cloudwatch_log_group.flow_logs soc-3tier-flowlogs
```

> 📸 `75_terraform_import_loggroup_success.png` — import 성공 화면

이후 정상적으로 배포를 완료했다.

> 📸 `76_terraform_apply_flowlogs_final.png` — 최종 배포 완료

## 4. 최종 검증 및 정리

현재 VPC에 두 종류의 Flow Log가 정상적으로 연결된 것을 확인했다.

```
[
  { "ID": "fl-03646e878d1cfc2f2", "Dest": "s3" },
  { "ID": "fl-07ff435da4bda693e", "Dest": "cloud-watch-logs" }
]
```

> 📸 `77_flowlog_dual_destination_confirmed.png` — 이중 저장 구조 확인

더 이상 필요 없는 옛 고아 Flow Log(`fl-05b9ab77b596454bf`)는 삭제해 정리했다.

---

## 트러블슈팅

| 발생 시점 | 이슈 | 원인 | 해결 |
|---|---|---|---|
| ELK 통합 준비 중 | VPC Flow Log가 현재 VPC에 연결되어 있지 않음 | 콘솔에서 수동 생성한 리소스가 Terraform destroy 대상에서 제외되어, 재구축된 VPC와 연결이 끊긴 채 고아로 남음 | Flow Log를 Terraform 코드로 재정의, 기존 로그 그룹은 import로 흡수 |
| Flow Log 코드 배포 시 | 로그 그룹 이름 충돌 (ResourceAlreadyExistsException) | 기존 콘솔 생성 로그 그룹이 이미 존재 | `terraform import`로 기존 리소스를 state에 편입 |

이번 트러블슈팅은 콘솔에서 생성한 리소스가 IaC 기반 destroy/재구축 사이클과 어떻게 어긋날 수 있는지를 실제로 보여준 사례였다. 이후로는 모든 로그 관련 리소스가 예외 없이 Terraform 코드로 관리된다.

---

## 오늘 진행사항 정리

- [x] VPC Flow Log가 Terraform 코드로 관리되지 않고 있었으며, 재구축된 VPC와 연결이 끊겨 있던 문제 발견
- [x] Flow Log를 Terraform 코드로 편입, 기존 로그 그룹은 import로 흡수
- [x] CloudWatch Logs + S3 이중 저장 구조 구현 (2일 차 계획 반영)
- [x] 옛 고아 Flow Log 정리
- [ ] ELK 스택(Elasticsearch/Logstash/Kibana) 구축 — 다음 단계
