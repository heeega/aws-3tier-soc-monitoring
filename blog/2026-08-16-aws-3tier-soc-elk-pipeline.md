# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ⑪ ELK 스택 구축 및 실시간 로그 파이프라인

**TL;DR**
- Private 서브넷에 최소 사양(t3.micro)으로 Elasticsearch + Kibana를 Docker로 구축하고, Bastion Host를 경유한 SSH 접근 체계를 구성했다.
- CloudWatch Logs 구독 필터와 VPC 내부에 배치한 Lambda를 이용해, VPC Flow Log를 실시간으로 Elasticsearch에 색인하는 서버리스 파이프라인을 만들었다.
- 보안 그룹 재생성 과정에서 삭제가 10분 이상 멈추는 문제를 겪었고, 리소스 재설계와 수동 개입으로 근본 원인을 해결했다.

---

## 1. 설계 방향

### 왜 Docker이고, 왜 Private 서브넷인가

ELK는 Amazon OpenSearch Service 같은 관리형 서비스로도 구축할 수 있지만, 이번 프로젝트는 필요한 만큼만 구성하고 그 구성 과정을 직접 설명할 수 있게 하는 것을 원칙으로 삼고 있어 EC2에 Docker로 직접 설치하는 방식을 택했다.

Kibana는 관리자만 접근할 자산이므로 인터넷에 노출하지 않는 것이 원칙이다. 이에 따라 ELK 서버는 Private 서브넷(WAS 계층)에 배치하고, 기존에 구축해둔 Web 서버(Bastion 겸용)를 통해서만 접근하도록 보안 그룹을 구성했다. Kibana 접근은 SSH 로컬 포트 포워딩으로 처리했다. 실무에서는 이 구간을 VPN이나 SSO 인증 프록시로 대체하지만, 이번 프로젝트 규모에서는 SSH 터널링이 "비공개 접근"이라는 동일한 보안 원칙을 충족하는 실용적인 선택이었다.

### 인스턴스 사양 제약

ELK용으로는 t3.medium(4GB RAM) 이상을 계획했으나, 계정이 결제 수단 검증 전 무료 플랜 상태라 프리티어 외 인스턴스 생성 자체가 차단되었다. 결제 검증 완료까지 예측할 수 없는 대기 시간이 필요했으므로, t3.micro(1GB RAM)로 축소하고 다음과 같이 최소 구성을 적용했다.

- Elasticsearch JVM 힙 메모리를 256MB로 제한
- 2GB 스왑 파일을 생성해 물리 메모리 부족을 완충
- Logstash 대신, 로그 수집을 서버리스(Lambda) 방식으로 대체해 ELK 서버의 메모리 부담 자체를 줄임

---

## 2. Bastion 경유 접근 체계 구축

Private 서브넷의 ELK 서버에 접근하기 위해 Web 서버를 거치는 2단계 SSH 연결이 필요했다. SSH Agent Forwarding 설정이 여의치 않아, 우선 SCP로 개인키를 Bastion에 직접 복사해 접속을 검증했다.

```
scp -i soc-3tier-key.pem soc-3tier-key.pem ec2-user@<Web 서버 IP>:~/soc-3tier-key.pem
```

이후 로컬 PC의 SSH config에 ProxyJump와 포트 포워딩을 명시적으로 설정해, 매번 긴 커맨드를 입력하지 않고 `ssh elk` 한 줄로 접속과 Kibana 포트 포워딩이 동시에 이루어지도록 정리했다.

```
Host bastion
    HostName <Web 서버 IP>
    User ec2-user
    IdentityFile <키 경로>

Host elk
    HostName <ELK 서버 Private IP>
    User ubuntu
    IdentityFile <키 경로>
    ProxyJump bastion
    LocalForward 5601 <ELK 서버 Private IP>:5601
```

> 📸 `79_bastion_to_elk_connected.png` — Bastion 경유 ELK 서버 접속 성공
> 📸 `84_ssh_config_proxyjump_success.png` — SSH config 기반 접속
> 📸 `85_kibana_initial_screen.png` — 로컬 브라우저에서 Kibana 접속 확인

---

## 3. Docker Compose로 ELK 최소 구성 배포

```yaml
services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.15.0
    environment:
      - discovery.type=single-node
      - ES_JAVA_OPTS=-Xms256m -Xmx256m
    ...
  kibana:
    image: docker.elastic.co/kibana/kibana:8.15.0
    ...
```

> 📸 `81_docker_compose_elk_up.png` — 컨테이너 기동 완료
> 📸 `82_docker_compose_ps_running.png` — 정상 구동 상태 확인
> 📸 `83_docker_stats_memory_usage.png` — 메모리 사용량 확인 (물리 914MB 중 약 554MB 사용, 여유 확보)

물리 메모리 1GB 환경에서도 스왑과 힙 제한 설정 덕분에 컨테이너가 안정적으로 유지되는 것을 확인했다.

---

## 4. Lambda 기반 실시간 로그 파이프라인

VPC Flow Log를 ELK로 가져오는 방식으로, 에이전트 기반 배치 수집(Filebeat) 대신 CloudWatch Logs 구독 필터와 Lambda를 이용한 서버리스 실시간 전송 방식을 택했다. 이는 클라우드 네이티브 로그 파이프라인에서 흔히 쓰이는 패턴이며, 이전 단계(SOAR 자동 차단)에서 구축한 Lambda 활용 경험을 확장하는 방향이기도 하다.

