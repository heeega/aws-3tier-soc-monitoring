# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ⑬ AWS WAF 구축 및 OWASP ZAP 기반 정량 검증

**TL;DR**
- ALB 앞단에 AWS WAF(OWASP 관리형 규칙)를 배포하고, OWASP ZAP으로 적용 전/후 취약점 스캔을 비교했다.
- 검증을 위해 의도적으로 취약한 검색 엔드포인트를 추가했고, WAF 적용 전 발견되었던 Reflected XSS가 적용 후 완전히 차단되는 것을 확인했다.
- 학술 문헌의 FPR/FNR 측정 방법론을 참고해, 소규모 표본으로 WAF의 오탐률·미탐률을 정량화했다.

---

## 1. 왜 애플리케이션 계층 방어가 필요한가

지금까지 구축한 방어(SG, NACL, Lambda 자동 차단)는 모두 네트워크 계층에서 동작한다. IP나 포트 단위로는 판단할 수 있지만, HTTP 요청의 내용(SQL Injection 페이로드, XSS 스크립트 등)까지는 볼 수 없다. AWS WAF는 요청 본문과 파라미터를 검사해 이 계층의 공격을 탐지·차단하며, 이번 단계에서 이를 추가해 심층 방어(Defense in Depth) 구조를 완성했다.

---

## 2. 검증 도구 선택 — OWASP ZAP, Docker 기반

ZAP은 최신 배포판부터 `zap-baseline.py` 등 스캔 스크립트를 tar.gz 패키지에서 제외하고 공식 Docker 이미지 사용을 권장하는 방향으로 전환되었다. 이에 따라 로컬 설치 대신 공식 Docker 이미지(`ghcr.io/zaproxy/zaproxy:stable`)로 스캔을 진행했으며, 이는 최근 실무에서 ZAP을 CI/CD 파이프라인에 통합할 때 흔히 쓰이는 방식이기도 하다.

---

## 3. 검증 대상 — 의도적으로 취약한 엔드포인트 추가

기존 Web 서버는 정적 페이지만 서빙하고 있어 WAF가 검사할 사용자 입력 지점이 없었다. 1차 Baseline Scan 결과 FAIL 0건, WARN 6건(모두 헤더 설정 관련)으로, WAF의 효과를 검증하기에는 부적합한 대상이었다.

이에 사용자 입력을 그대로 반영하고 SQL 쿼리 문자열에 삽입하는 최소한의 취약한 검색 페이지(`search.php`)를 `user_data`에 추가했다. 실제 DB 연결은 시키지 않아 데이터 유출·조작 위험 없이, WAF의 요청 단계 탐지 여부만 검증할 수 있도록 구성했다. 이는 학술 연구에서 WAF 성능 평가 시 의도적으로 취약한 백엔드(vulnerable backend)를 별도로 구성하는 방법론과 같은 접근이다.

---

## 4. WAF 적용 전 — 취약점 존재 확인

Active Scan(zap-full-scan.py)을 `search.php` 대상으로 실행한 결과, Reflected XSS가 실제로 발견되었다.

```
WARN-NEW: Cross Site Scripting (Reflected) [40012] x 1
    .../search.php?q=%3C%2Fh2%3E%3CscrIpt%3Ealert%281%29%3B%3C%2FscRipt%3E%3Ch2%3E (200 OK)
```

> 📸 `105_terraform_apply_search_php_added.png` — 취약한 엔드포인트 배포
> 📸 `106_zap_active_scan_before_waf_vulnerable.png` — WAF 미적용 상태 스캔 결과 (XSS 발견)
> 📸 `111_zap_alert_before_waf_xss_present.png` — alert 목록에 XSS 존재 확인

---

## 5. AWS WAF 배포

ALB에 WAF Web ACL을 연결하고, AWS 관리형 규칙 그룹(Core Rule Set, SQL Injection Rule Set)을 적용했다.

```hcl
rule {
  name     = "AWS-AWSManagedRulesCommonRuleSet"
  ...
}
rule {
  name     = "AWS-AWSManagedRulesSQLiRuleSet"
  ...
}
```

> 📸 `107_terraform_apply_waf_managed_rules.png` — WAF 관리형 규칙 배포 완료

---

## 6. WAF 적용 후 — 동일 공격 재검증

동일한 XSS 요청을 다시 보낸 결과, 이전에 200 OK로 통과했던 요청이 403 Forbidden으로 차단되었다.

```
curl -i ".../search.php?q=%3C%2Fh2%3E%3CscrIpt%3Ealert%281%29%3B%3C%2FscRipt%3E%3Ch2%3E"
→ HTTP/1.1 403 Forbidden
```

> 📸 `108_curl_xss_blocked_after_waf.png` — XSS 요청 차단 확인
> 📸 `110_zap_alert_comparison_xss_gone.png` — 재스캔 결과 alert 목록에서 XSS 사라짐 확인

애플리케이션 코드(`search.php`)는 변경되지 않았으므로, 이는 코드 수정이 아니라 WAF가 요청 단계에서 공격을 차단했기 때문임을 의미한다.

---

## 7. FPR/FNR 정량 평가

