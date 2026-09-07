# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ⑨ GitHub Actions CI/CD 파이프라인 구축

**TL;DR**
- OIDC 기반 GitHub Actions ↔ AWS 인증 체계를 구축하고, `plan`은 PR에서 자동 실행, `apply`는 GitHub Environment 승인을 거쳐야 실행되는 파이프라인을 만들었다.
- 인증 실패, 권한 설정, 변수 누락 등 여러 단계의 오류를 하나씩 해결했다.
- 가장 큰 문제는 **로컬 Terraform state와 GitHub Actions의 state가 서로 다른 것을 보고 있어 리소스가 중복 생성된 사고**였고, S3 Backend로 state를 통합해 근본적으로 해결했다.

---

## 1. 왜 CI/CD인가, 왜 OIDC인가

지금까지는 로컬 PC에서 직접 `terraform plan`/`apply`를 실행해왔다. 이를 GitHub Actions로 자동화하되, 다음 두 가지 설계 원칙을 세웠다.

- **plan은 자동, apply는 수동 승인**: 인프라 변경, 특히 삭제·교체가 포함될 수 있는 변경은 사람이 최종 검토하는 절차가 필요하다고 판단했다. 이는 SOC의 핵심 개념인 Human-in-the-loop과 같은 맥락이다.
- **Access Key 대신 OIDC 인증**: 장기 유효한 키를 GitHub에 저장하지 않고, 실행할 때마다 임시 자격증명을 발급받는 방식을 택해 키 유출 위험 자체를 제거했다.

---

## 2. OIDC 인증 트러블슈팅

### 1차 실패 — sub 조건 불일치

IAM Role의 신뢰 정책에 `token.actions.githubusercontent.com:sub` 조건을 `repo:heeega/aws-3tier-soc-monitoring:*` 형태로 설정했으나, `Not authorized to perform sts:AssumeRoleWithWebIdentity` 오류가 발생했다.

> 📸 `54_github_actions_oidc_auth_error.png` — 최초 인증 실패 화면

### 2차 확인 — 레포 Workflow 권한

레포의 Settings → Actions → General에서 Workflow permissions가 "Read repository contents and packages permissions"(읽기 전용)로 설정되어 있어, `id-token: write` 권한이 실질적으로 발급되지 않고 있었다. "Read and write permissions"로 변경했다.

### 근본 원인 — 실제 OIDC 토큰 sub claim 형식 확인

조건을 수정하고 권한도 바꿨음에도 계속 실패해, 워크플로우에 디버그 스텝을 추가해 GitHub이 실제로 발급하는 OIDC 토큰을 직접 디코딩했다.

```
"sub": "repo:heeega@94948106/aws-3tier-soc-monitoring@1330492936:pull_request"
```

예상했던 `repo:heeega/aws-3tier-soc-monitoring:pull_request` 형식이 아니라, 사용자 ID·레포 ID가 `@`로 결합된 확장 형식이 사용되고 있었다.

> 📸 `55_oidc_token_actual_sub_claim.png` — 실제 OIDC 토큰 디코딩 결과

신뢰 정책의 `sub` 조건에 이 확장 형식(`repo:heeega@*/aws-3tier-soc-monitoring@*:*`)을 함께 추가해 해결했다.

---

## 3. 변수 미주입 문제

인증이 통과된 이후, `terraform plan`이 `alert_email` 변수 값을 요구하며 대화형 프롬프트 상태로 멈추는 문제가 발생했다. 로컬에서는 `terraform.tfvars`(gitignore로 보호)로 값을 제공했지만, CI 환경에는 이 파일이 존재하지 않았다.

> 📸 `56_terraform_plan_stuck_alert_email_prompt.png` — 프롬프트 대기 상태

GitHub Secret(`TF_VAR_ALERT_EMAIL`)을 추가하고, 워크플로우에서 `TF_VAR_alert_email` 환경변수로 전달하도록 수정해 해결했다. 이후 PR의 plan 워크플로우가 정상적으로 통과했다.

> 📸 `57_github_actions_ci_success.png` — Terraform Plan CI 통과 화면

---

## 4. Apply 워크플로우와 승인 절차

`main` 브랜치 push 시 실행되는 apply 워크플로우를 작성하고, GitHub Environment(`production`)에 Required reviewer를 등록해 apply 실행 전 수동 승인이 필요하도록 구성했다.

> 📸 `58_github_environment_protection_setup.png` — Environment 보호 규칙 설정
> 📸 `59_terraform_apply_awaiting_approval.png` — 승인 대기 상태

---

## 5. State 불일치로 인한 리소스 중복 생성 사고

첫 apply 승인 후, 다음과 같은 오류가 발생했다.

```
Error: ELBv2 Target Group (soc-3tier-web-tg) already exists
Error: ELBv2 Load Balancer (soc-3tier-alb) already exists
Error: creating IAM OIDC Provider: EntityAlreadyExists
Error: creating IAM Role: EntityAlreadyExists
```

> 📸 `61_terraform_apply_state_conflict_error.png` — 리소스 충돌 오류 전체

### 원인

GitHub Actions는 로컬 PC의 `terraform.tfstate`를 전혀 알지 못한다. state 파일이 `.gitignore`로 보호되어 커밋된 적이 없었기 때문에, GitHub Actions는 "아무 인프라도 존재하지 않는다"고 판단하고 전체를 새로 만들려 시도했다. 그 결과 이름이 고유해야 하는 리소스(Target Group, ALB, IAM Role, OIDC Provider)는 충돌 오류로 실패했지만, **NAT Gateway는 실제로 중복 생성**됐다.

