# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ⑦ ALB + Auto Scaling 구축

**TL;DR**
- 단일 EC2로 운영되던 Web 서버를 Launch Template + Auto Scaling Group + ALB 구조로 전환해, 단일 장애점(SPOF)을 제거하고 가용성을 확보했다.
- `user_data` 스크립트의 셔뱅(`#!/bin/bash`) 줄 앞에 들여쓰기 공백이 남아 cloud-init 실행 자체가 실패하는 문제를 진단하고 해결했다.
- 이 과정에서 Auto Scaling Group이 반복적으로 인스턴스를 교체하는 상황을 직접 겪고, `suspend-processes`로 긴급 정지한 뒤 원인을 해결하는 실전 트러블슈팅을 경험했다.

---

## 1. 왜 ALB + Auto Scaling인가

기존 구조는 Web 서버가 EC2 1대뿐이라, 이 서버에 장애가 발생하면 서비스 전체가 중단되는 단일 장애점(SPOF)이 존재했다. 이를 해결하기 위해 다음 구조로 전환했다.

- **Launch Template**: EC2 스펙을 템플릿화해, Auto Scaling Group이 이를 기반으로 인스턴스를 생성하도록 함
- **Auto Scaling Group**: 최소 2대, 최대 4대를 유지하며 장애 발생 시 자동으로 인스턴스를 교체
- **ALB(Application Load Balancer)**: 여러 대의 Web 서버로 트래픽을 분산하고, 헬스체크로 비정상 인스턴스를 트래픽 대상에서 자동 제외
- **CPU 기반 Target Tracking 정책**: 평균 CPU 사용률 50%를 목표로 자동 확장/축소

각 서버가 응답할 때 자신의 인스턴스 ID를 표시하도록 `index.html`을 구성해, 로드밸런싱이 실제로 여러 대에 분산되고 있는지 육안으로 확인할 수 있게 했다.

> 📸 `42_terraform_apply_alb_asg_success.png` — ALB, Target Group, ASG 등 8개 리소스 배포 완료 화면

---

## 2. 트러블슈팅 — user_data 스크립트 실행 실패

### 증상

새로 생성된 인스턴스가 계속 Target Group에서 Unhealthy로 표시되고, Auto Scaling Group이 이를 자동으로 종료하고 새 인스턴스를 만드는 과정을 반복했다.

### 1차 원인 추정 — IMDSv2

처음에는 인스턴스 메타데이터(Instance ID)를 조회하는 과정에서 IMDSv2(토큰 기반 메타데이터 조회)를 사용하지 않아 실패한 것으로 추정하고, 토큰 발급 로직을 추가했다.

```bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
```

그러나 이 수정 후에도 문제가 재현되어, 근본 원인이 다른 곳에 있음을 확인했다.

### 실제 원인 — 셔뱅 줄의 들여쓰기

Unhealthy 인스턴스에 직접 SSH 접속해 `cloud-init` 로그를 확인한 결과, `scripts-user` 모듈 자체가 실행에 실패한 것으로 나타났다.

```
2026-08-14 10:46:19,959 - cc_scripts_user.py[WARNING]: Failed to run module scripts-user
```

실제로 실행하려던 스크립트 파일(`/var/lib/cloud/instance/scripts/`)을 확인하니, 첫 줄이 다음과 같이 공백으로 시작하고 있었다.

```
              #!/bin/bash
```

셔뱅(`#!`)은 파일의 맨 첫 글자부터 정확히 시작해야 인터프리터로 인식되며, 앞에 공백이 있으면 일반 텍스트로 처리되어 스크립트 전체가 실행되지 않는다. Terraform의 `<<-EOF` 히어독 문법은 공통 들여쓰기를 자동 제거해주지만, 에디터에서 들여쓰기가 일관되지 않게 저장되며 이 제거가 정상 동작하지 않은 것이 원인이었다.

> 📸 `43_userdata_shebang_indentation_error.png` — 들여쓰기가 남아있는 스크립트 원본 확인

### 해결

`user_data` 블록 내 스크립트 본문 전체를 왼쪽 정렬로 재작성해, 셔뱅 줄이 파일 맨 앞에서 시작하도록 수정했다.