```
VPC Flow Logs (CloudWatch Logs)
   → 구독 필터 (실시간)
   → Lambda (VPC 내부 배치)
   → Elasticsearch Bulk API
```

Lambda가 Private 서브넷의 Elasticsearch에 접근해야 하므로, 이번에는 Lambda를 VPC 내부(WAS 서브넷)에 배치했다. 지금까지 사용한 Lambda는 VPC 밖에서 AWS API만 호출했던 것과 달리, 이번 Lambda는 ENI를 할당받아 VPC 내부 통신이 가능하도록 구성했다.

---

## 5. 트러블슈팅 — 보안 그룹 재생성 무한 대기

ELK용 보안 그룹의 description을 수정하면서 재생성이 필요해졌는데, 이번에는 Day 6에서 겪었던 것과 다른 양상의 문제가 발생했다. `lifecycle { create_before_destroy = true }`가 설정되어 있었음에도, 옛 보안 그룹 삭제가 10분 넘게 멈춰 진행되지 않았다.

> 📸 `86_sg_destroy_timeout_and_shutdown.png` — 10분 이상 지속된 삭제 대기 및 강제 중단

### 원인 진단

ENI 조회를 통해 ELK EC2 인스턴스가 여전히 옛 보안 그룹을 물고 있는 것을 확인했다. `create_before_destroy`가 새 리소스 생성은 보장했지만, 그 리소스를 참조하는 EC2의 보안 그룹 갱신 순서까지는 보장하지 못한 것이 원인이었다.

작업을 중단하는 과정에서 state lock이 해제되지 않고 남는 문제도 함께 발생했다.

> 📸 `87_state_lock_error.png` — state lock 오류
> 📸 `88_force_unlock_success.png` — force-unlock으로 해제

### 해결

동일한 방식으로 재시도해도 같은 문제가 반복되어, 보안 그룹 리소스 자체를 새로운 이름(`elk_v2`)으로 분리해 재생성(replace) 판정 자체를 없앴다. 그럼에도 EC2가 자동으로 새 보안 그룹을 반영하지 않아, AWS CLI로 EC2의 보안 그룹을 직접 교체했다.

```
aws ec2 modify-instance-attribute --instance-id <id> --groups <new-sg-id>
```

이후 `terraform apply`를 재실행하자 옛 보안 그룹 삭제가 즉시 완료되었고, 그 과정에서 이미 생성되어 있던 IAM Role과의 충돌은 `terraform import`로 흡수해 해결했다.

> 📸 `89_elk_sg_destroy_resolved.png` — 삭제 정상 완료
> 📸 `90_terraform_apply_log_shipper_final_success.png` — 전체 파이프라인 배포 완료

---

## 6. 최종 검증

ELK 서버에서 Elasticsearch 인덱스를 확인한 결과, Flow Log가 실시간으로 색인되고 있음을 확인했다.

```
vpc-flowlogs-2026.08.16   487 docs   306.5kb
```

> 📸 `91_elasticsearch_flowlogs_indexed.png` — Flow Log 실시간 색인 확인

---

## 트러블슈팅

| 발생 시점 | 이슈 | 원인 | 해결 |
|---|---|---|---|
| ELK EC2 프로비저닝 시 | t3.medium 생성 실패 | 무료 플랜 계정은 프리티어 외 인스턴스 생성이 차단됨 | t3.micro로 축소, 힙 제한·스왑으로 메모리 보완 |
| Bastion 경유 SSH 시도 | 키 인증 실패 | Web 서버에 개인키가 없고 Agent Forwarding 설정이 여의치 않음 | SCP로 키 직접 복사 후 SSH config의 ProxyJump로 정리 |
| SG description 변경 후 apply | 옛 SG 삭제가 10분 이상 멈춤 | create_before_destroy가 SG 자체 생성/삭제 순서만 보장하고, 참조하는 EC2의 SG 갱신 순서는 보장하지 않음 | 리소스를 새 이름으로 분리, AWS CLI로 EC2 SG 수동 교체 |
| 중단 처리 중 | state lock이 해제되지 않고 남음 | 강제 중단(Ctrl+C) 이후 lock 정리가 완료되지 않음 | `terraform force-unlock`으로 해제 |
| 재적용 시 | IAM Role 생성 충돌 | 이전 중단된 apply에서 이미 생성되었던 리소스가 state에 반영되지 않음 | `terraform import`로 기존 리소스를 state에 흡수 |

---

## 오늘 진행사항 정리

- [x] ELK EC2(t3.micro, 스왑/힙 최소화 구성) 배포
- [x] Bastion 경유 SSH 접근 체계 구축 (SSH config, ProxyJump, 포트 포워딩)
- [x] Docker Compose로 Elasticsearch + Kibana 최소 구성 배포
- [x] Kibana 접속 확인 (SSH 로컬 포트 포워딩)
- [x] Lambda 기반 VPC Flow Log 실시간 색인 파이프라인 구축 (Lambda VPC 내부 배치)
- [x] 보안 그룹 재생성 무한 대기 트러블슈팅 및 근본 해결
- [x] Flow Log 실시간 색인 최종 검증
- [x] GitHub 커밋 & 푸시 (`feat: deploy ELK stack and lambda-based flowlog shipper to elasticsearch`)
- [ ] Kibana 인덱스 패턴 생성 및 대시보드 구성 — 다음 단계