WAF 평가는 탐지 여부뿐 아니라 정상 트래픽까지 차단하는 오탐(False Positive) 여부도 함께 확인해야 신뢰할 수 있다. Rathod et al.(2023, arXiv:2311.10450)의 평가 공식을 참고해 다음 지표를 사용했다.

```
False Positive Rate = FP / (FP + TN)
False Negative Rate = FN / (FN + TP)
Precision = TP / (TP + FP)
```

공격 트래픽 5건(SQL Injection 2건, XSS 3건)과 정상 트래픽 6건(일반 검색어)을 각각 전송해 측정했다.

| 구분 | 건수 | 결과 |
|---|---|---|
| TP (공격 · 차단됨) | 5 | 전부 403 |
| FN (공격 · 통과됨) | 0 | 없음 |
| TN (정상 · 통과됨) | 6 | 전부 200 |
| FP (정상 · 차단됨) | 0 | 없음 |

```
FPR = 0/6 = 0%
FNR = 0/5 = 0%
Precision = 5/5 = 100%
```

> 📸 `112_curl_fpr_fnr_test_batch.png` — 공격/정상 트래픽 일괄 테스트 결과

이 수치는 표본 수(N=11)가 학술 연구 수준에 비해 크게 작아, 통계적으로 일반화하기는 어렵다. 다만 AWS 관리형 규칙이 이번 프로젝트의 제한적인 공격·정상 시나리오 내에서는 오탐 없이 의도한 대로 동작함을 확인하는 목적으로는 충분한 근거가 된다.

---

## 8. WAF 로깅 구성 및 상세 검증

WAF 차단 로그를 CloudWatch Logs로 전송하도록 구성해, 향후 ELK 파이프라인 편입이 가능하도록 준비했다.

```hcl
resource "aws_wafv2_web_acl_logging_configuration" "web" {
  resource_arn            = aws_wafv2_web_acl.web.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
}
```

로그를 확인한 결과, 차단 근거가 되는 상세 정보(매칭된 규칙, 공격 패턴, 매칭 데이터)까지 기록되는 것을 확인했다.

```json
{
  "action": "BLOCK",
  "terminatingRuleId": "AWS-AWSManagedRulesSQLiRuleSet",
  "terminatingRuleMatchDetails": [{
    "conditionType": "SQL_INJECTION",
    "location": "ALL_QUERY_ARGS",
    "matchedData": ["", "OR", "1", "=", "1"]
  }]
}
```

> 📸 `113_terraform_apply_waf_logging.png` — WAF 로깅 구성 완료
> 📸 `114_waf_log_sqli_blocked_detail.png` — 차단 상세 로그 (계정 ID, 공격자 IP 모자이크)

---

## 트러블슈팅

| 발생 시점 | 이슈 | 원인 | 해결 |
|---|---|---|---|
| ZAP 설치 시 | `zap-baseline.py` 파일을 찾을 수 없음 | 최신 ZAP 배포판이 스캔 스크립트를 tar.gz에서 제외, Docker 사용 권장으로 전환 | 공식 Docker 이미지(`ghcr.io/zaproxy/zaproxy:stable`)로 전환 |
| ZAP Docker 스캔 실행 시 | 디스크 공간 부족(100%)으로 스캔 실패 | 공격자 EC2(t3.micro, 8GB) 디스크가 ZAP 설치 파일과 Docker 이미지로 가득 참 | 불필요 파일 삭제, EBS 볼륨을 20GB로 확장(`resize2fs`로 파일시스템까지 확장) |
| 1차 Active Scan 시 | XSS 등 실질적 취약점이 전혀 발견되지 않음 | 대상 페이지가 정적 페이지라 사용자 입력 지점이 없음 | 의도적으로 취약한 `search.php` 엔드포인트 추가 |
| 2차 Active Scan 시 | 새로 추가한 `search.php`가 스캔 대상에서 누락됨 | ZAP 스파이더가 `index.html`에 없는 링크는 자동으로 발견하지 못함 | 대상 URL을 `search.php`로 직접 지정 |
| FPR/FNR 측정용 curl 실행 시 | 특수문자가 포함된 요청이 `000`(연결 실패) 응답 | 작은따옴표, 공백 등이 셸에서 URL로 전달되기 전에 깨짐 | 페이로드를 URL 인코딩하여 전송 |

---

## 오늘 진행사항 정리

- [x] AWS WAF Web ACL 생성 및 ALB 연결
- [x] OWASP ZAP(Docker) 설치 및 Baseline/Active Scan 실행
- [x] 검증용 취약한 검색 엔드포인트(`search.php`) 추가
- [x] WAF 미적용 상태에서 Reflected XSS 발견
- [x] AWS 관리형 규칙(Common Rule Set, SQLi Rule Set) 적용
- [x] 동일 공격 요청 재검증 — 차단 확인 (200 → 403)
- [x] FPR/FNR/Precision 정량 측정 (학술 방법론 참고, 소규모 표본 한계 명시)
- [x] WAF 로깅 구성 및 차단 상세 로그 확인
- [x] GitHub 커밋 & 푸시 (`feat: add AWS WAF with managed rules and vulnerable search endpoint for testing`)
- [ ] Elasticvue 연동, WAF 로그의 ELK 파이프라인 편입 — 다음 단계
