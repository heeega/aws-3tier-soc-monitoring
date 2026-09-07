# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ④ 웹 취약점 스캔 및 하드닝

**TL;DR**
- Web 서버에 Apache를 설치하고, nikto로 웹 취약점 스캔을 실행해 6개 항목을 발견했다.
- 이 중 TRACE 메서드 활성화와 X-Frame-Options 헤더 누락 2건을 코드 수준에서 조치하고, 재스캔으로 개선을 확인했다.
- "취약점 발견 → 원인 분석 → 코드 수정 → 재검증"의 사이클을 인프라 코드 변경만으로 완결했다.

---

## 1. Web 서버에 Apache 설치

지금까지는 네트워크 계층(VPC, SG)만 구축된 상태였고, Web 서버에는 실제로 요청에 응답할 애플리케이션이 없었다. `ec2.tf`의 `user_data`에 Apache 설치 스크립트를 추가했다.

```hcl
user_data = <<-EOF
            #!/bin/bash
            dnf update -y
            dnf install -y httpd
            systemctl enable httpd
            systemctl start httpd
            echo "<h1>SOC 3-tier Toy Project - Web Tier</h1>" > /var/www/html/index.html
            EOF
```

이미 실행 중인 인스턴스는 `user_data`를 수정해도 재실행되지 않는다. `user_data`는 인스턴스의 최초 부팅 시에만 실행되도록 설계되어 있기 때문이다. 따라서 `terraform apply -replace="aws_instance.web"` 명령으로 인스턴스를 명시적으로 재생성해, 변경된 `user_data`가 반영되도록 했다.

> 📸 `20_terraform_replace_web_apply.png` — 인스턴스 재생성 완료 화면
> 📸 `21_web_apache_running.png` — 브라우저에서 Apache 응답 확인 화면

---

## 2. nikto 웹 취약점 스캔 — 1차

공격자 EC2에서 Web 서버를 대상으로 nikto를 실행했다.

```
nikto -h http://<Web 서버 Public IP>
```

**결과 (6개 항목 발견)**

| 발견 항목 | 내용 |
|---|---|
| Server 헤더 노출 | `Apache/2.4.68 (Amazon Linux)` 버전 정보가 응답 헤더에 그대로 노출 |
| ETag를 통한 inode 노출 | 파일 내부 식별자가 헤더로 노출 |
| X-Frame-Options 헤더 누락 | 클릭재킹 방어 헤더 미설정 |
| TRACE 메서드 활성화 | XST(Cross-Site Tracing) 공격에 악용 가능 |
| `/icons/` 디렉토리 인덱싱 | 디렉토리 내 파일 목록 노출 |
| `/icons/README` 노출 | Apache 기본 설치 문서 파일 노출 |

> 📸 `22_nikto_scan_result.png` — 1차 스캔 결과 화면

이 결과는 Apache를 기본 설정(`dnf install httpd`)만으로 설치했을 때 어떤 항목들이 기본적으로 노출되는지를 실제로 확인한 것이다.

---

## 3. 하드닝 적용

발견된 6개 항목 중, 실제 공격 기법과 직접 연결되는 2개 항목을 우선 조치 대상으로 선정했다.

- **TRACE 메서드 비활성화**: HTTP TRACE 메서드는 XST 공격에 악용될 수 있어 비활성화 대상으로 선정
- **X-Frame-Options 헤더 추가**: 클릭재킹 방어를 위해 `SAMEORIGIN` 값으로 헤더 추가

나머지 4개 항목(서버 버전 노출, ETag 노출, `/icons/` 관련 2건)은 정보 노출 성격이 강하고, 이번 단계의 핵심 시나리오(공격 탐지)와 직접적 연관성이 낮다고 판단해 조치 범위에서 제외했다.

조치 역시 서버에 직접 접속해 설정 파일을 수정하는 대신, `user_data`에 반영해 코드로 재현 가능하도록 구성했다.

```hcl
user_data = <<-EOF
            #!/bin/bash
            dnf update -y
            dnf install -y httpd
            systemctl enable httpd

            # Harden: disable TRACE method (XST 방지)
            echo "TraceEnable off" >> /etc/httpd/conf/httpd.conf

            # Harden: add clickjacking protection header
            echo "Header always append X-Frame-Options SAMEORIGIN" >> /etc/httpd/conf/httpd.conf

            systemctl start httpd
            echo "<h1>SOC 3-tier Toy Project - Web Tier</h1>" > /var/www/html/index.html
            EOF
```

> 📸 `23_terraform_apply_hardening.png` — 하드닝 반영 후 재배포 완료 화면

---

## 4. nikto 재스캔 — 개선 검증

동일한 명령으로 재스캔을 실행해 조치 결과를 확인했다.

| 항목 | 조치 전 | 조치 후 |
|---|---|---|
| X-Frame-Options 헤더 | 없음 | `SAMEORIGIN` 설정 확인 |
| Allowed HTTP Methods | `..., TRACE` 포함 | `GET, POST, OPTIONS, HEAD` — TRACE 제거 확인 |
| 전체 리포트 항목 수 | 6개 | 5개 |

> 📸 `24_nikto_scan_result_after_hardening.png` — 재스캔 결과 화면

두 조치 모두 의도대로 반영되었음을 스캔 결과로 직접 확인했다.

---

## 오늘 진행사항 정리

- [x] Web 서버에 Apache 설치 (`user_data` 자동화, 인스턴스 재생성으로 반영)
- [x] nikto 1차 스캔으로 취약점 6건 발견
- [x] TRACE 메서드 비활성화, X-Frame-Options 헤더 추가 (코드 기반 하드닝)
- [x] nikto 재스캔으로 조치 항목 2건 해소 확인 (6건 → 5건)
- [x] GitHub 커밋 & 푸시 (`feat: install Apache on web server and harden against nikto findings`)
- [ ] Anti-DDoS 탐지 로직 설계 및 Lambda 기반 자동 차단(SOAR) 구현 — 다음 단계
