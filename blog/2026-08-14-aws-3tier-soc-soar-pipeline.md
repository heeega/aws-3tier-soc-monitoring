# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ⑤ SOAR 파이프라인 구축 및 탐지 임계값 튜닝

**TL;DR**
- SG(상시 화이트리스트) + NACL(이상 탐지 시 동적 블랙리스트)로 심층 방어(Defense in Depth) 구조를 완성하고, CloudWatch Alarm과 Lambda로 자동 차단(SOAR) 파이프라인을 구축했다.
- 초기 임계값(1분당 REJECT 15건)이 실제 배경 트래픽보다 낮게 설정되어 상시 오탐이 발생하는 것을 확인했다.
- 배경 트래픽을 실측(약 35건/분)한 뒤, 이를 근거로 임계값을 100건으로 재조정하고, 탐지→알림→자동 차단 전체 파이프라인이 정상 동작함을 재검증했다.

---

## 1. SOAR 파이프라인 설계

이번 단계의 목표는 이상 트래픽을 사람 개입 없이 자동으로 차단하는 구조를 만드는 것이다. 구성은 다음과 같다.

1. **탐지**: CloudWatch Metric Filter — VPC Flow Logs에서 REJECT 로그를 집계해 지표로 변환
2. **알람**: CloudWatch Alarm — 지표가 임계값을 초과하면 발동
3. **알림**: SNS Topic — 알람 발생 시 이메일로 통보
4. **자동 대응**: Lambda — SNS를 트리거로 받아 최근 1분간 REJECT가 가장 많은 IP를 조회하고, 해당 IP를 차단
5. **기록**: Lambda 실행 로그에 차단 시각·대상 IP를 남겨 사후 감사 대응 근거로 활용

### 왜 SG가 아닌 NACL로 차단하는가

Security Group은 허용(Allow) 규칙만 지원하는 화이트리스트 방식이라, 특정 IP를 명시적으로 차단하는 기능이 없다. 반면 Network ACL은 허용과 거부(Deny)를 모두 지원하는 서브넷 단위 방화벽으로, 블랙리스트 방식의 동적 차단에 적합하다.

이에 따라 이번 프로젝트는 **SG(인스턴스 단위, 상시 화이트리스트)와 NACL(서브넷 단위, 이상 탐지 시 동적으로 추가되는 블랙리스트)을 함께 사용하는 심층 방어(Defense in Depth) 구조**로 설계했다. SG가 평상시 최소 권한 원칙에 따른 상시 방어를 담당하고, NACL은 이상 트래픽 탐지 시에만 개입하는 대응형 방어 계층으로 역할을 분리했다.

### 자동화 원칙

Lambda 코드 역시 콘솔에서 직접 작성하지 않고 레포 내 `lambda/` 폴더에 파일로 관리하고, Terraform의 `archive_file`로 자동 패키징해 배포했다. IAM 권한도 Lambda가 실제로 필요로 하는 3가지(로그 기록, Flow Logs 쿼리, NACL 규칙 추가)로 최소화했다.

> 📸 `25_terraform_init_archive_provider.png` — archive 프로바이더 초기화 화면
> 📸 `26_terraform_plan_lambda_soar.png` — SOAR 관련 리소스 12개 plan 결과
> 📸 `27_terraform_apply_lambda_soar_success.png` — 배포 완료 화면
> 📸 `28_sns_subscription_confirmed.png` — SNS 이메일 구독 확인 화면

---

## 2. 배포 중 발생한 오류 — 로그 그룹명 오타

Lambda 코드에 Flow Logs 로그 그룹명을 `/soc-3tier-flowlogs`로 잘못 기재해, Flow Logs 조회 단계에서 `ResourceNotFoundException`이 발생했다. 실제 로그 그룹명은 앞에 슬래시가 없는 `soc-3tier-flowlogs`였다.

> 📸 `33_lambda_log_error_loggroup.png` — 로그 그룹 조회 실패 오류

코드를 수정하고 Terraform으로 재배포해 해결했다.

---

## 3. 1차 검증 — 임계값 설정 오류 발견

공격자 EC2에서 `nmap -T4 -p 1-1000`으로 넓은 포트 범위를 빠르게 스캔해 REJECT 트래픽을 유발시켰다.

**결과**: 알람이 정상적으로 발동(1분간 REJECT 57건, 임계값 15건 초과)했고 이메일도 정상 수신되었다. 그러나 이후 시간이 지나도 알람 상태가 계속 "ALARM"에서 내려오지 않았고, 재스캔을 실행해도 Lambda가 트리거되지 않는 문제가 발생했다.

> 📸 `30_cloudwatch_alarm_in_alarm.png` — 알람 발동 화면
> 📸 `31_cloudwatch_alarm_email.png` — 알람 이메일

