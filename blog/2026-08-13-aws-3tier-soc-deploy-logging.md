# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ② 인프라 배포 및 로그 수집 체계 구축

**TL;DR**
- 전날 설계한 3-tier VPC 네트워크를 `terraform init → plan → apply`로 실제 배포했다. 배포 중 보안 그룹 `description` 필드의 한글 사용 제약으로 인한 오류를 확인하고 수정했다.
- CloudTrail(API 호출 로그)과 VPC Flow Logs(네트워크 트래픽 로그)를 설정해 공격 재현 이전에 로그 수집 체계를 먼저 구축했다.
- 다음 단계는 nmap/nikto를 이용한 공격 재현과, 수집된 로그에서 탐지 흔적을 확인하는 작업이다.

---

## 1. Terraform 인프라 배포

### init / plan / apply

`terraform init`으로 AWS provider를 초기화한 뒤, `terraform plan`으로 실제 적용 전 변경 계획을 확인했다. 계획 결과는 `Plan: 21 to add, 0 to change, 0 to destroy`로, VPC 1개, IGW 1개, 서브넷 6개, NAT Gateway 1개, EIP 1개, 라우트 테이블 2개, 라우트 테이블 연결 6개, 보안 그룹 3개를 합한 예상 리소스 수와 정확히 일치했다.

> 📸 `04_terraform_init_success.png` — `terraform init` 성공 화면
> 📸 `05_terraform_plan_output.png` — `Plan: 21 to add...` 요약 화면

이후 `terraform apply`로 실제 배포를 진행했다.

### 배포 중 발생한 오류

```
Error: "ingress.1.description" doesn't comply with restrictions
("^[0-9A-Za-z_ .:/()#,@\[\]+=&;{}!$*-]*$"): "SSH from Web tier (bastion 경유 시)"
```

WAS 보안 그룹의 인바운드 규칙 `description` 필드에 한글("경유 시")을 포함시킨 것이 원인이었다. AWS 보안 그룹의 `description` 필드는 영문·숫자 및 일부 특수문자만 허용하며, 이 제약은 변수 설명(`variable` 블록의 `description`)이나 코드 주석에는 적용되지 않고 AWS 리소스에 직접 등록되는 필드에만 적용된다.

> 📸 `06_terraform_apply_error_sg_description.png` — 오류 발생 화면

해당 문구를 영문으로 수정한 뒤 재배포했다.

```hcl
description = "SSH from Web tier (bastion)"
```

Terraform은 이미 생성이 완료된 리소스는 재생성하지 않고, 실패로 중단된 리소스만 이어서 생성한다. 재실행 결과는 `Apply complete! Resources: 2 added, 0 changed, 0 destroyed`로, 오류로 중단됐던 WAS/DB 보안 그룹 2개만 추가 생성됐다.

> 📸 `07_terraform_apply_success.png` — 재배포 성공 화면

### 배포 결과 검증

`terraform state list`로 Terraform이 관리 중인 리소스 목록을 확인한 결과, 설계한 21개 리소스가 모두 존재함을 확인했다. 이후 AWS 콘솔에서 VPC CIDR, 서브넷 6개, 라우트 테이블의 라우팅 설정, 보안 그룹 간 참조 관계(WAS SG의 인바운드 소스가 Web SG로 지정되어 있는지 등)를 직접 대조해 코드와 실제 배포 상태가 일치함을 확인했다.

> 📸 `08_terraform_state_list_final.png` — 리소스 목록 최종 확인 화면

---

## 2. 로그 수집 체계 구축

공격 재현에 앞서, 탐지 근거가 될 로그 수집 체계를 먼저 구성했다.

### CloudTrail

CloudTrail은 계정 내 API 호출 이력(누가 어떤 리소스를 생성·수정·삭제했는지)을 기록한다. 콘솔의 빠른 추적 생성 기능을 사용해 다중 리전 추적(`soc-3tier-trail`)을 구성했으며, 로그는 자동 생성된 S3 버킷에 저장된다.

> 📸 `09_cloudtrail_created.png` — CloudTrail 추적 생성 완료 화면

### VPC Flow Logs

VPC Flow Logs는 네트워크 인터페이스를 오가는 트래픽의 IP, 포트, 프로토콜, 허용/거부 여부를 기록한다. CloudTrail이 API 호출 계층을 기록한다면, Flow Logs는 네트워크 계층의 트래픽을 기록하므로, 이후 진행할 nmap/nikto 공격 재현 시 스캐닝 시도를 확인하는 근거 자료가 된다.

설정은 다음과 같이 구성했다.

- 필터: 전체(허용/거부 트래픽 모두 기록)
- 최대 집계 간격: 1분(기본 10분보다 짧게 설정해 탐지 지연을 최소화)
- 대상: CloudWatch Logs (추후 Lambda 기반 자동 대응과 연동할 계획을 고려해 선택)

> 📸 `10_vpc_flowlogs_created.png` — VPC Flow Logs 생성 완료 화면

### 로그 저장 정책에 대한 보완 계획

현재 CloudTrail은 S3에, VPC Flow Logs는 CloudWatch Logs에 저장되도록 구성했다. 실무에서는 두 로그 모두 CloudWatch Logs(실시간 모니터링·알람 연동)와 S3(장기 보관·감사 대응) 양쪽에 이중으로 저장하는 구성이 일반적이다. 이번 단계에서는 실시간 탐지 검증을 우선 목표로 두어 이중화를 적용하지 않았으며, 이후 ELK 연동 단계에서 S3 이중 저장을 실무 표준 반영 항목으로 추가할 예정이다.

---

## 트러블슈팅

| 발생 시점 | 이슈 | 원인 | 해결 |
|---|---|---|---|
| `terraform apply` 실행 중 | 보안 그룹 생성 실패 | SG `description` 필드에 한글 포함 — AWS가 허용하는 문자 패턴(`^[0-9A-Za-z_ .:/()#,@\[\]+=&;{}!$*-]*$`)에 위배 | `description` 값을 영문으로 수정 후 재배포. Terraform이 기존 생성 리소스는 재생성하지 않고 실패한 리소스만 이어서 생성하는 것을 확인 |

---

## 오늘 진행사항 정리

- [x] `terraform init` / `plan` / `apply`로 3-tier VPC 인프라 21개 리소스 배포 완료
- [x] 보안 그룹 description 필드 오류 확인 및 수정
- [x] `terraform state list` 및 AWS 콘솔 대조로 배포 상태 검증
- [x] CloudTrail 추적 생성 (API 호출 로그 수집)
- [x] VPC Flow Logs 생성 (네트워크 트래픽 로그 수집, CloudWatch Logs 대상)
- [x] GitHub 커밋 & 푸시 (`fix: replace Korean SG description with English to satisfy AWS naming restriction`)
- [ ] nmap/nikto를 이용한 공격 재현 및 로그 탐지 확인 — 다음 단계
