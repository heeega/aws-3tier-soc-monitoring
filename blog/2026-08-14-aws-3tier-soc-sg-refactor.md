# [SOC 포트폴리오 #4] AWS 3-tier 클라우드 보안관제 — ⑥ ALB 도입을 위한 보안 그룹 재설계

**TL;DR**
- Auto Scaling + ALB(로드밸런서) 도입에 앞서, Web 서버가 인터넷에 직접 노출되지 않도록 보안 그룹을 `alb-sg`(인터넷↔ALB)와 `web-sg`(ALB↔EC2)로 분리했다.
- SG의 `description` 변경이 리소스 강제 재생성을 유발하면서 의존성 위반, 이름 중복 오류가 연쇄적으로 발생했고, `lifecycle` 설정과 `name_prefix`로 해결했다.
- 다음 단계로 ALB, Target Group, Auto Scaling Group을 구축할 준비가 완료됐다.

---

## 1. 왜 지금 보안 그룹부터 손보는가

다음 단계로 가용성 확보를 위한 ALB(Application Load Balancer)와 Auto Scaling Group 도입을 계획하고 있다. 그런데 현재 구조는 Web 서버(EC2)가 `0.0.0.0/0`(인터넷 전체)로부터 80번 포트 접근을 직접 허용하고 있다. 이 상태에서 ALB만 추가하면, ALB를 거치지 않고 EC2에 직접 접근하는 경로가 그대로 남아 ALB를 두는 의미가 없어진다.

따라서 ALB나 Auto Scaling Group을 만들기 전에, 네트워크 경계부터 다음과 같이 재정의했다.

```
변경 전: 인터넷 → [web-sg: 0.0.0.0/0 허용] → EC2
변경 후: 인터넷 → [alb-sg: 0.0.0.0/0 허용] → ALB → [web-sg: alb-sg만 허용] → EC2
```

이는 지금까지 유지해온 SG 체이닝 원칙(Web→WAS→DB가 서로의 SG만 참조하도록 설계한 것)의 연장선이며, ALB가 추가되어도 "직전 계층의 SG에서 오는 트래픽만 허용한다"는 설계 원칙을 일관되게 유지한 것이다.

## 2. 변경 내용

**`alb-sg` 신규 생성**: 인터넷으로부터 80/443 포트를 허용하는 SG.

**`web-sg` 수정**: 80번 포트의 인바운드 소스를 `0.0.0.0/0`에서 `alb-sg`로 변경.

```hcl
ingress {
  description     = "HTTP from ALB only"
  from_port       = 80
  to_port         = 80
  protocol        = "tcp"
  security_groups = [aws_security_group.alb.id]
}
```

---

## 3. 트러블슈팅 — SG 재생성 연쇄 오류

### 3-1. 의존성 위반 오류

`web-sg`의 `description`을 수정하자, Terraform은 이를 "교체 필요(replace)" 대상으로 판단했다. AWS에서 보안 그룹의 `description`은 생성 후 수정이 불가능한 필드이기 때문에, 값이 바뀌면 기존 리소스를 삭제하고 새로 만들어야 한다.

```
Error: deleting Security Group (sg-...): DependencyViolation:
resource sg-... has a dependent object
```

문제는 Terraform이 기본 동작(destroy 후 create) 순서로 처리하면서, **아직 이 SG를 참조 중인 EC2·WAS SG가 남아있는 상태에서 삭제를 먼저 시도**해 실패한 것이다.

> 📸 `39_terraform_apply_error_sg_dependency.png` — 의존성 위반 오류 화면

### 3-2. lifecycle 설정 후 이름 중복 오류

Terraform에게 "삭제보다 생성을 먼저 수행하라"고 지시하는 `create_before_destroy`를 추가해 재시도했다.

```hcl
lifecycle {
  create_before_destroy = true
}
```

그러나 이번엔 다른 오류가 발생했다.

```
Error: creating Security Group (soc-3tier-web-sg):
InvalidGroup.Duplicate: The security group 'soc-3tier-web-sg' already exists
```

AWS에서 SG 이름은 VPC 내에서 고유해야 하는데, 새 SG를 먼저 생성하려는 시점에 같은 이름을 가진 기존 SG가 아직 존재하고 있어 이름이 충돌한 것이다. `create_before_destroy`가 지시하는 "먼저 생성" 동작과 고정된 리소스 이름이 서로 모순되는 상황이었다.

> 📸 `40_terraform_apply_error_sg_duplicate.png` — 이름 중복 오류 화면

### 3-3. name_prefix로 최종 해결

고정된 `name` 대신 `name_prefix`를 사용해, AWS가 매번 고유한 접미사를 자동으로 붙이도록 변경했다.

```hcl
resource "aws_security_group" "web" {
  name_prefix = "${var.project_name}-web-sg-"
  ...
  lifecycle {
    create_before_destroy = true
  }
}
```

이를 통해 새 SG와 기존 SG가 서로 다른 이름으로 동시에 존재할 수 있게 되어, 무중단으로 재생성이 완료됐다. `Name` 태그는 기존과 동일하게 유지해 콘솔에서 식별하는 데는 문제가 없도록 했다.

> 📸 `41_terraform_apply_sg_split_success.png` — 최종 배포 완료 화면

---

## 트러블슈팅

| 발생 시점 | 이슈 | 원인 | 해결 |
|---|---|---|---|
| SG description 수정 후 apply | 기존 SG 삭제 실패 (DependencyViolation) | description은 수정 불가 필드라 재생성이 필요했으나, 참조 중인 리소스가 남아있는 상태에서 삭제가 먼저 시도됨 | `lifecycle { create_before_destroy = true }` 추가 |
| lifecycle 설정 후 재시도 | 신규 SG 생성 실패 (InvalidGroup.Duplicate) | `create_before_destroy`로 신규 생성이 먼저 일어나지만, 고정된 `name`이 기존 리소스와 충돌 | `name`을 `name_prefix`로 변경해 이름 충돌 회피 |

이 연쇄적인 오류 해결 과정은 Terraform의 리소스 생명주기(`lifecycle`)와, 클라우드 리소스 이름 고유성 제약을 실제로 다뤄본 경험으로 남았다.

---

## 오늘 진행사항 정리

- [x] ALB 도입에 앞서 `alb-sg`(인터넷↔ALB), `web-sg`(ALB↔EC2)로 보안 그룹 분리
- [x] SG description 변경으로 인한 강제 재생성 시 발생하는 의존성 위반 오류 확인 및 `lifecycle` 설정으로 해결
- [x] `create_before_destroy` 적용 후 발생한 이름 중복 오류를 `name_prefix`로 해결
- [x] GitHub 커밋 & 푸시 (`refactor: split web-sg into alb-sg and web-sg for ALB integration`)
- [ ] ALB, Target Group, Auto Scaling Group 구축 — 다음 단계