### 원인 진단

CloudWatch Alarm은 상태가 전이(OK↔ALARM)될 때만 SNS로 알림을 보낸다. 이미 ALARM 상태를 유지 중이면 추가 알림이 발생하지 않는다.

Metrics에서 `soc-3tier-RejectedTrafficCount` 지표를 통계 "합계", 기간 "1분"으로 조회한 결과, **평상시(공격이 없는 상태)에도 배경 트래픽으로 인해 REJECT가 분당 약 35건 상시 발생**하고 있음을 확인했다. 이는 최초 설정한 임계값(15건)보다 높은 값으로, 임계값이 배경 잡음보다 낮게 설정되어 있었던 것이 근본 원인이었다.

> 📸 `32_nacl_inbound_before_lambda.png` — 최초 NACL 상태(차단 규칙 없음)

---

## 4. 임계값 재조정

배경 트래픽(약 35건/분)과 nmap 스캔 시 관측값(2,050건/분)의 격차가 뚜렷했으므로, 배경 최댓값 대비 약 3배의 안전마진을 두어 임계값을 **100건**으로 재조정했다.

```hcl
threshold = 100
alarm_description = "1분 내 REJECT 트래픽이 100건 이상 발생 시 알람. 초기값 15건은 실측 결과 배경 트래픽(평상시 약 35건/분)보다 낮아 상시 오탐 발생, 배경 최댓값 대비 약 3배 마진을 둔 100건으로 재조정"
```

재조정 후 알람 상태가 정상적으로 OK로 복귀하는 것을 확인했다.

> 📸 `34_cloudwatch_alarm_ok_after_retuning.png` — 재조정 후 OK 상태 복귀 화면

---

## 5. 2차 검증 — 전체 파이프라인 정상 동작 확인

동일한 스캔을 재실행한 결과, 이번에는 OK→ALARM 전이가 정상적으로 발생(1분간 REJECT 4,038건, 임계값 100건 초과)했다.

> 📸 `35_cloudwatch_alarm_in_alarm_retest.png` — 재발동 화면
> 📸 `36_cloudwatch_alarm_email_retest.png` — 재검증 알람 이메일

Lambda 로그를 확인한 결과, 해당 시점 REJECT가 가장 많았던 IP(`77.91.71.10`, 배경 스캐너 트래픽 중 하나)를 정상적으로 조회해 NACL에 차단 규칙을 추가했다.

```
[AUTO-BLOCK] IP 77.91.71.10 를 NACL 규칙 50번으로 차단했습니다.
```

> 📸 `37_lambda_autoblock_success.png` — Lambda 자동 차단 실행 로그
> 📸 `38_nacl_autoblock_rule_confirmed.png` — NACL에 반영된 차단 규칙 확인

차단 대상이 우리가 만든 공격자 EC2가 아니라 실제 배경 스캐너 IP로 잡힌 것은, Lambda가 "해당 시점 가장 위협적인 트래픽"을 정확히 식별해 대응했다는 점에서 오히려 의도된 로직이 올바르게 동작했음을 보여준다.

---

## 트러블슈팅

| 발생 시점 | 이슈 | 원인 | 해결 |
|---|---|---|---|
| Lambda 배포 후 실행 시 | Flow Logs 조회 실패 (`ResourceNotFoundException`) | 로그 그룹명 오타 (`/soc-3tier-flowlogs` → 실제로는 `soc-3tier-flowlogs`) | 코드 수정 후 재배포 |
| 1차 검증 시 | 알람이 재발동하지 않고 상시 ALARM 상태 유지 | 초기 임계값(15건)이 배경 트래픽(평상시 약 35건/분)보다 낮게 설정되어 상시 오탐 발생 | Metrics로 배경 트래픽 실측 후, 배경 최댓값 대비 3배 마진을 적용해 임계값을 100건으로 재조정 |

---

## 오늘 진행사항 정리

- [x] NACL 기반 동적 차단 구조 설계 및 배포 (SG+NACL Defense in Depth 구조 완성)
- [x] CloudWatch Metric Filter, Alarm, SNS Topic, Lambda 자동 차단 파이프라인 구축
- [x] Lambda 로그 그룹명 오류 확인 및 수정
- [x] 초기 임계값(15건) 설정 오류를 실제 배경 트래픽 관측을 통해 진단
- [x] 임계값을 100건으로 재조정하고 파이프라인 재검증 (탐지 → 알림 → 자동 차단 → 기록 전 과정 확인)
- [x] GitHub 커밋 & 푸시 (`feat: implement SOAR pipeline with NACL, Lambda auto-block, and CloudWatch alarm tuning`)
- [ ] GuardDuty 활성화 (결제 수단 검증 완료 후 별도 진행 예정)