```hcl
user_data = base64encode(<<-EOF
#!/bin/bash
dnf update -y
dnf install -y httpd
...
EOF
)
```

수정 후 새로 생성된 인스턴스에서 스크립트가 정상 반영된 것을 확인했다.

> 📸 `44_userdata_fixed_confirmed.png` — 수정된 스크립트 정상 반영 확인

---

## 3. 부가 트러블슈팅 — Instance Refresh 반복 실패

문제 해결 전, Auto Scaling Group에 Instance Refresh를 요청한 상태였기 때문에, 잘못된 스크립트를 가진 인스턴스가 계속 생성과 종료를 반복하는 상황이 발생했다. 이를 막기 위해 헬스체크와 자동 교체 프로세스를 일시 정지시켰다.

```
aws autoscaling suspend-processes --auto-scaling-group-name soc-3tier-web-asg --scaling-processes HealthCheck ReplaceUnhealthy --region ap-northeast-2
```

스크립트 수정 후에는 프로세스를 재개하고 Instance Refresh를 재시도했다. 이 과정에서 이미 생성되어 있던 구버전 인스턴스가 새 Launch Template을 자동으로 반영하지 않는 것을 확인해, 해당 인스턴스를 수동으로 강제 교체했다.

```
aws autoscaling terminate-instance-in-auto-scaling-group --instance-id <id> --no-should-decrement-desired-capacity --region ap-northeast-2
```

---

## 4. 최종 검증

ALB DNS 주소로 접속해 새로고침을 반복한 결과, 서로 다른 Instance ID가 응답하는 것을 확인해 로드밸런싱이 정상 동작함을 검증했다.

> 📸 `45_alb_loadbalancing_confirmed.png` — 서로 다른 인스턴스가 응답하는 것을 확인한 화면

---

## 트러블슈팅

| 발생 시점 | 이슈 | 원인 | 해결 |
|---|---|---|---|
| ALB/ASG 배포 후 | 새 인스턴스가 계속 Unhealthy로 표시되고 반복 교체됨 | `user_data` 스크립트의 셔뱅 줄 앞에 들여쓰기 공백이 남아 cloud-init의 스크립트 실행 모듈 자체가 실패 | 스크립트 본문을 왼쪽 정렬로 재작성 |
| 원인 조사 중 | Instance Refresh가 실패한 인스턴스를 계속 생성·종료하며 반복됨 | 잘못된 스크립트가 반영된 상태로 Refresh가 진행 중이었음 | `suspend-processes`로 자동 교체를 일시 정지, 수정 후 재개 |
| 수정 후 재검증 시 | 이미 생성된 구버전 인스턴스가 새 Launch Template을 반영하지 않음 | Launch Template 변경은 신규 생성 인스턴스에만 적용되며 기존 인스턴스는 자동 갱신되지 않음 | `terminate-instance-in-auto-scaling-group`으로 해당 인스턴스를 수동 강제 교체 |

이번 트러블슈팅은 "설정 파일을 수정했음에도 문제가 재현되는" 상황의 원인이 이미 생성되어 있던 리소스가 새 설정을 반영하지 않아서였다는 점에서, 실제 운영 환경에서도 자주 발생하는 유형의 장애였다.

---

## 오늘 진행사항 정리

- [x] 단일 EC2를 Launch Template + Auto Scaling Group 구조로 전환
- [x] ALB, Target Group 구축 (헬스체크 및 S3 Access Log 구성 포함)
- [x] CPU 기반 Target Tracking 스케일링 정책 추가
- [x] user_data 스크립트 실행 실패 원인(셔뱅 줄 들여쓰기) 진단 및 수정
- [x] Instance Refresh 반복 실패 상황을 `suspend-processes`로 긴급 대응
- [x] ALB를 통한 로드밸런싱 정상 동작 최종 검증
- [x] GitHub 커밋 & 푸시 (`feat: replace single web instance with ALB and Auto Scaling Group`)
- [ ] 장애 시뮬레이션(인스턴스 강제 종료 후 자동 복구 확인) — 다음 단계
