# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ③ 공격 재현 및 Flow Logs 탐지 검증

**TL;DR**
- Web 서버와 nmap/nikto가 설치된 공격자 EC2를 Terraform으로 배포했다. 배포 과정에서 프리티어 인스턴스 유형 불일치 오류를 확인하고 수정했다.
- 공격자 EC2에서 Web 서버로 `nmap -sV` 스캔을 실행하고, VPC Flow Logs에서 해당 트래픽이 SG 정책에 따라 ACCEPT/REJECT로 기록되는 것을 확인했다.
- 스캔 과정에서 예상치 못하게, Public IP를 인터넷에 노출한 직후부터 전 세계 무작위 스캐닝 트래픽이 유입되는 것도 함께 관찰했다.

---

## 1. Web 서버 및 공격자 EC2 배포

### 구성

- **Web 서버**: Amazon Linux 2023, Public 서브넷, `web-sg` 적용 (공격 대상)
- **공격자 EC2**: Ubuntu 22.04, Public 서브넷, 별도 `attacker-sg` 적용

공격자 EC2에는 Kali Linux 대신 Ubuntu에 `nmap`, `nikto`만 설치하는 방식을 선택했다. 이 결정은 두 가지 근거에 따른 것이다.

1. **비용**: Kali Linux Marketplace AMI는 과금 조건이 인스턴스 유형에 따라 달라질 수 있어 프리티어 보장이 불확실한 반면, Ubuntu는 프리티어 대상이 명확하다.
2. **설계 원칙**: 이번 프로젝트는 필요한 도구만 최소로 구성하고, 그 구성 과정을 코드로 재현 가능하게 만드는 것을 목표로 한다. `user_data` 스크립트로 nmap/nikto 설치를 자동화해, 공격 환경 자체도 IaC로 재현 가능하도록 구성했다.

```hcl
user_data = <<-EOF
            #!/bin/bash
            apt-get update -y
            apt-get install -y nmap nikto
            EOF
```

> 📸 `14_terraform_apply_ec2_success.png` — EC2 2대 배포 완료 화면

### 배포 중 발생한 오류

`terraform apply` 실행 시 아래 오류가 발생했다.

```
Error: creating EC2 Instance: ... InvalidParameterCombination:
The specified instance type is not eligible for Free Tier.
```

`t2.micro`로 지정했던 인스턴스 유형이 이 계정에서는 프리티어 대상이 아니었다. `describe-instance-types` 명령으로 실제 프리티어 대상 유형을 조회한 결과 `t3.micro`가 해당됨을 확인하고, 코드를 수정해 재배포했다.

> 📸 `13_terraform_apply_error_instance_type.png` — 인스턴스 유형 오류 화면

이 과정에서 계정별로 프리티어 대상 인스턴스 유형이 다를 수 있으며, 사전 가정(t2.micro)에 의존하기보다 CLI로 실제 대상을 조회하는 편이 안전하다는 점을 확인했다.

---

## 2. 공격 재현 — nmap 스캔

MobaXterm으로 공격자 EC2에 SSH 접속한 뒤, Web 서버를 대상으로 서비스 버전 탐지 스캔을 실행했다.

```
nmap -sV <Web 서버 Public IP>
```

> 📸 `16_moba_attacker_connected.png` — 공격자 EC2 SSH 접속 화면
> 📸 `17_nmap_nikto_installed.png` — nmap/nikto 설치 버전 확인 화면
> 📸 `18_nmap_scan_result.png` — nmap 스캔 결과 화면

**결과**

```
PORT    STATE  SERVICE VERSION
80/tcp  closed http
443/tcp closed https
Not shown: 998 filtered ports
```

80, 443 포트는 `closed`로 나타났다. 이는 `web-sg`가 해당 포트를 허용하고 있어 SG는 통과했지만, 서버 내부에 실제로 해당 포트를 리스닝하는 웹 서버 프로세스가 없어 애플리케이션 계층에서 응답이 거부된 상태를 의미한다. 나머지 998개 포트는 `filtered`로 나타났는데, 이는 `web-sg`가 해당 포트를 원천적으로 차단해 nmap이 응답 자체를 받지 못한 상태다.

