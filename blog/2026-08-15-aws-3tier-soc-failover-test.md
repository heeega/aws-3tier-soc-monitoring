# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ⑧ 인프라 재현성 및 장애 시뮬레이션 검증

**TL;DR**
- 전일 종료(`terraform destroy`)했던 인프라를 `terraform apply` 한 번으로 코드 그대로 재현했다 (리소스 44개).
- Web 서버 1대를 강제 종료하는 장애 시뮬레이션을 진행해, Auto Scaling Group이 이를 자동 감지하고 새 인스턴스로 복구하는 과정을 검증했다.
- ALB의 커넥션 드레이닝 메커니즘이 실제로 어떻게 동작하는지 로그로 확인했다.

---

## 1. 인프라 재현성 검증

전일 작업 종료 시 비용 관리를 위해 `terraform destroy`로 모든 리소스를 정리했다. 오늘은 `terraform apply` 한 번으로 VPC부터 SOAR 파이프라인, ALB, Auto Scaling Group까지 전체 인프라(44개 리소스)를 다시 배포했다.

```
Apply complete! Resources: 44 added, 0 changed, 0 destroyed.
```

> 📸 `46_terraform_reapply_full_infra.png` — 전체 인프라 재배포 완료 화면

재구축 후 SNS 이메일 구독을 다시 확인(confirm)하고, ALB DNS 주소로 접속해 Web 서버가 정상 응답하는 것을 확인했다.

> 📸 `47_sns_resubscribe_confirmed.png` — SNS 이메일 재구독 확인 화면

이는 지금까지 모든 인프라를 Terraform 코드로 관리해온 것이 실제로 유효했음을 보여주는 지점이다. 콘솔에서 수동으로 구성했다면 이 과정에 훨씬 오랜 시간이 걸리고 설정 누락 위험도 있었겠지만, 코드 기반 관리 덕분에 동일한 구성을 짧은 시간에 오차 없이 재현할 수 있었다.

---

## 2. 장애 시뮬레이션 — 인스턴스 강제 종료 및 자동 복구

### 목적

Auto Scaling Group과 ALB가 실제 장애 상황에서 의도한 대로 동작하는지 검증한다.

### 진행

**1. 종료 전 상태 확인** — Web 서버 2대 모두 정상(InService/Healthy)인 것을 확인했다.

**2. 인스턴스 강제 종료** — ASG의 정상적인 교체 절차(`terminate-instance-in-auto-scaling-group`)가 아니라, 실제 장애를 재현하기 위해 일반 EC2 종료 명령을 사용했다.

```
aws ec2 terminate-instances --instance-ids <instance-id> --region ap-northeast-2
```

> 📸 `49_ec2_manual_terminate.png` — 강제 종료 명령 실행 화면

### 자동 복구 과정 확인

ASG의 스케일링 활동 로그를 확인한 결과, 다음 두 작업이 동시에 진행된 것을 확인했다.

- **새 인스턴스 생성**: 강제 종료를 감지한 즉시 새 인스턴스 생성을 시작해 5초 만에 완료(Successful, 100%)
- **기존 인스턴스 제거**: ALB의 커넥션 드레이닝(Connection Draining)을 대기하며 진행 중(WaitingForELBConnectionDraining, 50%)

```
"Description": "Launching a new EC2 instance: i-0a2acb5ff7ef8fe59",
"Cause": "...an instance was launched in response to an unhealthy instance needing to be replaced."
"StatusCode": "Successful", "Progress": 100

"Description": "Terminating EC2 instance: i-0bd61e7fef0a96dbd - Waiting For ELB Connection Draining.",
"StatusCode": "WaitingForELBConnectionDraining", "Progress": 50
```

> 📸 `51_asg_scaling_activity_log.png` — 신규 생성 완료 및 드레이닝 대기 로그

새 인스턴스가 완전히 투입된 이후에야 기존 인스턴스가 종료되는 순서로 진행되며, 이 사이 트래픽이 끊기지 않도록 ALB가 드레이닝 시간(약 5분)을 두는 것을 확인했다. 드레이닝 완료 후에는 강제 종료했던 인스턴스가 완전히 목록에서 사라지고, 새 인스턴스를 포함해 다시 2대가 정상(InService/Healthy) 상태로 안정화됐다.

> 📸 `52_asg_recovery_complete.png` — 자동 복구 완료 후 최종 상태

---

## 정리

이번 시뮬레이션으로 확인된 자동 복구 흐름은 다음과 같다.

1. 인스턴스 장애 발생 (강제 종료)
2. ASG가 헬스체크로 이상을 감지
3. 새 인스턴스를 즉시 생성해 목표 대수를 유지
4. ALB가 기존 인스턴스로 향하던 트래픽을 안전하게 정리(드레이닝)한 뒤 완전히 제거
5. 별도의 수동 개입 없이 정상 상태로 복구 완료

이 과정 전체가 자동으로 이루어졌다는 점에서, 이번 프로젝트가 목표로 한 "가용성 확보" 요구사항이 실제로 충족됨을 확인했다.

---

## 오늘 진행사항 정리

- [x] `terraform destroy` 후 `terraform apply`로 전체 인프라(44개 리소스) 재구축
- [x] SNS 이메일 구독 재확인
- [x] Web 서버 1대 강제 종료를 통한 장애 시뮬레이션 진행
- [x] Auto Scaling Group의 자동 감지 및 신규 인스턴스 생성 확인
- [x] ALB 커넥션 드레이닝 메커니즘 확인
- [x] 최종 정상 상태(2대 InService/Healthy)로 복구 완료 검증
- [ ] CI(GitHub Actions) 파이프라인 구축 — 다음 단계