### 확인 및 긴급 정리

```
aws ec2 describe-nat-gateways --region ap-northeast-2 ...
```

> 📸 `62_nat_gateway_duplicate_found.png` — NAT Gateway 2개 확인

로컬 state가 참조하는 실제 NAT Gateway ID를 확인해, 이와 다른 고아 리소스를 즉시 삭제했다.

> 📸 `60_orphan_natgw_cleanup.png` — 중복 NAT Gateway 삭제

Route Table 등 다른 리소스는 중복 생성되지 않았음을 추가로 확인했다.

> 📸 `63a_route_table_check.png`, `63b_route_table_state_match.png` — Route Table 중복 없음 확인

### 근본 해결 — S3 Backend 도입

이 사고의 근본 원인은 **로컬과 CI가 서로 다른 state를 보고 있었다는 것**이다. Terraform state를 S3 버킷에 저장하고, 이를 잠금 처리하는 방식으로 전환했다.

```hcl
backend "s3" {
  bucket       = "soc-3tier-tfstate-374186048514"
  key          = "terraform.tfstate"
  region       = "ap-northeast-2"
  use_lockfile = true
  encrypt      = true
}
```

S3 버킷(버전 관리 활성화)과, 초기에는 DynamoDB 락 테이블도 함께 구성했으나, Terraform 최신 버전이 지원하는 `use_lockfile` 옵션(S3 자체의 조건부 쓰기 기반 락)으로 전환해 더 단순한 구조로 정리했다.

> 📸 `64_s3_backend_dynamodb_created.png` — Backend 인프라 생성
> 📸 `65_s3_state_migrated.png` — state 파일 S3 마이그레이션 확인
> 📸 `66_terraform_plan_no_changes_s3_backend.png` — 마이그레이션 후 로컬 plan 검증

### 재검증

S3 Backend 적용 후 다시 push하고 apply를 승인한 결과, 이번에는 리소스 충돌 없이 정상적으로 완료됐다.

> 📸 `67_terraform_apply_v2_awaiting_approval.png` — 재승인 대기
> 📸 `68_terraform_apply_ci_success_final.png` — CI apply 최종 성공

---

## 6. 부가 이슈 — 줄바꿈 문자 차이

S3 Backend 적용 후 로컬에서 plan을 재확인하는 과정에서, `user_data`를 포함한 3개 리소스가 변경 대상으로 잡혔다. 원인을 확인한 결과, Windows(CRLF)에서 작성한 파일이 GitHub Actions(Linux, LF) 환경에서 실행되며 줄바꿈 문자가 미묘하게 달라진 것이었다.

> 📸 `69_line_ending_diff_detected.png` — user_data 줄바꿈 차이로 인한 diff

`.gitattributes`로 `.tf`, `.py`, `.yml` 파일의 줄바꿈을 LF로 고정하고, 로컬에서 한 번 더 apply해 AWS 상태를 LF 기준으로 정규화했다.

> 📸 `70_terraform_apply_lf_normalize_final.png` — LF 정규화 반영
> 📸 `71_terraform_plan_final_no_changes.png` — 최종 검증(No changes)

---

## 트러블슈팅

| 발생 시점 | 이슈 | 원인 | 해결 |
|---|---|---|---|
| OIDC 인증 시도 | AssumeRoleWithWebIdentity 거부 | 신뢰 정책의 sub 조건이 GitHub의 확장 sub claim 형식과 불일치 | 디버그 토큰 디코딩으로 실제 형식 확인 후 조건 수정 |
| OIDC 조건 수정 후에도 실패 | 동일 오류 지속 | 레포 Workflow permissions가 읽기 전용으로 설정되어 id-token 권한 미발급 | Read and write permissions로 변경 |
| plan 실행 시 | alert_email 변수 프롬프트에서 멈춤 | CI 환경에 terraform.tfvars가 없음 | TF_VAR_ 환경변수로 GitHub Secret 전달 |
| 최초 apply 승인 후 | 다수 리소스 EntityAlreadyExists, NAT Gateway 중복 생성 | 로컬 state(.gitignore로 보호)와 CI의 state가 서로 다름 | S3 Backend + 원격 state로 통합, 고아 리소스 수동 정리 |
| S3 Backend 적용 후 | 3개 리소스가 불필요하게 변경 대상으로 잡힘 | Windows/Linux 간 줄바꿈 문자(CRLF/LF) 차이 | .gitattributes로 LF 고정, 로컬 apply로 재정규화 |

---

## 오늘 진행사항 정리

- [x] GitHub Actions OIDC 인증 체계 구축 (IAM Role, OIDC Provider)
- [x] Terraform Plan 워크플로우 구축 (PR 시 자동 fmt/validate/plan, 결과 PR 코멘트)
- [x] Terraform Apply 워크플로우 구축 (GitHub Environment 승인 절차 포함)
- [x] state 불일치로 인한 리소스 중복 생성 사고 대응 및 고아 리소스 정리
- [x] S3 Backend + 원격 state로 로컬/CI 환경 통합
- [x] 줄바꿈 문자 차이 문제를 .gitattributes로 방지
- [x] 전체 파이프라인(plan 자동화 → apply 승인 → 배포) 최종 검증 완료
- [ ] ELK SIEM 통합 — 다음 단계
