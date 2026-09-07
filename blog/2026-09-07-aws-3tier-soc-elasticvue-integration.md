# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ⑭ Elasticvue 연동

**TL;DR**
- 기존 ELK 서버의 Docker Compose에 Elasticvue를 추가해, Elasticsearch 클러스터를 GUI로 조회·관리할 수 있는 환경을 구성했다.
- CORS 설정 과정에서 YAML 파싱 오류로 Elasticsearch가 반복적으로 크래시되는 문제를 겪었고, 와일드카드(`*`) 대신 정확한 origin을 지정해 해결했다.
- 최종적으로 지난 10여 일간 쌓인 22개 인덱스, 800만 건 이상의 문서를 Elasticvue에서 확인했다.

---

## 1. 왜 Elasticvue인가

지금까지는 `curl`로 Elasticsearch API를 직접 호출해 인덱스 상태를 확인해왔다. Elasticvue는 Elasticsearch 전용 경량 GUI 도구로, 클러스터 상태·인덱스 목록·문서를 시각적으로 조회할 수 있어 운영 편의성을 높인다.

별도 EC2를 두지 않고, 기존 ELK 서버의 Docker Compose에 컨테이너 하나를 추가하는 방식으로 최소 구성을 유지했다. 접근 방식도 Kibana와 동일하게 Bastion Host를 경유하는 SSH 포트 포워딩을 그대로 적용했다.

```yaml
  elasticvue:
    image: cars10/elasticvue:latest
    container_name: elasticvue
    ports:
      - "8080:8080"
    restart: unless-stopped
```

---

## 2. 접속 환경 재정비

오랜만에 재접속하는 과정에서 두 가지를 다시 맞춰야 했다.

- **Auto Scaling Group이 그동안 인스턴스를 교체**하며 Bastion(Web 서버)의 Public IP가 바뀌어 있었다. SSH config의 `HostName`을 최신 IP로 갱신했다.
- **접속 환경이 바뀌며 공인 IP도 변경**되어, `admin_ips`에 새 IP를 추가하고 반영했다.

인프라를 장기간 운영할 때 IP나 엔드포인트가 유동적으로 바뀔 수 있다는 점을, 실제로 다시 접속을 시도하며 재확인했다.

---

## 3. CORS 설정 트러블슈팅

Elasticvue에서 클러스터 연결을 시도했으나 실패했다. Elasticsearch는 기본적으로 브라우저에서의 직접 API 호출(CORS)을 차단하기 때문에, 이를 허용하는 설정이 필요했다.

### 1차 시도 — YAML 파싱 오류

```yaml
- http.cors.enabled=true
- http.cors.allow-origin=*
```

컨테이너가 계속 재시작(`Restarting`)되며 다음 오류가 발생했다.

```
unexpected character found ... while scanning an alias
http.cors.allow-origin: *
```

`*`가 YAML에서 별도의 의미(alias 참조 기호)를 가지는 특수 문자라, Elasticsearch가 환경변수를 내부적으로 YAML로 변환하는 과정에서 파싱에 실패한 것이었다. 값을 따옴표로 감싸 봐도(`"http.cors.allow-origin=*"`) 동일한 오류가 반복됐는데, 이는 Docker Compose 수준의 따옴표가 컨테이너 내부로 전달된 이후에는 다시 순수 문자열로 해석되어 Elasticsearch 자체의 파서에서 또 한 번 문제를 일으켰기 때문이다.

### 2차 조치 — 설정 제거 후 정상화 확인

CORS 설정을 완전히 제거하고 컨테이너를 재생성해, Elasticsearch가 다시 정상 기동되는 것을 확인했다. 클러스터 상태가 `red`에서 `yellow`로 전환되는 과정을 통해, 기존에 쌓여 있던 인덱스들이 정상적으로 복구되고 있음도 함께 확인했다.

### 3차 해결 — 와일드카드 대신 정확한 origin 지정

`*` 자체가 문제였으므로, Elasticvue가 실제로 실행되는 주소를 명시적으로 지정했다.

```yaml
- http.cors.enabled=true
- http.cors.allow-origin=http://localhost:8080
```

이번에는 특수문자가 없어 YAML 파싱 문제 없이 정상 반영되었고, Elasticsearch도 안정적으로 기동되었다.

---

## 4. 최종 연결 및 확인

Elasticvue에서 클러스터 연결에 성공했다. 클러스터는 1개 노드, 54개 인덱스, 800만 건 이상의 문서, 총 1.05GB 규모로 확인되었으며, 상태는 `yellow`였다. 이는 단일 노드 구성에서 레플리카 샤드를 배치할 노드가 없어 발생하는 정상적인 상태로, 데이터 자체에는 영향이 없다.

인덱스 목록에서는 `vpc-flowlogs-2026.08.16`부터 최신 날짜까지, Day 10 이후 매일 자동 생성된 인덱스가 그대로 이어져 있는 것을 확인했다. Lambda 기반 실시간 로그 파이프라인이 별도 개입 없이 열흘 넘게 안정적으로 운영되어 왔음을 보여주는 결과다.

---

## 트러블슈팅

| 발생 시점 | 이슈 | 원인 | 해결 |
|---|---|---|---|
| 재접속 시 | Bastion SSH 연결 타임아웃 | ASG의 인스턴스 교체로 Web 서버 Public IP 변경 | SSH config의 HostName을 최신 IP로 갱신 |
| Elasticvue 최초 연결 시도 | 클러스터 연결 실패 | Elasticsearch CORS 미설정 | CORS 설정 추가 시도 |
| CORS 설정(`allow-origin=*`) 추가 후 | Elasticsearch 컨테이너 반복 재시작 | `*`가 YAML의 특수 문자(alias)로 해석되어 파싱 오류 발생. 따옴표로 감싸도 컨테이너 내부 재파싱에서 동일 오류 반복 | CORS 설정을 정확한 origin(`http://localhost:8080`)으로 지정해 특수문자 자체를 회피 |

---

## 오늘 진행사항 정리

- [x] Docker Compose에 Elasticvue 컨테이너 추가
- [x] SSH config 갱신 (Bastion IP, 관리자 IP 반영)
- [x] Elasticsearch CORS 설정 트러블슈팅 (YAML 파싱 오류 진단 및 해결)
- [x] Elasticvue 클러스터 연결 및 인덱스 목록 확인
- [x] README 및 blog 디렉토리 정리, 프로젝트 개요 문서화
- [ ] 프로젝트 종료 산출물(보고서, 노션, PPT) 제작 — 다음 단계