---

## 3. VPC Flow Logs를 통한 탐지 검증

CloudWatch Logs Insights에서 공격자 EC2의 Public IP를 기준으로 로그를 필터링해, 방금 실행한 스캔이 실제로 기록되었는지 확인했다.

```
fields @timestamp, @message
| filter @message like "<공격자 Public IP>"
| sort @timestamp desc
| limit 20
```

> 📸 `19_flowlog_attacker_scan_evidence.png` — 공격자 IP 기준 Flow Logs 필터링 결과

**결과 해석**

- 80번 포트로 향한 트래픽은 `ACCEPT`로 기록됨 — SG가 80번 포트를 허용하고 있음을 네트워크 계층에서 재확인
- 80/443 외 포트(예: 8000, 8402, 16992 등)로 향한 트래픽은 `REJECT`로 기록됨 — SG가 해당 포트를 차단하고 있음을 로그로 직접 확인

nmap 결과(애플리케이션 계층 관점의 open/closed/filtered)와 Flow Logs 결과(네트워크 계층 관점의 ACCEPT/REJECT)를 상관분석함으로써, "SG가 80/443만 허용하고 나머지는 차단한다"는 설계가 의도대로 동작하고 있음을 두 가지 관점에서 교차 검증했다.

---

## 트러블슈팅

| 발생 시점 | 이슈 | 원인 | 해결 |
|---|---|---|---|
| `security_groups.tf` 확장 시 | `terraform plan` 실행 시 "Reference to undeclared resource" 오류 | `ec2.tf`에서 참조한 `aws_security_group.attacker`가 `security_groups.tf`에 정의되지 않음 | 누락된 `attacker` 보안 그룹 리소스 블록 추가 |
| `terraform apply` 실행 시 | 인스턴스 생성 실패 (Free Tier 대상 아님) | `t2.micro`가 이 계정에서는 프리티어 대상이 아님 | `describe-instance-types`로 조회해 `t3.micro`로 변경 |
| SSH 접속 시 | MobaXterm 접속 타임아웃 | 접속 환경이 바뀌면서 공인 IP가 변경되어 SG의 `admin_ips`에 포함되지 않음 | 새 IP를 `admin_ips` 리스트에 추가 후 재적용 |

세 번째 이슈는 이전 단계에서 `admin_ips`를 리스트 타입 변수로 미리 분리해둔 설계가 실제로 도움이 된 사례였다. 값 추가와 `terraform apply` 한 번으로 대응이 끝났다.

---

## 추가로 관찰한 점

Web 서버의 Public IP를 대상으로 Flow Logs를 전체 조회하는 과정에서, 우리가 실행한 스캔 외에도 전 세계 각지의 IP로부터 SSH(22), Telnet(23), RDP(3389) 등 포트를 겨냥한 REJECT 트래픽이 지속적으로 발생하는 것을 확인했다. Public IP를 인터넷에 노출하는 순간부터 자동화된 스캐닝이 즉시 시작된다는 점, 그리고 `admin_ips` 기반 SG 제한이 이러한 무작위 접근 시도를 실제로 차단하고 있다는 점을 별도의 조작 없이 관찰할 수 있었다.

---

## 오늘 진행사항 정리

- [x] Web 서버(Amazon Linux 2023) 및 공격자 EC2(Ubuntu 22.04 + nmap/nikto) Terraform 배포
- [x] 프리티어 인스턴스 유형 오류 확인 및 수정
- [x] MobaXterm으로 공격자 EC2 SSH 접속 및 admin_ips 갱신 대응
- [x] nmap을 이용한 Web 서버 포트 스캔 재현
- [x] CloudWatch Logs Insights로 스캔 트래픽의 Flow Logs 기록 확인 및 SG 정책 교차 검증
- [x] GitHub 커밋 & 푸시 (`feat: deploy web/attacker EC2 instances and verify attack detection via flow logs`)
- [ ] nikto를 이용한 웹 취약점 스캔 및 애플리케이션 계층 로그 확인 — 다음 단계
